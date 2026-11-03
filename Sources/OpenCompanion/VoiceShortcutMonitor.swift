import AppKit
import ApplicationServices
import Combine
import CoreGraphics

/// Only modifier categories and a transient ordinary-key count are retained.
/// Key codes, characters, event objects and typed content are never retained.
struct VoiceChordModifiers: OptionSet, Sendable, Equatable {
  let rawValue: UInt8
  static let control = Self(rawValue: 1 << 0)
  static let option = Self(rawValue: 1 << 1)
  static let command = Self(rawValue: 1 << 2)
  static let shift = Self(rawValue: 1 << 3)
  static let function = Self(rawValue: 1 << 4)
  static let chord: Self = [.control, .option]

  init(rawValue: UInt8) { self.rawValue = rawValue }
  init(flags: CGEventFlags) {
    var value: Self = []
    if flags.contains(.maskControl) { value.insert(.control) }
    if flags.contains(.maskAlternate) { value.insert(.option) }
    if flags.contains(.maskCommand) { value.insert(.command) }
    if flags.contains(.maskShift) { value.insert(.shift) }
    if flags.contains(.maskSecondaryFn) { value.insert(.function) }
    self = value
    // Caps Lock and numeric-pad device bits do not alter the hold chord.
  }
}

enum VoiceShortcutCancellation: String, Sendable {
  case anotherKey, unexpectedModifiers, systemSleep, sessionInactive
  case monitorUnavailable, teardown, manualStop
}

enum VoiceHoldEdge: Sendable, Equatable {
  case pressed, released
  case cancelled(VoiceShortcutCancellation)
}

/// Pure gesture logic; independent of AppKit permissions, audio and the library.
struct VoiceHoldStateMachine: Sendable {
  private(set) var isHolding = false
  private(set) var suppressedUntilRelease = false
  private var modifiers: VoiceChordModifiers = []
  private var ordinaryKeysDown = 0

  mutating func beginObserving(modifiers: VoiceChordModifiers) {
    self.modifiers = modifiers
    isHolding = false
    ordinaryKeysDown = 0
    suppressedUntilRelease = !modifiers.intersection(.chord).isEmpty
  }

  mutating func flagsChanged(_ value: VoiceChordModifiers) -> VoiceHoldEdge? {
    modifiers = value
    if value.intersection(.chord).isEmpty { suppressedUntilRelease = false }
    let exact = value == .chord
    if isHolding {
      if !value.subtracting(.chord).isEmpty {
        return cancel(.unexpectedModifiers)
      }
      if !exact {
        isHolding = false
        return .released
      }
      return nil
    }
    if !value.subtracting(.chord).isEmpty && !value.intersection(.chord).isEmpty {
      suppressedUntilRelease = true
    }
    if ordinaryKeysDown > 0 && !value.intersection(.chord).isEmpty { suppressedUntilRelease = true }
    guard exact, ordinaryKeysDown == 0, !suppressedUntilRelease else { return nil }
    isHolding = true
    return .pressed
  }

  mutating func ordinaryKeyDown(isRepeat: Bool) -> VoiceHoldEdge? {
    if !isRepeat { ordinaryKeysDown = min(64, ordinaryKeysDown + 1) }
    if !modifiers.intersection(.chord).isEmpty { suppressedUntilRelease = true }
    return cancel(.anotherKey)
  }

  mutating func ordinaryKeyUp() { ordinaryKeysDown = max(0, ordinaryKeysDown - 1) }

  mutating func cancel(_ reason: VoiceShortcutCancellation) -> VoiceHoldEdge? {
    if !modifiers.intersection(.chord).isEmpty { suppressedUntilRelease = true }
    guard isHolding else { return nil }
    isHolding = false
    return .cancelled(reason)
  }
}

enum VoiceShortcutAvailability: Equatable, Sendable {
  case disabled, available
  case unavailable(String)
  var isInstalled: Bool { self == .available }
  var statusText: String {
    switch self {
    case .disabled: "Hold-to-talk shortcut is off. The Talk button is available."
    case .available: "Hold Control + Option to talk. Release either modifier to finish."
    case .unavailable(let reason): reason
    }
  }
}

/// A passive session event tap receives global and own-app modifier transitions.
/// It never suppresses, edits or reposts keyboard events. This is intentionally
/// separate from Carbon's configurable text/open shortcut.
@MainActor final class VoiceShortcutMonitor: ObservableObject {
  typealias Action = @MainActor @Sendable () -> Void
  typealias CancelAction = @MainActor @Sendable (VoiceShortcutCancellation) -> Void
  @Published private(set) var availability: VoiceShortcutAvailability = .disabled
  var isObservationInstalled: Bool { availability.isInstalled }
  var status: String { availability.statusText }
  private var registration: VoiceTapRegistration?
  private var machine = VoiceHoldStateMachine()
  private var lifecycleGeneration: UInt64 = 0
  private var holdSequence: UInt64 = 0
  private var currentHold: UInt64?
  private var deliveredHold: UInt64?
  private var onPressed: Action?
  private var onReleased: Action?
  private var onCancelled: CancelAction?

  @discardableResult func start(
    enabled: Bool = true, onPressed: @escaping Action, onReleased: @escaping Action,
    onCancelled: @escaping CancelAction
  ) -> VoiceShortcutAvailability {
    stop()
    self.onPressed = onPressed
    self.onReleased = onReleased
    self.onCancelled = onCancelled
    guard enabled else {
      availability = .disabled
      return availability
    }
    guard CGPreflightListenEventAccess() || AXIsProcessTrusted() else {
      availability = .unavailable(Self.permissionMessage)
      return availability
    }
    let context = VoiceTapContext(owner: self)
    let mask =
      (CGEventMask(1) << CGEventType.flagsChanged.rawValue)
      | (CGEventMask(1) << CGEventType.keyDown.rawValue)
      | (CGEventMask(1) << CGEventType.keyUp.rawValue)
    guard
      let tap = CGEvent.tapCreate(
        tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
        eventsOfInterest: mask, callback: Self.tapCallback,
        userInfo: Unmanaged.passUnretained(context).toOpaque()),
      let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
    else {
      availability = .unavailable(Self.permissionMessage)
      return availability
    }
    let owned = VoiceTapRegistration(tap: tap, source: source, context: context)
    registration = owned
    CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    CGEvent.tapEnable(tap: tap, enable: true)
    guard CGEvent.tapIsEnabled(tap: tap) else {
      registration = nil
      availability = .unavailable(Self.permissionMessage)
      return availability
    }
    machine.beginObserving(modifiers: .init(flags: CGEventSource.flagsState(.combinedSessionState)))
    availability = .available
    installLifecycleObservers()
    let health = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.checkHealth() }
    }
    owned.healthTimer = health
    RunLoop.main.add(health, forMode: .common)
    return availability
  }

  func stop() {
    lifecycleGeneration &+= 1
    _ = machine.cancel(.teardown)
    currentHold = nil
    let wasDelivered = deliveredHold != nil
    deliveredHold = nil
    registration = nil
    availability = .disabled
    if wasDelivered { onCancelled?(.teardown) }
    onPressed = nil
    onReleased = nil
    onCancelled = nil
  }

  func cancelActive(reason: VoiceShortcutCancellation = .manualStop) {
    // Invalidate queued begin/end deliveries too: Stop after physical release
    // must not allow an already-enqueued release to submit the transcript.
    lifecycleGeneration &+= 1
    _ = machine.cancel(reason)
    currentHold = nil
    let wasDelivered = deliveredHold != nil
    deliveredHold = nil
    if wasDelivered { onCancelled?(reason) }
  }

  @discardableResult static func requestListenPermission() -> Bool { CGRequestListenEventAccess() }

  static let permissionMessage =
    "Global hold-to-talk is unavailable. Enable OpenCompanion in System Settings → Privacy & Security → Input Monitoring, then restart the app. Accessibility access may also be required by macOS. The Talk button and text shortcut still work."

  private nonisolated static let tapCallback: CGEventTapCallBack = { _, type, event, info in
    guard let info else { return Unmanaged.passUnretained(event) }
    let context = Unmanaged<VoiceTapContext>.fromOpaque(info).takeUnretainedValue()
    let flags = VoiceChordModifiers(flags: event.flags)
    let repeated = type == .keyDown && event.getIntegerValueField(.keyboardEventAutorepeat) != 0
    // This source is attached only to the main run loop. Do not pass CGEvent to
    // another actor/task; only the bounded modifier state and event kind escape.
    let owner = context.owner
    MainActor.assumeIsolated { owner?.consume(type: type, modifiers: flags, repeated: repeated) }
    return Unmanaged.passUnretained(event)
  }

  private func consume(type: CGEventType, modifiers: VoiceChordModifiers, repeated: Bool) {
    guard registration != nil else { return }
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
      loseObservation()
      return
    }
    guard availability.isInstalled else { return }
    let edge: VoiceHoldEdge?
    switch type {
    case .flagsChanged: edge = machine.flagsChanged(modifiers)
    case .keyDown: edge = machine.ordinaryKeyDown(isRepeat: repeated)
    case .keyUp:
      machine.ordinaryKeyUp()
      edge = nil
    default: edge = nil
    }
    if let edge { deliver(edge) }
  }

  private func deliver(_ edge: VoiceHoldEdge) {
    let generation = lifecycleGeneration
    switch edge {
    case .pressed:
      holdSequence &+= 1
      let token = holdSequence
      currentHold = token
      Task { @MainActor [weak self] in
        guard let self, self.lifecycleGeneration == generation, self.currentHold == token,
          self.machine.isHolding, self.availability.isInstalled
        else { return }
        self.deliveredHold = token
        self.onPressed?()
      }
    case .released, .cancelled:
      let token = currentHold
      currentHold = nil
      Task { @MainActor [weak self] in
        guard let self, self.lifecycleGeneration == generation, let token,
          self.deliveredHold == token
        else { return }
        self.deliveredHold = nil
        if case .cancelled(let reason) = edge {
          self.onCancelled?(reason)
        } else {
          self.onReleased?()
        }
      }
    }
  }

  private func loseObservation() {
    lifecycleGeneration &+= 1
    _ = machine.cancel(.monitorUnavailable)
    // Cancellation callbacks remain outside the C event-tap callback. Cancel
    // pending release delivery before it can be mistaken for a valid finish.
    currentHold = deliveredHold
    if deliveredHold != nil { deliver(.cancelled(.monitorUnavailable)) }
    availability = .unavailable(
      "Global hold-to-talk stopped receiving events. Check Input Monitoring permission, then disable and re-enable the voice shortcut or restart the app. The Talk button is available."
    )
    if let registration { CGEvent.tapEnable(tap: registration.tap, enable: false) }
  }

  private func checkHealth() {
    guard let registration, availability.isInstalled else { return }
    if !CGEvent.tapIsEnabled(tap: registration.tap)
      || (!CGPreflightListenEventAccess() && !AXIsProcessTrusted())
    {
      loseObservation()
    }
  }

  private func installLifecycleObservers() {
    let center = NSWorkspace.shared.notificationCenter
    for name in [
      NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification,
      NSWorkspace.sessionDidResignActiveNotification,
    ] {
      let observer = center.addObserver(forName: name, object: nil, queue: .main) {
        [weak self] notification in
        let reason: VoiceShortcutCancellation =
          notification.name == NSWorkspace.sessionDidResignActiveNotification
          ? .sessionInactive : .systemSleep
        Task { @MainActor [weak self] in self?.cancelActive(reason: reason) }
      }
      registration?.observers.append((center, observer))
    }
    for name in [NSWorkspace.didWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
      let observer = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
        Task { @MainActor [weak self] in
          guard let self else { return }
          self.cancelActive(reason: .sessionInactive)
          self.machine.beginObserving(
            modifiers: .init(flags: CGEventSource.flagsState(.combinedSessionState)))
          self.checkHealth()
        }
      }
      registration?.observers.append((center, observer))
    }
    // Ordinary foreground-app changes are expected during global hold-to-talk;
    // they deliberately do not cancel or activate the companion.
  }

  deinit {
    let callback = onCancelled
    if deliveredHold != nil { Task { @MainActor in callback?(.teardown) } }
  }
}

/// The callback context outlives the port and weakly references its UI owner.
/// CF teardown stays valid even if the monitor owner is released without stop().
private final class VoiceTapContext {
  weak var owner: VoiceShortcutMonitor?
  init(owner: VoiceShortcutMonitor) { self.owner = owner }
}

private final class VoiceTapRegistration {
  let tap: CFMachPort
  let source: CFRunLoopSource
  let context: VoiceTapContext
  var healthTimer: Timer?
  var observers: [(NotificationCenter, NSObjectProtocol)] = []
  init(tap: CFMachPort, source: CFRunLoopSource, context: VoiceTapContext) {
    self.tap = tap
    self.source = source
    self.context = context
  }
  deinit {
    healthTimer?.invalidate()
    for (center, observer) in observers { center.removeObserver(observer) }
    CGEvent.tapEnable(tap: tap, enable: false)
    CFMachPortInvalidate(tap)
    CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
  }
}
