import AppKit
@preconcurrency import ApplicationServices
import Foundation

struct GuidanceAXResult: Sendable {
  let reason: GuidanceObservationEvent.Reason?
  let focusedBounds: CGRect?
}

/// Registers only the selected application's metadata notifications. Unknown
/// notifications/unsupported AX are covered by the scoped visual detector.
/// No AX title, help, description, value, text or child content is read here.
@MainActor final class GuidanceAXRegistration {
  private var resources: GuidanceAXResources?
  private var pump: GuidanceAXPump?
  private var invalidated = false
  private(set) var notificationCount = 0

  init?(
    scope: GuidanceObservationScope, sourceWindowBounds: CGRect?, primaryTop: Double,
    onChange: @escaping @MainActor @Sendable (GuidanceAXResult) -> Void
  ) {
    guard AXIsProcessTrusted(), primaryTop.isFinite else { return nil }
    let app = AXUIElementCreateApplication(scope.foregroundPID)
    AXUIElementSetMessagingTimeout(app, 0.05)
    var created: AXObserver?
    guard AXObserverCreate(scope.foregroundPID, Self.callback, &created) == .success,
      let created
    else { return nil }
    pump = GuidanceAXPump(
      scope: scope, app: app, sourceWindowBounds: sourceWindowBounds,
      primaryTop: primaryTop, onChange: onChange)
    let notifications: [CFString] = [
      kAXFocusedWindowChangedNotification as CFString, kAXMainWindowChangedNotification as CFString,
      kAXFocusedUIElementChangedNotification as CFString, kAXWindowCreatedNotification as CFString,
      kAXWindowMovedNotification as CFString, kAXWindowResizedNotification as CFString,
      kAXWindowMiniaturizedNotification as CFString,
      kAXWindowDeminiaturizedNotification as CFString,
      kAXUIElementDestroyedNotification as CFString, kAXMenuOpenedNotification as CFString,
      kAXMenuClosedNotification as CFString, kAXMenuItemSelectedNotification as CFString,
      kAXLayoutChangedNotification as CFString, kAXSelectedChildrenChangedNotification as CFString,
      kAXSelectedChildrenMovedNotification as CFString, kAXRowCountChangedNotification as CFString,
      kAXCreatedNotification as CFString, kAXMovedNotification as CFString,
      kAXResizedNotification as CFString,
      kAXTitleChangedNotification as CFString, kAXValueChangedNotification as CFString,
      kAXElementBusyChangedNotification as CFString,
    ]
    let owned = GuidanceAXResources(
      observer: created, app: app, names: notifications,
      context: GuidanceAXCallbackContext(owner: self))
    resources = owned
    owned.install { [weak self, owned] count in
      Task { @MainActor in
        guard let self, !self.invalidated, self.resources === owned, count > 0 else {
          owned.invalidate()
          return
        }
        self.notificationCount = count
        CFRunLoopAddSource(
          CFRunLoopGetMain(), AXObserverGetRunLoopSource(owned.observer), .commonModes)
        self.pump?.offer(element: owned.app, reason: nil)
      }
    }
  }

  func invalidate() {
    invalidated = true
    pump?.invalidate()
    pump = nil
    if let resources {
      let source = AXObserverGetRunLoopSource(resources.observer)
      CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
      CFRunLoopSourceInvalidate(source)
      resources.invalidate()
    }
    resources = nil
    notificationCount = 0
  }

  private nonisolated static let callback: AXObserverCallback = {
    _, element, notification, context in
    guard let context else { return }
    let box = Unmanaged<GuidanceAXCallbackContext>.fromOpaque(context).takeUnretainedValue()
    let name = notification as String
    // This observer's source is installed only on the main run loop and removed
    // synchronously before its retained registration/context can be released.
    MainActor.assumeIsolated {
      box.owner?.receive(element: element, notification: name)
    }
  }

  private func receive(element: AXUIElement, notification: String) {
    let reason: GuidanceObservationEvent.Reason
    switch notification {
    case "AXFocusedWindowChanged", "AXMainWindowChanged", "AXWindowCreated",
      "AXWindowMiniaturized", "AXWindowDeminiaturized", "AXUIElementDestroyed":
      reason = .windowChanged
    case "AXFocusedUIElementChanged": reason = .focusChanged
    case "AXWindowMoved", "AXWindowResized": reason = .geometryChanged
    case "AXMenuOpened", "AXMenuClosed", "AXMenuItemSelected": reason = .menuChanged
    case "AXValueChanged": reason = .typing
    default: reason = .layoutChanged
    }
    pump?.offer(element: element, reason: reason)
  }
}

private final class GuidanceAXCallbackContext: @unchecked Sendable {
  @MainActor weak var owner: GuidanceAXRegistration?
  @MainActor init(owner: GuidanceAXRegistration) { self.owner = owner }
}

/// AX subscription IPC is serialized away from the native event/render actor.
/// The MainActor owner alone connects or invalidates the CF source. Revocation
/// immediately prevents more subscriptions; queued cleanup cannot race an add.
private final class GuidanceAXResources: @unchecked Sendable {
  let observer: AXObserver
  let app: AXUIElement
  private let names: [CFString]
  private let context: GuidanceAXCallbackContext
  private let lock = NSLock()
  private let queue = DispatchQueue(
    label: "org.opencompanion.guidance.ax.registration", qos: .utility)
  private var active = true
  private var cleanupQueued = false
  private var registered: [CFString] = []

  init(
    observer: AXObserver, app: AXUIElement, names: [CFString], context: GuidanceAXCallbackContext
  ) {
    self.observer = observer
    self.app = app
    self.names = names
    self.context = context
  }

  func install(completion: @escaping @Sendable (Int) -> Void) {
    queue.async { [self] in
      for name in names {
        guard lock.withLock({ active }) else { break }
        if AXObserverAddNotification(
          observer, app, name, Unmanaged.passUnretained(context).toOpaque()) == .success
        {
          registered.append(name)
        }
      }
      completion(registered.count)
    }
  }

  func invalidate() {
    let schedule = lock.withLock {
      active = false
      guard !cleanupQueued else { return false }
      cleanupQueued = true
      return true
    }
    guard schedule else { return }
    queue.async { [self] in
      for name in registered { AXObserverRemoveNotification(observer, app, name) }
      registered.removeAll()
    }
  }

  deinit {
    // Core Foundation source teardown is thread safe. Retain the weak callback
    // box until after invalidation even when the explicit stop path was missed.
    let source = AXObserverGetRunLoopSource(observer)
    CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
    CFRunLoopSourceInvalidate(source)
  }
}

/// AX messaging stays off MainActor/native input callbacks. At most one worker,
/// one pending AX element, and one delivery exist. An element is never read for
/// a user value; only role/window/position/size/PID metadata is inspected.
private final class GuidanceAXPump: @unchecked Sendable {
  private struct Work: @unchecked Sendable {
    let element: AXUIElement
    let reason: GuidanceObservationEvent.Reason?
  }
  private let lock = NSLock()
  private let queue = DispatchQueue(label: "org.opencompanion.guidance.ax", qos: .userInitiated)
  private let scope: GuidanceObservationScope
  private let app: AXUIElement
  private let sourceWindowBounds: CGRect?
  private let primaryTop: Double
  private let onChange: @MainActor @Sendable (GuidanceAXResult) -> Void
  private var active = true
  private var working = false
  private var pending: Work?
  // Accessed exclusively by the serial worker queue.
  private var sourceWindow: AXUIElement?

  init(
    scope: GuidanceObservationScope, app: AXUIElement, sourceWindowBounds: CGRect?,
    primaryTop: Double, onChange: @escaping @MainActor @Sendable (GuidanceAXResult) -> Void
  ) {
    self.scope = scope
    self.app = app
    self.sourceWindowBounds = sourceWindowBounds
    self.primaryTop = primaryTop
    self.onChange = onChange
  }

  func offer(element: AXUIElement, reason: GuidanceObservationEvent.Reason?) {
    let schedule = lock.withLock {
      guard active else { return false }
      pending = Work(element: element, reason: reason)
      guard !working else { return false }
      working = true
      return true
    }
    if schedule { queue.async { [self] in processOne() } }
  }

  func invalidate() {
    lock.withLock {
      active = false
      pending = nil
    }
  }

  private func processOne() {
    let work = lock.withLock { () -> Work? in
      guard active else { return nil }
      let value = pending
      pending = nil
      return value
    }
    let result = work.flatMap(inspect)
    Task { @MainActor [self] in
      if lock.withLock({ active }), let result { onChange(result) }
      let again = lock.withLock {
        guard active, pending != nil else {
          working = false
          return false
        }
        return true
      }
      if again { queue.async { [self] in processOne() } }
    }
  }

  private func inspect(_ work: Work) -> GuidanceAXResult? {
    let deadline = ProcessInfo.processInfo.systemUptime + 0.25
    func read(_ element: AXUIElement, _ key: CFString) -> CFTypeRef? {
      guard lock.withLock({ active }), ProcessInfo.processInfo.systemUptime < deadline else {
        return nil
      }
      AXUIElementSetMessagingTimeout(element, 0.05)
      var value: CFTypeRef?
      guard AXUIElementCopyAttributeValue(element, key, &value) == .success else { return nil }
      return value
    }
    func window(_ element: AXUIElement) -> AXUIElement? {
      guard let value = read(element, kAXWindowAttribute as CFString),
        CFGetTypeID(value) == AXUIElementGetTypeID()
      else { return nil }
      return (value as! AXUIElement)
    }
    func bounds(_ element: AXUIElement) -> CGRect? {
      guard let position = read(element, kAXPositionAttribute as CFString),
        let size = read(element, kAXSizeAttribute as CFString),
        CFGetTypeID(position) == AXValueGetTypeID(),
        CFGetTypeID(size) == AXValueGetTypeID()
      else { return nil }
      let positionValue = position as! AXValue
      let sizeValue = size as! AXValue
      var point = CGPoint.zero
      var dimensions = CGSize.zero
      guard AXValueGetType(positionValue) == .cgPoint, AXValueGetType(sizeValue) == .cgSize,
        AXValueGetValue(positionValue, .cgPoint, &point),
        AXValueGetValue(sizeValue, .cgSize, &dimensions)
      else { return nil }
      let rect = CGRect(
        x: point.x, y: primaryTop - point.y - dimensions.height,
        width: dimensions.width, height: dimensions.height)
      return GuidanceObservationScope.valid(rect) ? rect : nil
    }
    func focusedWindow() -> AXUIElement? {
      guard let value = read(app, kAXFocusedWindowAttribute as CFString),
        CFGetTypeID(value) == AXUIElementGetTypeID()
      else { return nil }
      return (value as! AXUIElement)
    }
    var pid: pid_t = 0
    guard AXUIElementGetPid(work.element, &pid) == .success, pid == scope.foregroundPID else {
      return nil
    }
    if work.reason == nil || work.reason == .windowChanged {
      if let focused = focusedWindow(), let rect = bounds(focused) {
        if sourceWindow == nil, sourceWindowBounds == nil || rect == sourceWindowBounds {
          sourceWindow = focused
        }
        if work.reason == nil {
          return .init(reason: nil, focusedBounds: rect)
        }
        // A pinned source losing focus is a reason to pause, not permission to
        // observe the other window's content or widen the original rectangle.
        if let sourceWindow, scope.windowID != nil, !CFEqual(sourceWindow, focused) {
          return .init(reason: .windowChanged, focusedBounds: nil)
        }
        if scope.sourceRect.intersects(rect) {
          return .init(reason: .windowChanged, focusedBounds: rect)
        }
      }
      if let sourceWindow, CFEqual(sourceWindow, work.element) {
        return .init(reason: .windowChanged, focusedBounds: nil)
      }
      return nil
    }
    let role = read(work.element, kAXRoleAttribute as CFString) as? String
    let subrole = read(work.element, kAXSubroleAttribute as CFString) as? String
    guard role != "AXSecureTextField", subrole != "AXSecureTextField" else { return nil }
    if let sourceWindow, CFEqual(sourceWindow, work.element), work.reason == .geometryChanged {
      return .init(reason: .geometryChanged, focusedBounds: bounds(work.element))
    }
    let elementBounds = bounds(work.element)
    let enclosingWindow = role == "AXWindow" ? work.element : window(work.element)
    let enclosingBounds = enclosingWindow.flatMap(bounds)
    let directlyScoped = elementBounds.map { scope.sourceRect.intersects($0) } ?? false
    let windowScoped =
      enclosingWindow.map { candidate in
        sourceWindow.map { CFEqual($0, candidate) } ?? false
      } ?? false
    guard directlyScoped || (windowScoped && work.reason != .typing) else { return nil }
    return .init(reason: work.reason, focusedBounds: elementBounds ?? enclosingBounds)
  }
}
