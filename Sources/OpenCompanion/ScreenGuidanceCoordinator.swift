import AppKit
import Combine

/// Geometry and deadlines for passive click observation. A matching point is
/// evidence of a user click, never proof that the intended action succeeded.
enum ScreenGuidancePolicy {
  static let maximumSteps = 6
  static let maximumRequestLifetime: TimeInterval = 180
  static let admissionEvidenceAge: TimeInterval = 15
  static let markedTargetLifetime: TimeInterval = 45

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

  private static func permitsRequest(
    step: Int, requestExpires: TimeInterval, began: TimeInterval, now: TimeInterval
  ) -> Bool {
    (0..<maximumSteps).contains(step) && now.isFinite && began.isFinite && requestExpires.isFinite
      && began >= 0 && now >= began && requestExpires > now
      && requestExpires - began <= maximumRequestLifetime
  }
}

/// One deliberately admitted target, one observed user click, then one fresh
/// continuation request. This controller never injects input, captures screens,
/// performs AX work, stores pointer trails, or claims a click was successful.
@MainActor final class ScreenGuidanceCoordinator {
  private struct Mark {
    let lease: UUID
    let rect: CGRect
    let evidence: ScreenEvidenceIdentity
    let generation: UInt64
    let request: ScreenGuidanceRequest
    let admittedAt: TimeInterval
  }

  private weak var model: AppModel?
  private let observesInput: Bool
  private var preferences: CursorCompanionPreferences
  private var mark: Mark?
  private var globalMouse: Any?
  private var localMouse: Any?
  private var expiryTask: Task<Void, Never>?
  private var continuationTask: Task<Void, Never>?
  private var subscriptions = Set<AnyCancellable>()
  private var validationScheduled = false
  private var machineAwake = true
  private var sessionActive = true
  private var isShutdown = false

  init(model: AppModel, observeInput: Bool = true) {
    self.model = model
    observesInput = observeInput
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
    if target.advanceOn != "click" {
      // A response may add explanatory/manual marks after its one advancing
      // control. Those marks cannot replace click ownership on the same frame.
      if let owner = mark, owner.generation == generation, owner.request == request,
        owner.evidence == ScreenEvidenceIdentity(evidence), owns(owner)
      { return }
      cancel()
      return
    }
    cancel()
    let now = ProcessInfo.processInfo.systemUptime
    guard !isShutdown, machineAwake, sessionActive, preferences.screenGuidanceEnabled,
      let model,
      generation == model.taskGeneration,
      evidence.foregroundPID > 0,
      evidence.foregroundPID != ProcessInfo.processInfo.processIdentifier,
      ScreenEvidenceIdentity(evidence).matches(model.evidence),
      NSWorkspace.shared.frontmostApplication?.processIdentifier == evidence.foregroundPID,
      ScreenGuidancePolicy.permitsAdmission(
        step: request.step, requestExpires: request.expires, capturedAt: evidence.capturedAt, now: now),
      let rect = ScreenGuidancePolicy.targetRect(target, in: evidence.screenRect)
    else { return }
    let owner = Mark(
      lease: UUID(), rect: rect, evidence: ScreenEvidenceIdentity(evidence),
      generation: generation, request: request, admittedAt: now)
    mark = owner
    guard observesInput else { return }
    let lease = owner.lease
    globalMouse = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { [weak self] _ in
      // AppKit delivers event-monitor handlers on its main thread. Sample only
      // this mouse-up edge; do not record continuous pointer movement.
      MainActor.assumeIsolated {
        self?.mouseUp(at: NSEvent.mouseLocation, lease: lease)
      }
    }
    localMouse = NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp) { [weak self] event in
      MainActor.assumeIsolated {
        // A click delivered to one of our own nonactivating windows must not
        // count as a click through to an external app underneath that window.
        if event.window == nil { self?.mouseUp(at: NSEvent.mouseLocation, lease: lease) }
      }
      return event
    }
    guard globalMouse != nil else {
      model.record("guidance.clickObservation.unavailable")
      cancel()
      return
    }
    let deadline = min(
      request.expires, now + ScreenGuidancePolicy.markedTargetLifetime)
    expiryTask = Task { @MainActor [weak self] in
      do { try await Task.sleep(for: .seconds(max(0, deadline - now))) } catch { return }
      guard let self, self.mark?.lease == lease else { return }
      self.cancel()
    }
  }

  func cancel() {
    mark = nil
    removeClickMonitors()
    expiryTask?.cancel()
    expiryTask = nil
    continuationTask?.cancel()
    continuationTask = nil
  }

  func shutdown() {
    isShutdown = true
    cancel()
    subscriptions.removeAll()
  }

  private func mouseUp(at point: CGPoint, lease: UUID) {
    guard continuationTask == nil, let owner = mark, owner.lease == lease else { return }
    guard owns(owner) else { cancel(); return }
    guard point.x.isFinite, point.y.isFinite, owner.rect.contains(point) else { return }
    // Remove observation synchronously before queuing work. Repeated clicks,
    // queued old callbacks, or a subsequent target cannot schedule a second step.
    removeClickMonitors()
    expiryTask?.cancel()
    expiryTask = nil
    model?.record("guidance.userClick.observed")
    continuationTask = Task { @MainActor [weak self] in
      do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
      guard let self, self.mark?.lease == lease, !Task.isCancelled else { return }
      guard self.owns(owner), let model = self.model else { self.cancel(); return }
      self.mark = nil
      self.continuationTask = nil
      // A fresh capture and model verification belong to AppModel. This event
      // reports only that the user clicked inside the admitted target bounds.
      model.continueScreenGuidance(
        request: owner.request, expectedEvidence: owner.evidence, generation: owner.generation)
    }
  }

  private func owns(_ owner: Mark) -> Bool {
    guard !isShutdown, machineAwake, sessionActive, preferences.screenGuidanceEnabled,
      let model, owner.generation == model.taskGeneration,
      owner.evidence.matches(model.evidence),
      NSWorkspace.shared.frontmostApplication?.processIdentifier == owner.evidence.foregroundPID
    else { return false }
    return ScreenGuidancePolicy.permitsClick(
      step: owner.request.step, requestExpires: owner.request.expires,
      admittedAt: owner.admittedAt, now: ProcessInfo.processInfo.systemUptime)
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
