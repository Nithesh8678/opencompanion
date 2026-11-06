import AppKit
import Combine
import CompanionCore

/// The observation requests fresh perception; neither case proves success.
enum ScreenGuidanceContinuationObservation: String, Sendable {
  case click
  case explicitContinue
}

/// Emitted only for a real mouse-up inside the currently owned click target.
/// The point records interaction, not control activation or task completion.
struct GuidanceUserClickObservation: Codable, Sendable {
  let point: CGPoint
  let targetRect: CGRect
  let frameID: UUID
  let generation: UInt64
  let requestID: UUID
  let checkStep: Int
}

struct ManualGuidanceStep: Identifiable, Sendable, Equatable {
  let id: UUID
  let label: String
  let instruction: String
  let evidence: ScreenEvidenceIdentity
  let generation: UInt64
  let request: ScreenGuidanceRequest
  let targetRect: CGRect
  let expiresAt: TimeInterval
}

/// One manual lease carried across the deliberate start of a new voice-input
/// generation. It never treats an arbitrary utterance as task completion.
struct ManualGuidanceVoiceContinuation: Sendable {
  let step: ManualGuidanceStep
  let inputGeneration: UInt64

  static func isContinueCommand(_ text: String) -> Bool {
    guard !text.isEmpty, text.utf8.prefix(257).count <= 256 else { return false }
    var command = text.lowercased().replacingOccurrences(of: "’", with: "'")
      .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    // Speech transcription may add sentence punctuation, but quoted commands,
    // negation, surrounding explanations and substring matches stay ordinary.
    while let last = command.last, last == "." || last == "!" || last == "?" {
      command.removeLast()
    }
    return [
      "continue", "please continue", "continue please", "done", "all done", "i'm done",
      "i am done", "next step", "the next step", "next step please",
      "please continue to the next step",
    ].contains(command)
  }

  func nextRequest(
    transcript: String, generation: UInt64, evidence: ScreenEvidence?, foregroundPID: pid_t?,
    now: TimeInterval
  ) -> ScreenGuidanceRequest? {
    guard Self.isContinueCommand(transcript), generation == inputGeneration,
      step.evidence.matches(evidence), let foregroundPID, foregroundPID > 0,
      step.request.selectedScope?.matches(evidence) ?? true,
      foregroundPID == step.evidence.foregroundPID,
      now.isFinite, now >= 0, step.expiresAt.isFinite, step.request.expires.isFinite,
      now < step.expiresAt, step.expiresAt <= step.request.expires,
      step.expiresAt - now <= ScreenGuidancePolicy.markedTargetLifetime,
      step.request.expires > now,
      step.request.expires - now <= ScreenGuidancePolicy.maximumRequestLifetime,
      ScreenGuidancePolicy.permitsContinuation(step: step.request.step)
    else { return nil }
    return ScreenGuidanceRequest(
      id: step.request.id, prompt: step.request.prompt, step: step.request.step + 1,
      expires: step.request.expires, speakAloud: step.request.speakAloud,
      selectedScope: step.request.selectedScope)
  }
}

/// Geometry and deadlines for passive click observation. A matching point is
/// evidence of a user click, never proof that the intended action succeeded.
enum ScreenGuidancePolicy {
  static let maximumSteps = GuidanceWorkflow.maximumActions
  static let maximumChecks = GuidanceWorkflow.maximumChecks
  static let maximumRequestLifetime: TimeInterval = 180
  static let admissionEvidenceAge: TimeInterval = 15
  static let markedTargetLifetime: TimeInterval = 45

  /// Quartz mouse-event locations use the primary display's top-left origin;
  /// AppKit uses global upward coordinates. Preserve negative display origins.
  static func appKitPoint(quartz point: CGPoint?, mainTop: CGFloat?) -> CGPoint? {
    guard let point, let mainTop, point.x.isFinite, point.y.isFinite, mainTop.isFinite else {
      return nil
    }
    let y = mainTop - point.y
    guard y.isFinite else { return nil }
    return CGPoint(x: point.x, y: y)
  }

  static func targetRect(_ target: ProviderTarget, in screen: CGRect) -> CGRect? {
    // CGRect's width/height getters standardize negative stored dimensions.
    // Validate the capture's raw size before deriving its coordinate bounds.
    let width = screen.size.width
    let height = screen.size.height
    guard screen.origin.x.isFinite, screen.origin.y.isFinite,
      width.isFinite, height.isFinite,
      width > 0, height > 0,
      width <= 100_000, height <= 100_000,
      abs(screen.minX) <= 10_000_000, abs(screen.minY) <= 10_000_000,
      screen.maxX.isFinite, screen.maxY.isFinite,
      target.x.isFinite, target.y.isFinite,
      target.width.isFinite, target.height.isFinite,
      target.x >= 0, target.y >= 0, target.width > 0, target.height > 0,
      target.x + target.width <= 1, target.y + target.height <= 1
    else { return nil }
    let rect = CGRect(
      x: screen.minX + target.x * width,
      y: screen.maxY - (target.y + target.height) * height,
      width: target.width * width, height: target.height * height)
    guard rect.origin.x.isFinite, rect.origin.y.isFinite,
      rect.width.isFinite, rect.height.isFinite
    else { return nil }
    return rect
  }

  static func permitsAdmission(
    step: Int, requestExpires: TimeInterval, capturedAt: TimeInterval, now: TimeInterval
  ) -> Bool {
    guard permitsRequest(step: step, requestExpires: requestExpires, began: now, now: now),
      capturedAt.isFinite, capturedAt >= 0, now >= capturedAt
    else { return false }
    return now - capturedAt < admissionEvidenceAge
  }

  static func permitsClick(
    step: Int, requestExpires: TimeInterval, admittedAt: TimeInterval, now: TimeInterval
  ) -> Bool {
    permitsRequest(step: step, requestExpires: requestExpires, began: admittedAt, now: now)
      && now - admittedAt < markedTargetLifetime
  }

  /// A final annotation may remain useful, but it cannot offer another step
  /// when the bounded check budget is exhausted; action admission has its own limit.
  static func permitsContinuation(step: Int) -> Bool {
    (0..<(maximumChecks - 1)).contains(step)
  }

  private static func permitsRequest(
    step: Int, requestExpires: TimeInterval, began: TimeInterval, now: TimeInterval
  ) -> Bool {
    (0..<maximumChecks).contains(step) && now.isFinite && began.isFinite && requestExpires.isFinite
      && began >= 0 && now >= began && requestExpires > now
      && requestExpires - began <= maximumRequestLifetime
  }
}

/// One deliberately admitted target, one observed click or explicit recheck,
/// then one fresh continuation request. This controller never injects input,
/// captures screens, performs AX work, or claims a user action was successful.
@MainActor final class ScreenGuidanceCoordinator: ObservableObject {
  typealias ContinuationHandler =
    @MainActor (
      ScreenGuidanceRequest, ScreenEvidenceIdentity, UInt64, ScreenGuidanceContinuationObservation
    ) -> Void

  private struct Mark {
    let lease: UUID
    let rect: CGRect
    let evidence: ScreenEvidenceIdentity
    let generation: UInt64
    let request: ScreenGuidanceRequest
    let admittedAt: TimeInterval
    let observation: ScreenGuidanceContinuationObservation
  }

  @Published private(set) var manualStep: ManualGuidanceStep?
  /// Optional read-only acceptance observation, after admission/ownership gates
  /// and before the explicit Continue consumes this exact lease. No input is
  /// synthesized; a revoked owner is checked again before continuation queues.
  var onManualContinueWillBegin: ((ManualGuidanceStep) -> Void)?
  /// Optional opt-in diagnostic. Outside-target points and keyboard events are
  /// never delivered; ordinary product operation does not persist this data.
  var onUserClickObserved: (@MainActor (GuidanceUserClickObservation) -> Void)?
  private weak var model: AppModel?
  private let observesInput: Bool
  private let now: @MainActor () -> TimeInterval
  private let foregroundPID: @MainActor () -> pid_t?
  private let settle: @MainActor () async throws -> Void
  private let windowVisibility: @MainActor (ScreenEvidence, CGRect) -> Bool
  private let onContinue: ContinuationHandler?
  private var preferences: CursorCompanionPreferences
  private var mark: Mark?
  private var selectedWindowClick = SelectedWindowClickHandoff()
  private var globalMouse: Any?
  private var localMouse: Any?
  private var expiryTask: Task<Void, Never>?
  private var continuationTask: Task<Void, Never>?
  private var notifyingManualContinue = false
  private var subscriptions = Set<AnyCancellable>()
  private var validationScheduled = false
  private var machineAwake = true
  private var sessionActive = true
  private var isShutdown = false

  init(
    model: AppModel, observeInput: Bool = true,
    now: @escaping @MainActor () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
    foregroundPID: @escaping @MainActor () -> pid_t? = {
      NSWorkspace.shared.frontmostApplication?.processIdentifier
    },
    settle: @escaping @MainActor () async throws -> Void = {
      try await Task.sleep(for: .milliseconds(300))
    },
    windowVisibility: @escaping @MainActor (ScreenEvidence, CGRect) -> Bool = { evidence, rect in
      GuidanceSelectedWindowCheck.permits(evidence: evidence, targetRect: rect)
    },
    onContinue: ContinuationHandler? = nil
  ) {
    self.model = model
    observesInput = observeInput
    self.now = now
    self.foregroundPID = foregroundPID
    self.settle = settle
    self.windowVisibility = windowVisibility
    self.onContinue = onContinue
    // Isolated acceptance fixtures do not consult saved preferences or observe
    // external application input/lifecycle events.
    preferences = observeInput ? .load() : .init()
    model.objectWillChange.sink { [weak self] in
      MainActor.assumeIsolated { self?.scheduleValidation() }
    }.store(in: &subscriptions)
    if observeInput { installLifecycleObservers() }
  }

  func accept(
    target: ProviderTarget, evidence: ScreenEvidence, generation: UInt64,
    request: ScreenGuidanceRequest
  ) {
    let isManual = target.advanceOn == "manual" && target.awaitUser == true
    if target.advanceOn != "click" {
      // Secondary annotations cannot replace the primary click/manual lease,
      // including while that lease has already queued its continuation.
      if let owner = mark, owner.generation == generation, owner.request == request,
        owner.evidence == ScreenEvidenceIdentity(evidence), owns(owner)
      {
        return
      }
      cancel()
      guard isManual, ScreenGuidancePolicy.permitsContinuation(step: request.step) else { return }
    } else {
      cancel()
    }
    let currentTime = now()
    guard !isShutdown, machineAwake, sessionActive, preferences.screenGuidanceEnabled,
      let model,
      generation == model.taskGeneration,
      evidence.foregroundPID > 0,
      evidence.foregroundPID != ProcessInfo.processInfo.processIdentifier,
      request.selectedScope?.matches(evidence) ?? true,
      request.selectedScope.map({ (try? model.currentSelectedGuidanceScope()) == $0 }) ?? true,
      ScreenEvidenceIdentity(evidence).matches(model.evidence),
      foregroundPID() == evidence.foregroundPID,
      ScreenGuidancePolicy.permitsAdmission(
        step: request.step, requestExpires: request.expires, capturedAt: evidence.capturedAt,
        now: currentTime),
      let rect = ScreenGuidancePolicy.targetRect(target, in: evidence.screenRect)
    else { return }
    if request.selectedScope?.windowID != nil, !windowVisibility(evidence, rect) { return }
    let owner = Mark(
      lease: UUID(), rect: rect, evidence: ScreenEvidenceIdentity(evidence),
      generation: generation, request: request, admittedAt: currentTime,
      observation: isManual ? .explicitContinue : .click)
    mark = owner
    if isManual {
      manualStep = ManualGuidanceStep(
        id: owner.lease,
        label: ScreenGrounding.firstNonemptyLabel([target.label, target.instruction]),
        instruction: ScreenGrounding.firstNonemptyLabel([target.instruction], limit: 1_000),
        evidence: owner.evidence, generation: generation, request: request, targetRect: rect,
        expiresAt: min(request.expires, currentTime + ScreenGuidancePolicy.markedTargetLifetime))
      model.record("guidance.manualContinuation.armed")
    } else {
      model.record("guidance.clickObservation.armed")
    }
    scheduleExpiry(for: owner)
    guard !isManual, observesInput else { return }
    let lease = owner.lease
    let edges: NSEvent.EventTypeMask = [.leftMouseDown, .leftMouseUp]
    globalMouse = NSEvent.addGlobalMonitorForEvents(matching: edges) { [weak self] event in
      // Use the actual edge's recorded location. A later live pointer sample can
      // already have moved away from the control by the time this handler runs.
      MainActor.assumeIsolated {
        self?.receiveMouseEvent(event, lease: lease)
      }
    }
    localMouse = NSEvent.addLocalMonitorForEvents(matching: edges) { [weak self] event in
      MainActor.assumeIsolated {
        // A click delivered to one of our own nonactivating windows must not
        // count as a click through to an external app underneath that window.
        if event.window == nil {
          self?.receiveMouseEvent(event, lease: lease)
        }
      }
      return event
    }
    guard globalMouse != nil else {
      model.record("guidance.clickObservation.unavailable")
      cancel()
      return
    }
  }

  /// Consumes only the currently presented lease. Repeated button callbacks,
  /// stale IDs and unrelated pointer events cannot queue another continuation.
  func continueManualStep(id: UUID) {
    guard !notifyingManualContinue, continuationTask == nil, let step = manualStep, step.id == id,
      let owner = mark,
      owner.lease == id, owner.observation == .explicitContinue
    else { return }
    guard owns(owner) else {
      cancel()
      return
    }
    notifyingManualContinue = true
    onManualContinueWillBegin?(step)
    notifyingManualContinue = false
    guard continuationTask == nil, manualStep?.id == id, mark?.lease == owner.lease,
      owns(owner)
    else { return }
    model?.record("guidance.manualContinue.requested")
    queueContinuation(owner)
  }

  /// Called before starting voice input cancels the current response generation.
  /// The caller must bind the returned lease to its new voice-input generation.
  func takeManualStepForVoice() -> ManualGuidanceStep? {
    guard continuationTask == nil, let step = manualStep, let owner = mark,
      step.id == owner.lease, owner.observation == .explicitContinue
    else { return nil }
    guard owns(owner) else {
      cancel()
      return nil
    }
    cancel()
    return step
  }

  private func scheduleExpiry(for owner: Mark) {
    let currentTime = now()
    let deadline = min(
      owner.request.expires, owner.admittedAt + ScreenGuidancePolicy.markedTargetLifetime)
    expiryTask = Task { @MainActor [weak self] in
      do { try await Task.sleep(for: .seconds(max(0, deadline - currentTime))) } catch { return }
      guard let self, self.mark?.lease == owner.lease else { return }
      self.model?.record("guidance.continuation.expired")
      self.cancel()
    }
  }

  func cancel() {
    mark = nil
    selectedWindowClick.clear()
    manualStep = nil
    removeClickMonitors()
    expiryTask?.cancel()
    expiryTask = nil
    continuationTask?.cancel()
    continuationTask = nil
  }

  func shutdown() {
    isShutdown = true
    cancel()
    onManualContinueWillBegin = nil
    onUserClickObserved = nil
    subscriptions.removeAll()
  }

  /// The read-only lease also scopes authored metadata ingestion. Neither the
  /// getter nor the receive methods install observers or synthesize input.
  var clickObservationLeaseID: UUID? {
    mark?.observation == .click ? mark?.lease : nil
  }

  private func receiveMouseEvent(_ event: NSEvent, lease: UUID) {
    let cgEvent = event.cgEvent
    let point = ScreenGuidancePolicy.appKitPoint(
      quartz: cgEvent?.location, mainTop: NSScreen.screens.first?.frame.maxY)
    let rawPID = cgEvent?.getIntegerValueField(.eventTargetUnixProcessID) ?? 0
    let targetPID: pid_t? = rawPID == 0 ? nil : (pid_t(exactly: rawPID) ?? -1)
    // Field 92 is public: the window that can handle this event. Field 91 is
    // intentionally not a fallback; it does not establish input destination.
    let rawWindow =
      cgEvent?.getIntegerValueField(
        .mouseEventWindowUnderMousePointerThatCanHandleThisEvent) ?? 0
    let handlingWindowID = rawWindow > 0 ? CGWindowID(exactly: rawWindow) : nil
    if event.type == .leftMouseDown {
      receiveMouseDown(
        at: point, timestamp: event.timestamp, eventTargetPID: targetPID,
        handlingWindowID: handlingWindowID, lease: lease)
    } else if event.type == .leftMouseUp {
      receiveMouseUp(
        at: point, timestamp: event.timestamp, eventTargetPID: targetPID,
        handlingWindowID: handlingWindowID, lease: lease)
    }
  }

  func receiveMouseDown(
    at point: CGPoint?, timestamp: TimeInterval, eventTargetPID: pid_t?,
    handlingWindowID: CGWindowID?, lease: UUID
  ) {
    guard continuationTask == nil, let owner = mark, owner.lease == lease,
      owner.observation == .click, owner.request.selectedScope?.windowID != nil
    else { return }
    guard owns(owner), let authority = selectedWindowAuthority(owner) else {
      selectedWindowClick.clear()
      cancel()
      return
    }
    selectedWindowClick.receiveDown(
      authority: authority, point: point, timestamp: timestamp,
      eventTargetPID: eventTargetPID, handlingWindowID: handlingWindowID)
  }

  func receiveMouseUp(
    at point: CGPoint?, timestamp: TimeInterval, eventTargetPID: pid_t?,
    handlingWindowID: CGWindowID?, lease: UUID
  ) {
    guard continuationTask == nil, let owner = mark, owner.lease == lease,
      owner.observation == .click
    else { return }
    model?.record("guidance.mouseUp.received")
    guard owns(owner) else {
      model?.record("guidance.clickObservation.ownershipLost")
      cancel()
      return
    }
    if owner.request.selectedScope?.windowID != nil {
      guard let authority = selectedWindowAuthority(owner),
        selectedWindowClick.receiveUp(
          authority: authority, point: point, timestamp: timestamp, eventTargetPID: eventTargetPID)
      else { return }
    }
    guard let point, point.x.isFinite, point.y.isFinite, owner.rect.contains(point) else { return }
    // The up's handling window is deliberately not required to equal the down
    // destination: a same-app menu may already have opened. No live window hit
    // query is performed here or during the subsequent settle interval.
    onUserClickObserved?(
      .init(
        point: point, targetRect: owner.rect, frameID: owner.evidence.frameID,
        generation: owner.generation, requestID: owner.request.id, checkStep: owner.request.step))
    guard continuationTask == nil, mark?.lease == owner.lease, owns(owner) else { return }
    model?.record("guidance.userClick.observed")
    queueContinuation(owner)
  }

  private func selectedWindowAuthority(_ owner: Mark) -> SelectedWindowClickHandoff.Authority? {
    guard let windowID = owner.request.selectedScope?.windowID else { return nil }
    return .init(
      lease: owner.lease, frameID: owner.evidence.frameID, generation: owner.generation,
      requestID: owner.request.id, step: owner.request.step,
      foregroundPID: owner.evidence.foregroundPID, windowID: windowID,
      targetRect: owner.rect, admittedAt: owner.admittedAt,
      deadline: min(
        owner.request.expires, owner.admittedAt + ScreenGuidancePolicy.markedTargetLifetime))
  }

  private func queueContinuation(_ owner: Mark) {
    // Clear presentation and observation before yielding. The retained private
    // lease protects the settle interval against cancellation and replacement.
    manualStep = nil
    selectedWindowClick.clear()
    removeClickMonitors()
    expiryTask?.cancel()
    expiryTask = nil
    continuationTask = Task { @MainActor [weak self] in
      guard let self else { return }
      do { try await self.settle() } catch {
        if self.mark?.lease == owner.lease { self.cancel() }
        return
      }
      guard self.mark?.lease == owner.lease, !Task.isCancelled else { return }
      guard self.owns(owner), let model = self.model else {
        self.cancel()
        return
      }
      self.mark = nil
      self.continuationTask = nil
      // AppModel owns fresh capture and postcondition verification. Explicit
      // Continue reports no click, typing, drag, or successful task completion.
      if let onContinue = self.onContinue {
        onContinue(owner.request, owner.evidence, owner.generation, owner.observation)
      } else {
        model.continueScreenGuidance(
          request: owner.request, expectedEvidence: owner.evidence, generation: owner.generation,
          observation: owner.observation)
      }
    }
  }

  private func owns(_ owner: Mark) -> Bool {
    guard !isShutdown, machineAwake, sessionActive, preferences.screenGuidanceEnabled,
      let model, owner.generation == model.taskGeneration,
      owner.evidence.matches(model.evidence),
      owner.request.selectedScope.map({ (try? model.currentSelectedGuidanceScope()) == $0 })
        ?? true,
      foregroundPID() == owner.evidence.foregroundPID
    else { return false }
    return ScreenGuidancePolicy.permitsClick(
      step: owner.request.step, requestExpires: owner.request.expires,
      admittedAt: owner.admittedAt, now: now())
  }

  private func removeClickMonitors() {
    if let globalMouse { NSEvent.removeMonitor(globalMouse) }
    if let localMouse { NSEvent.removeMonitor(localMouse) }
    globalMouse = nil
    localMouse = nil
  }

  private func scheduleValidation() {
    guard !validationScheduled, !isShutdown, mark != nil else { return }
    validationScheduled = true
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      self.validationScheduled = false
      if let owner = self.mark, !self.owns(owner) { self.cancel() }
    }
  }

  private func installLifecycleObservers() {
    NotificationCenter.default.publisher(for: .cursorCompanionPreferencesDidChange).sink {
      [weak self] _ in
      MainActor.assumeIsolated {
        guard let self else { return }
        self.preferences = .load()
        if !self.preferences.screenGuidanceEnabled { self.cancel() }
      }
    }.store(in: &subscriptions)
    NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
      .sink { [weak self] _ in MainActor.assumeIsolated { self?.cancel() } }
      .store(in: &subscriptions)
    let center = NSWorkspace.shared.notificationCenter
    center.publisher(for: NSWorkspace.didActivateApplicationNotification).sink { [weak self] _ in
      MainActor.assumeIsolated { self?.scheduleValidation() }
    }.store(in: &subscriptions)
    center.publisher(for: NSWorkspace.willSleepNotification).sink { [weak self] _ in
      MainActor.assumeIsolated {
        self?.machineAwake = false
        self?.cancel()
      }
    }.store(in: &subscriptions)
    center.publisher(for: NSWorkspace.sessionDidResignActiveNotification).sink { [weak self] _ in
      MainActor.assumeIsolated {
        self?.sessionActive = false
        self?.cancel()
      }
    }.store(in: &subscriptions)
    center.publisher(for: NSWorkspace.didWakeNotification).sink { [weak self] _ in
      MainActor.assumeIsolated { self?.machineAwake = true }
    }.store(in: &subscriptions)
    center.publisher(for: NSWorkspace.sessionDidBecomeActiveNotification).sink { [weak self] _ in
      MainActor.assumeIsolated { self?.sessionActive = true }
    }.store(in: &subscriptions)
  }
}
