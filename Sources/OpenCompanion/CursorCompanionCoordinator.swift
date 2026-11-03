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
    let label: String
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
  private var phase = NotchActivityPhase.idle
  private var reveal = CursorTextReveal()
  private var highestAcceptedPreviewID: Int?
  private var guidance: Guidance?
  private var guidanceReveal = CursorTextReveal()
  private var lastPlacement: CursorCompanionPlacement?
  private var dismissal: TimeInterval?
  private var visibleText = ""
  private var firstGlyphRecorded = false
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
          self.guidanceReveal.reset()
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

  func beginResponse(generation: UInt64) {
    guard generation >= watermark else { return }
    begin(generation: generation, stage: .response, phase: .thinking)
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

  func accept(_ preview: ProviderTextPreview, generation: UInt64) {
    guard self.generation == generation, stage == .response, preferences.showReplies else { return }
    var accepted = reveal.append(
      unitID: preview.unitID, text: preview.text, isComplete: preview.isComplete)
    // Bound queued captions without evicting unseen canonical chat content.
    // A burst can finish the current complete caption immediately, then retry.
    if !accepted, reveal.pendingUnitCount == CursorTextReveal.maximumPendingUnits,
      preview.unitID > (highestAcceptedPreviewID ?? -1),
      preview.text.utf8.count <= CursorTextReveal.maximumUnitUTF8Bytes
    {
      _ = reveal.fastForward()
      accepted = reveal.append(
        unitID: preview.unitID, text: preview.text, isComplete: preview.isComplete)
    }
    guard accepted else {
      model?.record("cursor.preview.rejectedOrBackpressured")
      return
    }
    highestAcceptedPreviewID = max(highestAcceptedPreviewID ?? -1, preview.unitID)
    let elapsed = (ProcessInfo.processInfo.systemUptime - beganAt) * 1_000
    if timing.firstPreviewMS == nil && !preview.text.isEmpty { timing.firstPreviewMS = elapsed }
    if timing.firstCompleteTextMS == nil && preview.isComplete {
      timing.firstCompleteTextMS = elapsed
    }
    dismissal = nil
    wake()
  }

  /// Called only after OverlayHost accepted the target against the selected
  /// evidence. Guidance has a separate lifetime from pointer-following.
  func guide(target: ProviderTarget, evidence: ScreenEvidence, generation: UInt64) {
    guard self.generation == generation, stage == .response,
      evidence.screenRect.width > 0, evidence.screenRect.height > 0,
      target.instruction.utf8.count <= 32_000
    else { return }
    let display = evidence.screenRect
    let destination = CGPoint(
      x: display.minX + target.x * display.width - 14,
      y: display.maxY - (target.y + target.height / 2) * display.height)
    let now = ProcessInfo.processInfo.systemUptime
    guidance = Guidance(
      flight: CursorFlight(start: lastBodyCenter, end: destination),
      began: now, expires: now + 7.5, evidence: ScreenEvidenceIdentity(evidence),
      capturedAt: evidence.capturedAt, label: target.instruction)
    guidanceReveal.reset()
    guidanceReveal.append(unitID: 0, text: target.instruction, isComplete: true)
    dismissal = nil
    model?.record("cursor.guidance.flightStarted")
    wake()
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
      dismissal = ProcessInfo.processInfo.systemUptime + 3.5
    }
  }

  private func clearPresentation() {
    if guidance != nil {
      x = NotchSpring(lastBodyCenter.x, frequency: 38)
      y = NotchSpring(lastBodyCenter.y, frequency: 38)
    }
    generation = nil
    stage = nil
    phase = .idle
    reveal.reset()
    highestAcceptedPreviewID = nil
    visibleText = ""
    firstGlyphRecorded = false
    timing = CursorCompanionTiming()
    guidance = nil
    guidanceReveal.reset()
    dismissal = nil
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
      } else if now - guidance.began >= guidance.flight.duration * 0.65 || reduceMotion {
        _ = guidanceReveal.advance(by: min(elapsed, 0.1), reduceMotion: reduceMotion)
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
    if guidance == nil { _ = reveal.advance(by: min(elapsed, 0.1), reduceMotion: reduceMotion) }
    finishIfReady()
    if let dismissal, now >= dismissal { clearPresentation() }
    renderNow()
    let animatingActivity = phase == .listening || phase == .thinking || phase == .speaking
    if guidance == nil && x.isSettled && y.isSettled && !reveal.hasPending
      && !animatingActivity && dismissal == nil
    {
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
    var text = preferences.showReplies ? reveal.visibleText : ""
    if let guidance {
      let progress = reduceMotion ? 1 : min(1, (now - guidance.began) / guidance.flight.duration)
      center = guidance.flight.point(at: progress)
      if progress < 1 {
        let tangent = guidance.flight.tangent(at: progress)
        rotation = atan2(-tangent.y, tangent.x)
      }
      text = preferences.showReplies ? guidanceReveal.visibleText : ""
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
      rotation: rotation, reduceMotion: reduceMotion)
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

  private func stopClock() {
    link?.invalidate()
    link = nil
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
