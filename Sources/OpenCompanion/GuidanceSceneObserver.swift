import AppKit
import Foundation

enum GuidanceSceneChange: String, Sendable {
  case foregroundChanged
  case scroll
  case expired
  case displayChanged
}

/// Ephemeral scope only. This value is never saved as workflow progress or
/// substituted for the host's current frame/generation authority.
struct GuidanceSceneScope: Equatable, Sendable {
  let leaseID: UUID
  let generation: UInt64
  let foregroundPID: pid_t
  let sourceRect: CGRect
}

/// Observes only while armed. It reads event metadata, never captures pixels,
/// inspects Accessibility, makes a request, or forwards/posts desktop input.
/// Its owner must disarm on cancellation and teardown.
@MainActor final class GuidanceSceneObserver {
  private let observesSystemEvents: Bool
  private let onChange: @MainActor (GuidanceSceneScope, GuidanceSceneChange) -> Void
  private var scope: GuidanceSceneScope?
  private var activationObserver: NSObjectProtocol?
  private var globalScroll: Any?
  private var localScroll: Any?

  init(
    observeSystemEvents: Bool = true,
    onChange: @escaping @MainActor (GuidanceSceneScope, GuidanceSceneChange) -> Void
  ) {
    observesSystemEvents = observeSystemEvents
    self.onChange = onChange
  }

  @discardableResult
  func arm(generation: UInt64, foregroundPID: pid_t, sourceRect: CGRect) -> GuidanceSceneScope? {
    disarm()
    // CGRect width/height accessors standardize negative raw sizes. Validate
    // the stored size and bounded extents before using containment instead.
    guard foregroundPID > 0, foregroundPID != ProcessInfo.processInfo.processIdentifier,
      sourceRect.origin.x.isFinite, sourceRect.origin.y.isFinite,
      sourceRect.size.width.isFinite, sourceRect.size.height.isFinite,
      sourceRect.size.width > 0, sourceRect.size.height > 0,
      sourceRect.size.width <= 100_000, sourceRect.size.height <= 100_000,
      abs(sourceRect.origin.x) <= 10_000_000, abs(sourceRect.origin.y) <= 10_000_000,
      sourceRect.maxX.isFinite, sourceRect.maxY.isFinite
    else { return nil }
    let armed = GuidanceSceneScope(
      leaseID: UUID(), generation: generation, foregroundPID: foregroundPID, sourceRect: sourceRect)
    scope = armed
    if observesSystemEvents, !install(for: armed) {
      disarm()
      return nil
    }
    return armed
  }

  func disarm() {
    scope = nil
    if let activationObserver {
      NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
    }
    activationObserver = nil
    if let globalScroll { NSEvent.removeMonitor(globalScroll) }
    if let localScroll { NSEvent.removeMonitor(localScroll) }
    globalScroll = nil
    localScroll = nil
  }

  func receiveActivation(pid: pid_t?) {
    guard let scope else { return }
    receiveActivation(pid: pid, leaseID: scope.leaseID)
  }

  /// Native callbacks use the lease captured when installed, not whichever
  /// scope happens to be current when an already queued event is delivered.
  func receiveActivation(pid: pid_t?, leaseID: UUID) {
    guard let scope, scope.leaseID == leaseID, pid != scope.foregroundPID else { return }
    revoke(scope, reason: .foregroundChanged)
  }

  func receiveScroll(
    point: CGPoint?, deltaX: Double, deltaY: Double, foregroundPID: pid_t?, ownWindow: Bool
  ) {
    guard let scope else { return }
    receiveScroll(
      point: point, deltaX: deltaX, deltaY: deltaY, foregroundPID: foregroundPID,
      ownWindow: ownWindow, leaseID: scope.leaseID)
  }

  func receiveScroll(
    point: CGPoint?, deltaX: Double, deltaY: Double, foregroundPID: pid_t?, ownWindow: Bool,
    leaseID: UUID
  ) {
    guard let scope, scope.leaseID == leaseID, !ownWindow,
      foregroundPID == scope.foregroundPID,
      let point, point.x.isFinite, point.y.isFinite,
      deltaX.isFinite, deltaY.isFinite, deltaX != 0 || deltaY != 0,
      scope.sourceRect.contains(point)
    else { return }
    revoke(scope, reason: .scroll)
  }

  private func revoke(_ owner: GuidanceSceneScope, reason: GuidanceSceneChange) {
    guard scope == owner else { return }
    // Remove all observations before invoking the host. A callback may arm a
    // new lease; no cleanup after it is allowed to remove that replacement.
    disarm()
    onChange(owner, reason)
  }

  private func install(for owner: GuidanceSceneScope) -> Bool {
    activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
    ) { [weak self] notification in
      // OperationQueue.main delivers this observer on the main thread. Read
      // the recorded PID: sampling the later foreground would miss an A → B → A
      // transition while preparation is awaiting completion.
      let pid =
        (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?
        .processIdentifier
      MainActor.assumeIsolated {
        self?.receiveActivation(pid: pid, leaseID: owner.leaseID)
      }
    }
    globalScroll = NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
      // AppKit event monitor handlers are delivered on the main thread.
      MainActor.assumeIsolated {
        let point = ScreenGuidancePolicy.appKitPoint(
          quartz: event.cgEvent?.location, mainTop: NSScreen.screens.first?.frame.maxY)
        self?.receiveScroll(
          point: point, deltaX: Double(event.scrollingDeltaX),
          deltaY: Double(event.scrollingDeltaY),
          foregroundPID: NSWorkspace.shared.frontmostApplication?.processIdentifier,
          ownWindow: false, leaseID: owner.leaseID)
      }
    }
    localScroll = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
      MainActor.assumeIsolated {
        let point = ScreenGuidancePolicy.appKitPoint(
          quartz: event.cgEvent?.location, mainTop: NSScreen.screens.first?.frame.maxY)
        self?.receiveScroll(
          point: point, deltaX: Double(event.scrollingDeltaX),
          deltaY: Double(event.scrollingDeltaY),
          foregroundPID: NSWorkspace.shared.frontmostApplication?.processIdentifier,
          ownWindow: event.window != nil, leaseID: owner.leaseID)
      }
      return event
    }
    return activationObserver != nil && globalScroll != nil && localScroll != nil
  }
}
