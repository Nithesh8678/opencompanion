import AppKit
import Combine
import QuartzCore
@preconcurrency import ScreenCaptureKit

struct CursorCompanionTiming: Codable {
  var firstPreviewMS: Double?
  var firstCompleteTextMS: Double?
  var firstGlyphRenderSubmissionMS: Double?
}

struct CursorCompanionSnapshot: Codable {
  let generation: UInt64?
  let phase: String
  let text: String
  let frame: CGRect
  let bodyCenter: CGPoint
  let visible: Bool
  let ignoresMouseEvents: Bool
  let canBecomeKey: Bool
  let following: Bool
  let displayLinkRunning: Bool
  let callbacks: Int
  let p95CallbackIntervalMS: Double
  let timing: CursorCompanionTiming
}

/// Presentation owns its own clock. Mouse movement never captures a screen,
/// queries Accessibility, calls a provider, or changes the actual system cursor.
@MainActor final class CursorCompanionCoordinator: NSObject {
  private enum Stage { case input, response }
  private struct Guidance {
    let flight: CursorFlight
    let began: TimeInterval
    let expires: TimeInterval
    let evidence: ScreenEvidenceIdentity
    let capturedAt: TimeInterval
    let labelFrame: CGRect
    let prefixWidths: [CGFloat]
    let ellipse: CGRect?
  }

  private let panel: CursorCompanionPanel
  private let view = CursorCompanionView(frame: CGRect(x: 0, y: 0, width: 80, height: 60))
  private weak var model: AppModel?
  private let exclusionFrames: () -> [CGRect]
  let observesPointer: Bool
  private var preferences = CursorCompanionPreferences.load()
  private var subscriptions = Set<AnyCancellable>()
  private var globalMouse: Any?
  private var localMouse: Any?
  private var link: CADisplayLink?
  private var scheduledUpdate = false
  private var suspended = false
  private var pointer = NSEvent.mouseLocation
  private var x = NotchSpring(0, frequency: 38)
  private var y = NotchSpring(0, frequency: 38)
  private var initialized = false
  private var lastTick = 0.0
  private var intervals: [Double] = []
  private var generation: UInt64?
  private var watermark: UInt64 = 0
  private var stage: Stage?
  private var isGuidance = false
  private var phase = NotchActivityPhase.idle
  private var reveal = CursorTextReveal()
  private var highestAcceptedPreviewID: Int?
  private var guidance: Guidance?
  private var lastPlacement: CursorCompanionPlacement?
  private var dismissal: TimeInterval?
  private var dismissalTask: Task<Void, Never>?
  private var visibleText = ""
  private var firstGlyphRecorded = false
  private var wordSerial: UInt64 = 0
  private var word: CursorCaptionWord?
  private var lastBodyCenter = CGPoint.zero
  private var syntheticReduceMotion: Bool?
  private var beganAt = 0.0
  private var timing = CursorCompanionTiming()

  init(
    model: AppModel, observePointer: Bool = true,
    preferences: CursorCompanionPreferences? = nil,
    exclusionFrames: @escaping () -> [CGRect] = { [] }
  ) {
    self.model = model
    observesPointer = observePointer
    self.exclusionFrames = exclusionFrames
    if let preferences { self.preferences = preferences }
    panel = CursorCompanionPanel(
      contentRect: CGRect(x: 0, y: 0, width: 80, height: 60),
      styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    super.init()
    panel.identifier = NSUserInterfaceItemIdentifier("org.opencompanion.cursor")
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = false
    panel.ignoresMouseEvents = true
    panel.hidesOnDeactivate = false
    panel.isFloatingPanel = true
    panel.level = .floating
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
    panel.isReleasedWhenClosed = false
    panel.contentView = view
    model.objectWillChange.sink { [weak self] in
      MainActor.assumeIsolated { self?.scheduleModelUpdate() }
    }.store(in: &subscriptions)
    NotificationCenter.default.publisher(for: .cursorCompanionPreferencesDidChange).sink {
      [weak self] _ in
      MainActor.assumeIsolated {
        guard let self else { return }
        self.preferences = .load()
        if !self.preferences.showReplies {
          self.reveal.reset()
          self.visibleText = ""
        }
        self.renderNow()
        self.wake()
      }
    }.store(in: &subscriptions)
    NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
      .sink { [weak self] _ in
        MainActor.assumeIsolated {
          guard let self else { return }
          self.guidance = nil
          self.lastPlacement = nil
          self.initialized = false
          self.pointerMoved(to: self.observesPointer ? NSEvent.mouseLocation : self.pointer)
          self.renderNow()
        }
      }.store(in: &subscriptions)
    for name in [NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification]
    {
      NSWorkspace.shared.notificationCenter.publisher(for: name).sink { [weak self] _ in
        MainActor.assumeIsolated {
          guard let self else { return }
          self.suspended = true
          self.clearPresentation()
          self.panel.orderOut(nil)
          self.stopClock()
        }
      }.store(in: &subscriptions)
    }
    for name in [NSWorkspace.didWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
      NSWorkspace.shared.notificationCenter.publisher(for: name).sink { [weak self] _ in
        MainActor.assumeIsolated {
          guard let self else { return }
          self.suspended = false
          self.pointerMoved(to: NSEvent.mouseLocation)
        }
      }.store(in: &subscriptions)
    }
    if observePointer {
      let mask: NSEvent.EventTypeMask = [
        .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
      ]
      globalMouse = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] _ in
        MainActor.assumeIsolated { self?.pointerMoved(to: NSEvent.mouseLocation) }
      }
      localMouse = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
        MainActor.assumeIsolated { self?.pointerMoved(to: NSEvent.mouseLocation) }
        return event
      }
    }
    pointerMoved(to: pointer)
  }

  var snapshot: CursorCompanionSnapshot {
    let sorted = intervals.sorted()
    return CursorCompanionSnapshot(
      generation: generation, phase: phase.rawValue, text: visibleText,
      frame: panel.frame, bodyCenter: lastBodyCenter, visible: panel.isVisible,
      ignoresMouseEvents: panel.ignoresMouseEvents, canBecomeKey: panel.canBecomeKey,
      following: guidance == nil, displayLinkRunning: link != nil, callbacks: intervals.count,
      p95CallbackIntervalMS: sorted.isEmpty
        ? 0 : sorted[Int(Double(sorted.count - 1) * 0.95)] * 1_000,
      timing: timing)
  }

  func beginInput(generation: UInt64) {
    guard generation >= watermark else { return }
    begin(generation: generation, stage: .input, phase: .preparing)
  }

  func beginResponse(generation: UInt64, isGuidance: Bool = false) {
    guard generation >= watermark else { return }
    begin(generation: generation, stage: .response, phase: .thinking)
    self.isGuidance = isGuidance
  }

  private func begin(generation: UInt64, stage: Stage, phase: NotchActivityPhase) {
    clearPresentation()
    watermark = generation
    self.generation = generation
    self.stage = stage
    self.phase = phase
    beganAt = ProcessInfo.processInfo.systemUptime
    // Reset layers synchronously: a new hold never inherits response dots/text.
    view.reset()
    renderNow()
    wake()
  }

  func cancel(generation: UInt64) {
    guard generation >= watermark else { return }
    watermark = generation
    clearPresentation()
    renderNow()
    wake()
  }

  @discardableResult func accept(_ preview: ProviderTextPreview, generation: UInt64) -> Bool {
    guard self.generation == generation, stage == .response, !isGuidance, preferences.enabled,
      preferences.showReplies
    else { return true }
    let accepted = reveal.append(
      unitID: preview.unitID, text: preview.text, isComplete: preview.isComplete)
    if !accepted, reveal.pendingUnitCount == CursorTextReveal.maximumPendingUnits,
      preview.unitID > (highestAcceptedPreviewID ?? -1),
      preview.text.utf8.count <= CursorTextReveal.maximumUnitUTF8Bytes
    {
      return false
    }
    guard accepted else {
      model?.record("cursor.preview.rejectedOrBackpressured")
      return true
    }
    highestAcceptedPreviewID = max(highestAcceptedPreviewID ?? -1, preview.unitID)
    let elapsed = (ProcessInfo.processInfo.systemUptime - beganAt) * 1_000
    if timing.firstPreviewMS == nil && !preview.text.isEmpty { timing.firstPreviewMS = elapsed }
    if timing.firstCompleteTextMS == nil && preview.isComplete {
      timing.firstCompleteTextMS = elapsed
    }
    cancelDismissal()
    view.cancelCaptionDismissal()
    wake()
    return true
  }

  /// Called only after OverlayHost accepted the target against the selected
  /// evidence. Guidance has a separate lifetime from pointer-following.
  @discardableResult func guide(
    target: ProviderTarget, evidence: ScreenEvidence, generation: UInt64
  ) -> TimeInterval {
    guard preferences.enabled, !suspended, self.generation == generation, stage == .response,
      evidence.screenRect.width > 0, evidence.screenRect.height > 0,
      target.instruction.utf8.count <= 32_000
    else { return 0 }
    let display = evidence.screenRect
    let targetFrame = CGRect(
      x: display.minX + target.x * display.width,
      y: display.maxY - (target.y + target.height) * display.height,
      width: target.width * display.width, height: target.height * display.height)
    let labelFrame = GuidanceAnnotationLayout.labelFrame(
      target: target, display: display)
    let widths = GuidanceAnnotationLayout.labelPrefixWidths(
      text: GuidanceAnnotationLayout.labelText(target: target))
    let ellipse = target.shape == "ellipse" ? targetFrame : nil
    let destination =
      ellipse.map { Self.ellipsePoint($0, progress: 0) }
      ?? (labelFrame.isEmpty
        ? CGPoint(x: targetFrame.minX - 14, y: targetFrame.midY)
        : CGPoint(x: labelFrame.minX + 10, y: labelFrame.minY - 5))
    let now = ProcessInfo.processInfo.systemUptime
    let flight = CursorFlight(start: lastBodyCenter, end: destination)
    let writing =
      ellipse != nil
      ? 0.35
      : GuidanceAnnotationLayout.labelFadeDuration + Double(max(0, widths.count - 1))
        * GuidanceAnnotationLayout.glyphInterval
    guidance = Guidance(
      flight: flight, began: now,
      expires: now + (reduceMotion ? 0 : flight.duration + writing) + 0.35,
      evidence: ScreenEvidenceIdentity(evidence), capturedAt: evidence.capturedAt,
      labelFrame: labelFrame, prefixWidths: widths, ellipse: ellipse)
    cancelDismissal()
    view.cancelCaptionDismissal()
    model?.record("cursor.guidance.flightStarted")
    wake()
    return reduceMotion ? 0 : flight.duration
  }

  func pointerMoved(to point: CGPoint) {
    guard point.x.isFinite, point.y.isFinite else { return }
    pointer = point
    let target = followTarget
    if !initialized || reduceMotion {
      x = NotchSpring(target.x, frequency: 38)
      y = NotchSpring(target.y, frequency: 38)
      initialized = true
    }
    x.target = target.x
    y.target = target.y
    // Hide immediately when the user enters the notch, including while settled.
    if exclusionFrames().contains(where: { $0.contains(pointer) }) { panel.orderOut(nil) }
    // NSView's display link does not tick an offscreen window. Mount the first
    // pose (or returning follower) before asking the clock to animate it.
    if !panel.isVisible { renderNow() }
    wake()
  }

  private var followTarget: CGPoint { CGPoint(x: pointer.x + 17, y: pointer.y - 22) }
  private var reduceMotion: Bool {
    syntheticReduceMotion ?? NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
  }

  private func scheduleModelUpdate() {
    guard !scheduledUpdate else { return }
    scheduledUpdate = true
    Task { @MainActor [weak self] in
      guard let self else { return }
      self.scheduledUpdate = false
      self.syncModel()
    }
  }

  private func syncModel() {
    guard let model, let generation, generation == model.taskGeneration else { return }
    if model.error != nil {
      cancel(generation: generation)
      return
    }
    switch stage {
    case .input:
      switch model.voiceInputState {
      case "Preparing microphone": phase = .preparing
      case "Listening": phase = .listening
      case "Finishing speech", "Release Control+Option to send": phase = .thinking
      default:
        if !model.listening && !model.pushToTalkActive {
          clearPresentation()
        }
      }
    case .response:
      phase =
        model.state == "Speaking" && model.voice.hasPendingSpeech
        ? .speaking : (model.busy || model.voice.hasPendingSpeech ? .thinking : .idle)
      finishIfReady()
    case nil: break
    }
    renderNow()
    wake()
  }

  private func finishIfReady() {
    guard stage == .response, let model, !model.busy, !model.voice.hasPendingSpeech,
      !reveal.hasPending, guidance == nil, dismissal == nil
    else { return }
    phase = .idle
    if reveal.visibleText.isEmpty {
      clearPresentation()
    } else {
      let deadline = ProcessInfo.processInfo.systemUptime + 3.5
      dismissal = deadline
      let owner = generation
      dismissalTask = Task { @MainActor [weak self] in
        do { try await Task.sleep(for: .milliseconds(3_500)) } catch { return }
        guard let self, self.generation == owner, self.dismissal == deadline else { return }
        self.view.dismissCaption(animated: !self.reduceMotion)
        if !self.reduceMotion {
          do { try await Task.sleep(for: .milliseconds(180)) } catch { return }
        }
        guard self.generation == owner, self.dismissal == deadline else { return }
        self.dismissalTask = nil
        self.clearPresentation()
        self.renderNow()
        self.wake()
      }
    }
  }

  private func clearPresentation() {
    if guidance != nil {
      x = NotchSpring(lastBodyCenter.x, frequency: 38)
      y = NotchSpring(lastBodyCenter.y, frequency: 38)
    }
    generation = nil
    stage = nil
    isGuidance = false
    phase = .idle
    reveal.reset()
    highestAcceptedPreviewID = nil
    visibleText = ""
    firstGlyphRecorded = false
    word = nil
    timing = CursorCompanionTiming()
    guidance = nil
    cancelDismissal()
    view.reset()
  }

  private func wake() {
    guard preferences.enabled, !suspended else {
      panel.orderOut(nil)
      stopClock()
      return
    }
    if link == nil {
      lastTick = ProcessInfo.processInfo.systemUptime
      let clock = view.displayLink(target: self, selector: #selector(tick(_:)))
      clock.add(to: .main, forMode: .common)
      link = clock
    }
  }

  @objc private func tick(_ sender: CADisplayLink) {
    let now = ProcessInfo.processInfo.systemUptime
    let elapsed = max(0, now - lastTick)
    if intervals.count < 2_400 { intervals.append(elapsed) }
    lastTick = now
    if let guidance {
      let valid =
        guidance.evidence.matches(model?.evidence)
        && NSWorkspace.shared.frontmostApplication?.processIdentifier
          == guidance.evidence.foregroundPID
        && now - guidance.capturedAt >= 0 && now - guidance.capturedAt < 15
        && now < guidance.expires
      if !valid {
        self.guidance = nil
        x = NotchSpring(lastBodyCenter.x, frequency: 38)
        y = NotchSpring(lastBodyCenter.y, frequency: 38)
        model?.record("cursor.guidance.invalidated")
      }
    }
    if guidance == nil {
      let target = followTarget
      if reduceMotion {
        x = NotchSpring(target.x, frequency: 38)
        y = NotchSpring(target.y, frequency: 38)
      } else {
        x.target = target.x
        y.target = target.y
        x.advance(by: min(elapsed, 0.1))
        y.advance(by: min(elapsed, 0.1))
      }
    }
    if guidance == nil {
      let previous = reveal.visibleText
      let previousID = reveal.currentUnitID
      if reveal.advance(by: min(elapsed, 0.1), reduceMotion: reduceMotion) {
        word = nextWord(previous: previous, previousID: previousID, reveal: reveal)
      }
    }
    finishIfReady()
    renderNow()
    if guidance == nil && x.isSettled && y.isSettled && !reveal.hasRevealableText {
      stopClock()
    }
  }

  private func renderNow() {
    guard preferences.enabled, !suspended,
      !exclusionFrames().contains(where: { $0.contains(pointer) })
    else {
      panel.orderOut(nil)
      return
    }
    let now = ProcessInfo.processInfo.systemUptime
    var center = CGPoint(x: x.value, y: y.value)
    var rotation: CGFloat = 0
    var text = preferences.showReplies && !isGuidance ? reveal.visibleText : ""
    if let guidance {
      let progress = reduceMotion ? 1 : min(1, (now - guidance.began) / guidance.flight.duration)
      center = guidance.flight.point(at: progress)
      if progress < 1 {
        let tangent = guidance.flight.tangent(at: progress)
        rotation = atan2(-tangent.y, tangent.x)
      } else if let ellipse = guidance.ellipse {
        let trace =
          reduceMotion
          ? 1 : min(1, max(0, (now - guidance.began - guidance.flight.duration) / 0.35))
        center = Self.ellipsePoint(ellipse, progress: trace)
        let angle = CGFloat(trace) * 2 * .pi - .pi * 0.72
        rotation = atan2(ellipse.height * cos(angle), -ellipse.width * sin(angle))
      } else if !guidance.labelFrame.isEmpty {
        let elapsed =
          now - guidance.began - guidance.flight.duration
          - GuidanceAnnotationLayout.labelFadeDuration
        let glyphProgress =
          reduceMotion
          ? Double(max(0, guidance.prefixWidths.count - 1))
          : max(0, elapsed) / GuidanceAnnotationLayout.glyphInterval
        let index = min(guidance.prefixWidths.count - 1, Int(glyphProgress))
        let next = min(guidance.prefixWidths.count - 1, index + 1)
        let fraction = CGFloat(min(1, glyphProgress - Double(index)))
        let width =
          guidance.prefixWidths[index]
          + (guidance.prefixWidths[next] - guidance.prefixWidths[index]) * fraction
        center = CGPoint(
          x: guidance.labelFrame.minX + 10 + min(guidance.labelFrame.width - 20, width),
          y: guidance.labelFrame.minY - 5)
      }
      text = ""
    }
    // The full reply remains in Chat. A rolling caption bounds layout work and
    // keeps long answers beside the pointer rather than covering the display.
    visibleText = Self.captionWindow(text)
    guard
      let screen = NSScreen.screens.first(where: { $0.frame.contains(center) })
        ?? NSScreen.screens.first(where: { $0.frame.contains(pointer) }) ?? NSScreen.main
    else {
      panel.orderOut(nil)
      return
    }
    let placement = CursorCompanionLayout.placement(
      anchor: center, bubbleSize: view.measure(text: visibleText, maxWidth: 300),
      display: screen.frame, visible: screen.visibleFrame, previous: lastPlacement)
    lastPlacement = placement
    panel.setFrame(placement.frame, display: false)
    view.frame = CGRect(origin: .zero, size: placement.frame.size)
    view.update(
      phase: phase, text: visibleText, level: model?.microphoneLevel ?? 0,
      bodyPoint: placement.bodyPoint, bubbleFrame: placement.bubbleFrame,
      rotation: rotation, reduceMotion: reduceMotion, word: guidance == nil ? word : nil)
    lastBodyCenter = CGPoint(
      x: placement.frame.minX + placement.bodyPoint.x,
      y: placement.frame.maxY - placement.bodyPoint.y)
    if !panel.isVisible { panel.orderFrontRegardless() }
    if guidance == nil, !firstGlyphRecorded, !visibleText.isEmpty {
      firstGlyphRecorded = true
      timing.firstGlyphRenderSubmissionMS = (now - beganAt) * 1_000
      model?.record("cursor.firstGlyph.renderSubmitted")
    }
  }

  static func captionWindow(_ text: String) -> String {
    guard text.count > 220 else { return text }
    let suffix = String(text.suffix(219))
    if let boundary = suffix.firstIndex(where: { $0.isWhitespace }),
      suffix.distance(from: suffix.startIndex, to: boundary) < 32
    {
      return "…" + suffix[suffix.index(after: boundary)...]
    }
    return "…" + suffix
  }

  private func nextWord(previous: String, previousID: Int?, reveal: CursorTextReveal)
    -> CursorCaptionWord
  {
    wordSerial &+= 1
    let appended =
      previousID == reveal.currentUnitID && reveal.visibleText.hasPrefix(previous)
      ? String(reveal.visibleText.dropFirst(previous.count)) : reveal.visibleText
    return CursorCaptionWord(serial: wordSerial, suffix: appended)
  }

  func setReduceMotionForAcceptance(_ enabled: Bool?) {
    syntheticReduceMotion = enabled
    wake()
  }

  func exportSnapshot(to url: URL) async throws {
    guard panel.isVisible else { throw ProviderError.message("Cursor panel is hidden.") }
    let inventory = try await SCShareableContent.excludingDesktopWindows(
      false, onScreenWindowsOnly: true)
    guard
      let window = inventory.windows.first(where: {
        $0.windowID == CGWindowID(panel.windowNumber)
          && $0.owningApplication?.processID == ProcessInfo.processInfo.processIdentifier
      })
    else { throw ProviderError.message("Cursor panel is unavailable for its own capture.") }
    let configuration = SCStreamConfiguration()
    configuration.width = max(1, Int(panel.frame.width * panel.backingScaleFactor))
    configuration.height = max(1, Int(panel.frame.height * panel.backingScaleFactor))
    configuration.showsCursor = false
    let image = try await SCScreenshotManager.captureImage(
      contentFilter: SCContentFilter(desktopIndependentWindow: window), configuration: configuration
    )
    guard let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    else { throw CocoaError(.fileWriteUnknown) }
    try data.write(to: url, options: .atomic)
  }

  private static func ellipsePoint(_ rect: CGRect, progress: Double) -> CGPoint {
    let angle = CGFloat(min(1, max(0, progress))) * 2 * .pi - .pi * 0.72
    let rx = max(0.25, rect.width / 2 - 2)
    let ry = max(0.25, rect.height / 2 - 2)
    let wobble = min(0.7, rx * 0.06, ry * 0.06) * sin(angle * 3 + 0.4)
    return CGPoint(
      x: rect.midX + (rx + wobble) * cos(angle),
      y: rect.midY - (ry + wobble) * sin(angle))
  }

  private func stopClock() {
    link?.invalidate()
    link = nil
  }

  private func cancelDismissal() {
    dismissalTask?.cancel()
    dismissalTask = nil
    dismissal = nil
  }

  func shutdown() {
    stopClock()
    if let globalMouse { NSEvent.removeMonitor(globalMouse) }
    if let localMouse { NSEvent.removeMonitor(localMouse) }
    globalMouse = nil
    localMouse = nil
    subscriptions.removeAll()
    clearPresentation()
    panel.orderOut(nil)
  }
}

private final class CursorCompanionPanel: NSPanel {
  override var canBecomeKey: Bool { false }
  override var canBecomeMain: Bool { false }
}
