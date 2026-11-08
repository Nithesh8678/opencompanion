import AppKit
import Combine
import QuartzCore
@preconcurrency import ScreenCaptureKit

struct CursorCompanionTiming: Codable {
  var firstPreviewMS: Double?
  var firstCompleteTextMS: Double?
  var firstGlyphRenderSubmissionMS: Double?
}

enum SceneCursorVisitEndReason: String, Codable, Sendable {
  case preferencesDisabled, repliesDisabled, displayChanged, suspended
  case newInput, newResponse, generationCancelled, inputEnded
  case responseCompleted, captionDismissed, presentationCleared, shutdown
  case narrationContextChanged, nativeNarrationFinished, narrationAbandoned, localCaptionCompleted
  case replacedByNewVisit, explicitCancellation, explicitScopedCancellation, screenGuidanceStarted
  case authorityUnavailable, boundsObserverUnavailable, hostBoundsUnavailable
  case authorityChangedDuringBoundsRead, pointOrBoundsInvalid, pointExcluded,
    projectionUpdateRejected
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
  private var showingGuidanceExplanation = false
  private var guidanceExplanationEvidence: ScreenEvidenceIdentity?
  private var phase = NotchActivityPhase.idle
  private var reveal = CursorTextReveal()
  private var narration: CursorNarrationCaption?
  var onNarrationCaptionCompleted: ((VoiceNarrationContext) -> Void)?
  private var highestAcceptedPreviewID: Int?
  private var guidance: Guidance?
  private var sceneVisit: SceneCursorVisit?
  /// Returns the current own-scene panel only while this exact narration and
  /// presentation lease is active. Absence revokes the visit, never the caption.
  var sceneNodeVisitBounds: ((SceneFocusAuthority) -> CGRect?)?
  /// Optional lifecycle observation. The old owner is revoked before delivery;
  /// callers that record a trace remain responsible for bounding their storage.
  var onSceneNodeVisitEnded: ((SceneFocusAuthority, SceneCursorVisitEndReason) -> Void)?
  private(set) var lastSceneNodeVisitEndReason: SceneCursorVisitEndReason?
  var sceneNodeVisitAuthority: SceneFocusAuthority? { sceneVisit?.authority }
  var sceneNodeVisitTargetPoint: CGPoint? { sceneVisit?.target }
  private var lastPlacement: CursorCompanionPlacement?
  private var lastRequestedWindowFrame: CGRect?
  private var dismissal: TimeInterval?
  private var dismissalTask: Task<Void, Never>?
  private var visibleText = ""
  private var firstGlyphRecorded = false
  private var wordSerial: UInt64 = 0
  private var word: CursorCaptionWord?
  private var lastBodyCenter = CGPoint.zero
  private var hasRenderedBody = false
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
    // Above the own explanation surface, even when that panel mounted later.
    // This remains passive and below the notch/status-bar presentation level.
    panel.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
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
        if !self.preferences.enabled || !self.preferences.showReplies {
          self.endSceneNodeVisit(
            reason: self.preferences.enabled ? .repliesDisabled : .preferencesDisabled)
          self.abandonNarration()
        }
        if !self.preferences.showReplies {
          self.clearGuidanceExplanation()
        }
        self.renderNow()
        self.wake()
      }
    }.store(in: &subscriptions)
    NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
      .sink { [weak self] _ in
        MainActor.assumeIsolated {
          guard let self else { return }
          self.endSceneNodeVisit(reason: .displayChanged)
          if self.guidanceExplanationEvidence != nil { self.clearGuidanceExplanation() }
          self.guidance = nil
          self.lastPlacement = nil
          self.initialized = false
          self.pointerMoved(to: self.observesPointer ? NSEvent.mouseLocation : self.pointer)
          self.renderNow()
        }
      }.store(in: &subscriptions)
    // The display clock sleeps during a completed caption's reading hold.
    // App activation must therefore invalidate screen-bound text independently.
    NSWorkspace.shared.notificationCenter.publisher(
      for: NSWorkspace.didActivateApplicationNotification
    )
    .sink { [weak self] _ in
      Task { @MainActor [weak self] in self?.syncModel() }
    }.store(in: &subscriptions)
    for name in [NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification]
    {
      NSWorkspace.shared.notificationCenter.publisher(for: name).sink { [weak self] _ in
        MainActor.assumeIsolated {
          guard let self else { return }
          self.suspended = true
          self.clearPresentation(reason: .suspended)
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
      following: guidance == nil && sceneVisit == nil, displayLinkRunning: link != nil,
      callbacks: intervals.count,
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
    clearPresentation(reason: stage == .input ? .newInput : .newResponse)
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
    clearPresentation(reason: .generationCancelled)
    renderNow()
    wake()
  }

  @discardableResult func accept(_ preview: ProviderTextPreview, generation: UInt64) -> Bool {
    guard narration == nil, self.generation == generation, stage == .response, !isGuidance,
      preferences.enabled,
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

  /// The caller starts this lease before enqueuing native speech. An empty
  /// native caption remains owned until a real range or explicit finish arrives.
  @discardableResult func beginNarration(
    text: String, context: VoiceNarrationContext, nativeSpeech: Bool
  ) -> Bool {
    guard preferences.enabled, preferences.showReplies, !suspended,
      generation == context.generation, model?.taskGeneration == context.generation,
      stage == .response, !isGuidance,
      let next = CursorNarrationCaption(text: text, context: context, nativeSpeech: nativeSpeech)
    else { return false }
    if let narration, narration.context == context, narration.text == text,
      narration.nativeSpeech == nativeSpeech
    {
      return true
    }
    if let visit = sceneVisit,
      visit.authority.generation != context.generation
        || visit.authority.beatID != context.narrationID
    {
      endSceneNodeVisit(reason: .narrationContextChanged)
    }
    abandonNarration()
    narration = next
    reveal.reset()
    highestAcceptedPreviewID = nil
    word = nil
    visibleText = ""
    cancelDismissal()
    view.reset()
    phase = .thinking
    renderNow()
    wake()
    return true
  }

  func updateNarration(_ update: VoiceUtteranceUpdate) {
    guard generation == update.context.generation,
      model?.taskGeneration == update.context.generation,
      var owned = narration, owned.context == update.context, owned.nativeSpeech
    else { return }
    let previous = owned.visibleText
    let changed = owned.receive(update)
    narration = owned
    if owned.cancelled {
      // The owner may now explicitly restart the same text in local mode.
      abandonNarration()
      renderNow()
      wake()
      return
    }
    guard changed else { return }
    word = nextWord(previous: previous, current: owned.visibleText)
    phase = .speaking
    cancelDismissal()
    view.cancelCaptionDismissal()
    renderNow()
    wake()
  }

  func finishNarration(context: VoiceNarrationContext) {
    guard generation == context.generation, model?.taskGeneration == context.generation,
      let owned = narration, owned.context == context, owned.nativeSpeech
    else { return }
    if owned.visibleText != owned.text {
      word = nextWord(previous: owned.visibleText, current: owned.text)
    }
    endSceneNodeVisit(for: context, reason: .nativeNarrationFinished)
    narration = nil
    settleNarrationText(owned.text)
    renderNow()
    finishIfReady()
    wake()
  }

  private func settleNarrationText(_ text: String) {
    reveal.reset()
    _ = reveal.append(unitID: 0, text: text, isComplete: true)
    _ = reveal.fastForward()
    highestAcceptedPreviewID = 0
  }

  private func dispatchNarrationCompletion(_ context: VoiceNarrationContext) {
    // The callback may synchronously begin another stage. Deliver only after
    // the current state transition/render submission has completely returned.
    Task { @MainActor [weak self] in self?.onNarrationCaptionCompleted?(context) }
  }

  private func abandonNarration() {
    guard var owned = narration else { return }
    endSceneNodeVisit(for: owned.context, reason: .narrationAbandoned)
    narration = nil
    reveal.reset()
    highestAcceptedPreviewID = nil
    word = nil
    visibleText = ""
    view.reset()
    if let context = owned.takeLocalCompletion(at: 0, force: true) {
      dispatchNarrationCompletion(context)
    }
  }

  private func completeLocalNarrationAfterSubmission(at uptime: TimeInterval) {
    guard var owned = narration else { return }
    owned.didSubmitCaption(at: uptime, reduceMotion: reduceMotion)
    let context = owned.takeLocalCompletion(at: uptime)
    narration = owned
    guard let context else { return }
    endSceneNodeVisit(for: context, reason: .localCaptionCompleted)
    narration = nil
    settleNarrationText(owned.text)
    dispatchNarrationCompletion(context)
  }

  /// A generated explanation uses its admitted document/presentation lease;
  /// this path has no screen-capture evidence or desktop automation authority.
  @discardableResult func visitSceneNode(
    authority: SceneFocusAuthority, point: CGPoint
  ) -> Bool {
    let validation = sceneBoundsValidation(for: authority)
    guard let bounds = validation.bounds,
      SceneCursorVisit.valid(point: point, in: bounds)
    else {
      if sceneVisit?.authority == authority {
        cancelSceneNodeVisit(
          authority: authority, reason: validation.failure ?? .pointOrBoundsInvalid)
      }
      return false
    }
    if sceneVisit?.authority == authority {
      return updateSceneNodeVisit(authority: authority, point: point)
    }
    let now = ProcessInfo.processInfo.systemUptime
    guard
      let next = SceneCursorVisit(
        authority: authority,
        from: hasRenderedBody ? lastBodyCenter : CGPoint(x: x.value, y: y.value),
        point: point, bounds: bounds, at: now)
    else { return false }
    let replaced = sceneVisit?.authority
    sceneVisit = next
    if let replaced { reportSceneNodeVisitEnded(replaced, reason: .replacedByNewVisit) }
    guard sceneVisit?.authority == authority else { return false }
    cancelDismissal()
    view.cancelCaptionDismissal()
    renderNow()
    wake()
    return sceneVisit?.authority == authority
  }

  @discardableResult func updateSceneNodeVisit(
    authority: SceneFocusAuthority, point: CGPoint
  ) -> Bool {
    guard sceneVisit?.authority == authority else { return false }
    let validation = sceneBoundsValidation(for: authority)
    guard let bounds = validation.bounds,
      sceneVisit?.authority == authority,
      sceneVisit?.update(
        authority: authority, point: point, bounds: bounds,
        at: ProcessInfo.processInfo.systemUptime, reduceMotion: reduceMotion) == true
    else {
      cancelSceneNodeVisit(
        authority: authority, reason: validation.failure ?? .projectionUpdateRejected)
      return false
    }
    renderNow()
    wake()
    return sceneVisit?.authority == authority
  }

  func cancelSceneNodeVisit(authority: SceneFocusAuthority? = nil) {
    cancelSceneNodeVisit(
      authority: authority,
      reason: authority == nil ? .explicitCancellation : .explicitScopedCancellation)
  }

  private func cancelSceneNodeVisit(
    authority: SceneFocusAuthority?, reason: SceneCursorVisitEndReason
  ) {
    guard let current = sceneVisit, authority == nil || current.authority == authority else {
      return
    }
    endSceneNodeVisit(reason: reason)
    renderNow()
    wake()
  }

  private func currentSceneBounds(for authority: SceneFocusAuthority) -> CGRect? {
    sceneBoundsValidation(for: authority).bounds
  }

  private func sceneBoundsValidation(
    for authority: SceneFocusAuthority
  ) -> (bounds: CGRect?, failure: SceneCursorVisitEndReason?) {
    guard ownsSceneAuthority(authority) else { return (nil, .authorityUnavailable) }
    guard let observer = sceneNodeVisitBounds else { return (nil, .boundsObserverUnavailable) }
    guard let bounds = observer(authority) else { return (nil, .hostBoundsUnavailable) }
    guard ownsSceneAuthority(authority) else { return (nil, .authorityChangedDuringBoundsRead) }
    return (bounds, nil)
  }

  private func ownsSceneAuthority(_ authority: SceneFocusAuthority) -> Bool {
    guard preferences.enabled, preferences.showReplies, !suspended,
      stage == .response, !isGuidance, guidance == nil,
      generation == authority.generation, let model,
      model.taskGeneration == authority.generation,
      let document = model.explanationDisplayDocument
    else { return false }
    return authority.matches(document: document)
  }

  private func validateSceneNodeVisit() {
    guard let current = sceneVisit else { return }
    let validation = sceneBoundsValidation(for: current.authority)
    // The host callback may synchronously publish a newer presentation.
    guard sceneVisit?.authority == current.authority else { return }
    guard let bounds = validation.bounds else {
      endSceneNodeVisit(reason: validation.failure ?? .hostBoundsUnavailable)
      return
    }
    guard SceneCursorVisit.valid(point: current.target, in: bounds) else {
      endSceneNodeVisit(reason: .pointOrBoundsInvalid)
      return
    }
    guard !exclusionFrames().contains(where: { $0.contains(current.target) }) else {
      endSceneNodeVisit(reason: .pointExcluded)
      return
    }
  }

  private func endSceneNodeVisit(
    for context: VoiceNarrationContext, reason: SceneCursorVisitEndReason
  ) {
    guard let current = sceneVisit, current.authority.generation == context.generation,
      current.authority.beatID == context.narrationID
    else { return }
    endSceneNodeVisit(reason: reason)
  }

  private func endSceneNodeVisit(reason: SceneCursorVisitEndReason) {
    guard let previous = sceneVisit else { return }
    sceneVisit = nil
    // Rebase the existing follower spring at the actual last painted body.
    // Revoking a projection therefore returns smoothly without touching text.
    x = NotchSpring(lastBodyCenter.x, frequency: 38)
    y = NotchSpring(lastBodyCenter.y, frequency: 38)
    x.target = followTarget.x
    y.target = followTarget.y
    initialized = true
    reportSceneNodeVisitEnded(previous.authority, reason: reason)
  }

  private func reportSceneNodeVisitEnded(
    _ authority: SceneFocusAuthority, reason: SceneCursorVisitEndReason
  ) {
    lastSceneNodeVisitEndReason = reason
    onSceneNodeVisitEnded?(authority, reason)
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
    endSceneNodeVisit(reason: .screenGuidanceStarted)
    if let previous = guidanceExplanationEvidence, previous != ScreenEvidenceIdentity(evidence) {
      clearGuidanceExplanation()
    }
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
    // A short attached label is not a substitute for the full screen answer.
    // Reveal the explanation beside the follower after its pointing animation.
    if target.advanceOn == "manual",
      target.instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        != target.label?.trimmingCharacters(in: .whitespacesAndNewlines),
      !target.instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    {
      let id = (highestAcceptedPreviewID ?? -1) + 1
      if reveal.append(unitID: id, text: target.instruction, isComplete: true) {
        highestAcceptedPreviewID = id
        showingGuidanceExplanation = true
        guidanceExplanationEvidence = ScreenEvidenceIdentity(evidence)
      }
    }
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
    if sceneVisit == nil, exclusionFrames().contains(where: { $0.contains(pointer) }) {
      panel.orderOut(nil)
    }
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
    validateGuidanceExplanation()
    if model.error != nil && model.cursorFailureGeneration != generation {
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
          clearPresentation(reason: .inputEnded)
        }
      }
    case .response:
      phase =
        model.state == "Speaking" && model.voice.hasPendingSpeech
        ? .speaking
        : (model.busy || model.voice.hasPendingSpeech || model.presentingExplanation
          ? .thinking : .idle)
      finishIfReady()
    case nil: break
    }
    renderNow()
    wake()
  }

  private func finishIfReady() {
    guard stage == .response, let model, !model.busy, !model.voice.hasPendingSpeech,
      !model.presentingExplanation, narration == nil,
      !reveal.hasPending, guidance == nil, sceneVisit == nil, dismissal == nil
    else { return }
    phase = .idle
    if reveal.visibleText.isEmpty {
      clearPresentation(reason: .responseCompleted)
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
        self.clearPresentation(reason: .captionDismissed)
        self.renderNow()
        self.wake()
      }
    }
  }

  private func clearPresentation(reason: SceneCursorVisitEndReason) {
    endSceneNodeVisit(reason: reason)
    abandonNarration()
    if guidance != nil {
      x = NotchSpring(lastBodyCenter.x, frequency: 38)
      y = NotchSpring(lastBodyCenter.y, frequency: 38)
    }
    generation = nil
    stage = nil
    isGuidance = false
    showingGuidanceExplanation = false
    guidanceExplanationEvidence = nil
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
    validateGuidanceExplanation()
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
    validateSceneNodeVisit()
    if guidance == nil && sceneVisit == nil {
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
      if var owned = narration {
        let previous = owned.visibleText
        if owned.advance(by: min(elapsed, 0.1), reduceMotion: reduceMotion) {
          word = nextWord(previous: previous, current: owned.visibleText)
        }
        narration = owned
      } else {
        let previous = reveal.visibleText
        let previousID = reveal.currentUnitID
        if reveal.advance(by: min(elapsed, 0.1), reduceMotion: reduceMotion) {
          word = nextWord(previous: previous, previousID: previousID, reveal: reveal)
        }
      }
    }
    finishIfReady()
    renderNow()
    completeLocalNarrationAfterSubmission(at: ProcessInfo.processInfo.systemUptime)
    if guidance == nil && sceneVisit == nil && x.isSettled && y.isSettled
      && !(narration?.hasRevealableText ?? reveal.hasRevealableText)
      && narration?.needsLocalCompletionTick != true
    {
      stopClock()
    }
  }

  private func renderNow() {
    validateGuidanceExplanation()
    validateSceneNodeVisit()
    guard preferences.enabled, !suspended else {
      endSceneNodeVisit(reason: suspended ? .suspended : .preferencesDisabled)
      abandonNarration()
      panel.orderOut(nil)
      return
    }
    let visibilityPoint = sceneVisit?.target ?? pointer
    guard !exclusionFrames().contains(where: { $0.contains(visibilityPoint) }) else {
      // A hidden view has no display-link callbacks to finish local pacing.
      // Local fallback releases its gate; real speech retains its owned caption
      // until its native callback, even if the pointer is parked in the notch.
      if narration?.nativeSpeech != true { abandonNarration() }
      panel.orderOut(nil)
      return
    }
    let now = ProcessInfo.processInfo.systemUptime
    var center = CGPoint(x: x.value, y: y.value)
    var rotation: CGFloat = 0
    var text =
      preferences.showReplies && (!isGuidance || showingGuidanceExplanation)
      ? (narration?.visibleText ?? reveal.visibleText) : ""
    if let visit = sceneVisit, let pose = visit.pose(at: now, reduceMotion: reduceMotion) {
      center = pose.point
      if pose.travelling { rotation = atan2(-pose.tangent.y, pose.tangent.x) }
    }
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
    var placement = CursorCompanionLayout.placement(
      anchor: center, bubbleSize: view.measure(text: visibleText, maxWidth: 300),
      display: screen.frame, visible: screen.visibleFrame, previous: lastPlacement)
    if sceneVisit != nil {
      placement = SceneCursorVisit.anchoring(placement, bodyCenter: center)
    }
    if let visit = sceneVisit, let bounds = currentSceneBounds(for: visit.authority),
      sceneVisit?.authority == visit.authority
    {
      placement = SceneCursorVisit.avoidingScene(
        placement, bounds: bounds, display: screen.frame, visible: screen.visibleFrame)
    }
    if lastRequestedWindowFrame != placement.frame || lastPlacement?.frame != panel.frame {
      panel.setFrame(placement.frame, display: false)
      lastRequestedWindowFrame = placement.frame
    }
    // The window server may round the requested fractional origin/size. Use
    // its accepted frame before submitting view-local layers, so the glyph
    // tip and caption keep their intended global logical-point coordinates.
    placement = CursorCompanionLayout.rebased(placement, windowFrame: panel.frame)
    lastPlacement = placement
    let acceptedViewFrame = CGRect(origin: .zero, size: panel.frame.size)
    if view.frame != acceptedViewFrame { view.frame = acceptedViewFrame }
    view.update(
      phase: phase, text: visibleText, level: model?.microphoneLevel ?? 0,
      bodyPoint: placement.bodyPoint, bubbleFrame: placement.bubbleFrame,
      rotation: rotation, reduceMotion: reduceMotion, word: guidance == nil ? word : nil)
    lastBodyCenter = CGPoint(
      x: placement.frame.minX + placement.bodyPoint.x,
      y: placement.frame.maxY - placement.bodyPoint.y)
    hasRenderedBody = true
    if !panel.isVisible { panel.orderFrontRegardless() }
    if guidance == nil, !firstGlyphRecorded, !visibleText.isEmpty {
      firstGlyphRecorded = true
      timing.firstGlyphRenderSubmissionMS = (now - beganAt) * 1_000
      model?.record("cursor.firstGlyph.renderSubmitted")
    }
  }

  /// A manual answer remains tied to its source after the pointing animation
  /// ends. Natural flight expiry keeps the answer; changed evidence/apps do not.
  private func validateGuidanceExplanation() {
    guard let source = guidanceExplanationEvidence else { return }
    guard generation == model?.taskGeneration, source.matches(model?.evidence),
      NSWorkspace.shared.frontmostApplication?.processIdentifier == source.foregroundPID
    else {
      if guidance != nil {
        guidance = nil
        x = NotchSpring(lastBodyCenter.x, frequency: 38)
        y = NotchSpring(lastBodyCenter.y, frequency: 38)
      }
      clearGuidanceExplanation()
      model?.record("cursor.guidance.explanationInvalidated")
      return
    }
  }

  private func clearGuidanceExplanation() {
    showingGuidanceExplanation = false
    guidanceExplanationEvidence = nil
    reveal.reset()
    highestAcceptedPreviewID = nil
    visibleText = ""
    word = nil
    cancelDismissal()
    view.reset()
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

  private func nextWord(previous: String, current: String) -> CursorCaptionWord {
    wordSerial &+= 1
    let appended = current.hasPrefix(previous) ? String(current.dropFirst(previous.count)) : current
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
    clearPresentation(reason: .shutdown)
    panel.orderOut(nil)
  }
}

private final class CursorCompanionPanel: NSPanel {
  override var canBecomeKey: Bool { false }
  override var canBecomeMain: Bool { false }
}
