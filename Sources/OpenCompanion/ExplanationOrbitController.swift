import AppKit
import ApplicationServices

/// Bounded, content-free input ownership diagnostics. No raw events, key codes,
/// model output, screen pixels or coordinates are retained here.
struct ExplanationOrbitDiagnostics: Codable, Sendable {
  let phase: String
  let observationAvailable: Bool
  let tapEnabled: Bool
  let observedModifiers: Int
  let optionPresses: Int
  let optionReleases: Int
  let pointerEvents: Int
  let starts: Int
  let ends: Int
  let cancels: Int
  let dragEvents: Int
  let scrollStarts: Int
  let scrollEnds: Int
  let scrollCancels: Int
  let scrollEvents: Int
  let localScrollAvailable: Bool
  let panelIgnoresMouseEvents: Bool
  let canvasArmed: Bool
}

/// The visible card owns only its bounded native window. Two-finger scroll is
/// handled locally without a permission prompt; global observation remains only
/// for the optional Option-drag fallback. No input is reposted or synthesized.
@MainActor final class ExplanationOrbitController {
  typealias Authority = ExplanationOrbitState.Authority
  private weak var canvas: RetainedCanvasView?
  private weak var panel: AnnotationPanel?
  private let authority: @MainActor () -> Authority?
  private let available: @MainActor () -> Bool
  private let onPhaseChange: @MainActor (ExplanationOrbitState.Phase) -> Void
  private let observeInput: Bool
  private let reduceMotion: @MainActor () -> Bool
  private var state = ExplanationOrbitState()
  private var registration: ExplanationOrbitTapRegistration?
  private var globalMouse: Any?
  private var localMouse: Any?
  private var closed = false
  private var applying = false
  private var pointerRefreshScheduled = false
  private var lastPointerRefresh = 0.0
  private var manualInput:
    (CGPoint, ExplanationOrbitState.Modifiers, ExplanationOrbitState.Buttons)?
  private var observedModifiers = 0
  private var optionPresses = 0
  private var optionReleases = 0
  private var lastObservedOption = false
  private var pointerEvents = 0
  private var starts = 0
  private var ends = 0
  private var cancels = 0
  private var lastPhase = ExplanationOrbitState.Phase.passive
  private var scrollEndTimer: Timer?
  private var scrollTimerAuthority: Authority?
  private var latestModifiers: ExplanationOrbitState.Modifiers = []
  private var lastObservedAuthority: Authority?
  private var authorityObservedAt = ProcessInfo.processInfo.systemUptime
  private var scrollStarts = 0
  private var scrollEnds = 0
  private var scrollCancels = 0
  private var scrollEvents = 0

  init(
    canvas: RetainedCanvasView, panel: AnnotationPanel, observeInput: Bool = true,
    authority: @escaping @MainActor () -> Authority?,
    available: @escaping @MainActor () -> Bool,
    reduceMotion: @escaping @MainActor () -> Bool = {
      NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    },
    onPhaseChange: @escaping @MainActor (ExplanationOrbitState.Phase) -> Void = { _ in }
  ) {
    self.canvas = canvas
    self.panel = panel
    self.observeInput = observeInput
    self.authority = authority
    self.available = available
    self.reduceMotion = reduceMotion
    self.onPhaseChange = onPhaseChange
    canvas.shouldBeginOverlayCameraInteraction = { [weak self] point, flags in
      self?.begin(atCanvasPoint: point, flags: flags) == true
    }
    canvas.onOverlayCameraInteraction = { [weak self] event in self?.cameraInteraction(event) }
    canvas.onOverlayScrollInteraction = { [weak self] event in
      self?.consumeScrollEvent(event) == true
    }
    lastObservedAuthority = authority()
    if observeInput { installObservation() }
    applyOwnership()
  }

  var diagnostics: ExplanationOrbitDiagnostics {
    .init(
      phase: state.phase.rawValue, observationAvailable: observationAvailable,
      tapEnabled: registration.map { CGEvent.tapIsEnabled(tap: $0.tap) } ?? false,
      observedModifiers: observedModifiers, optionPresses: optionPresses,
      optionReleases: optionReleases, pointerEvents: pointerEvents,
      starts: starts, ends: ends, cancels: cancels,
      dragEvents: canvas?.overlayCameraDragEventCount ?? 0,
      scrollStarts: scrollStarts, scrollEnds: scrollEnds, scrollCancels: scrollCancels,
      scrollEvents: scrollEvents,
      localScrollAvailable: surfaceAvailable && canvas?.spatialStage != nil,
      panelIgnoresMouseEvents: panel?.ignoresMouseEvents ?? true,
      canvasArmed: canvas?.overlayCameraArmed ?? false)
  }

  private var observationAvailable: Bool {
    if !observeInput { return manualInput != nil && !closed }
    return !closed && registration.map { CGEvent.tapIsEnabled(tap: $0.tap) } == true
  }

  func refresh() {
    guard !closed else { return }
    let values = currentInputValues()
    reconcile(input(pointer: values.0, modifiers: values.1, buttons: values.2))
    applyOwnership()
  }

  /// Authored own-view acceptance only. This does not post a system event or
  /// claim real external modifier delivery; production installs live monitors.
  func reconcileForAcceptance(
    pointer: CGPoint, modifiers: ExplanationOrbitState.Modifiers,
    buttons: ExplanationOrbitState.Buttons
  ) {
    guard !observeInput, !closed else { return }
    manualInput = (pointer, modifiers, buttons)
    refresh()
  }

  func shutdown() {
    guard !closed else { return }
    closed = true
    cancelScrollTimer()
    state.cancel()
    applyOwnership()
    canvas?.shouldBeginOverlayCameraInteraction = nil
    canvas?.onOverlayCameraInteraction = nil
    canvas?.onOverlayScrollInteraction = nil
    if let globalMouse { NSEvent.removeMonitor(globalMouse) }
    if let localMouse { NSEvent.removeMonitor(localMouse) }
    globalMouse = nil
    localMouse = nil
    registration = nil
    manualInput = nil
  }

  private func input(
    pointer: CGPoint, modifiers: ExplanationOrbitState.Modifiers,
    buttons: ExplanationOrbitState.Buttons, canvasPoint: CGPoint? = nil,
    requireFreshHit: Bool = false, forLocalScroll: Bool = false
  ) -> ExplanationOrbitState.Input {
    latestModifiers = modifiers
    let current = authority()
    if current != lastObservedAuthority {
      lastObservedAuthority = current
      authorityObservedAt = ProcessInfo.processInfo.systemUptime
    }
    let visible = panel?.isVisible == true && canvas?.window === panel
    let isAvailable = available()
    var hit = false
    // No scene ray work for ordinary pointer use or a retained admitted drag.
    let optionOnly = modifiers.subtracting([.capsLock, .numericPad]) == .option
    if optionOnly, state.phase != .dragging || requireFreshHit, visible, observationAvailable,
      isAvailable, let canvas, let panel
    {
      let local = canvasPoint ?? canvas.convert(panel.convertPoint(fromScreen: pointer), from: nil)
      hit = canvas.visibleSpatialMesh(atCanvasPoint: local) != nil
    } else if let canvasPoint, optionOnly, let canvas {
      hit = canvas.visibleSpatialMesh(atCanvasPoint: canvasPoint) != nil
    }
    let localPoint: CGPoint? = {
      guard let canvas, let panel else { return nil }
      return canvasPoint ?? canvas.convert(panel.convertPoint(fromScreen: pointer), from: nil)
    }()
    let inside =
      localPoint.map { point in
        point.x.isFinite && point.y.isFinite && canvas?.bounds.contains(point) == true
      } ?? false
    return .init(
      authority: current, modifiers: modifiers, buttons: buttons,
      presentationVisible: visible, awake: isAvailable, sessionActive: isAvailable,
      displayAvailable: current != nil,
      spatialReady: (forLocalScroll || state.phase == .scrolling || observationAvailable)
        && canvas?.spatialStage != nil,
      pointerOnVisibleMesh: hit, pointerInsideSurface: inside)
  }

  private var surfaceAvailable: Bool {
    guard !closed, available(), panel?.isVisible == true, canvas?.window === panel,
      canvas?.spatialStage != nil, let current = authority(),
      !current.documentID.isEmpty, current.documentID.utf8.prefix(257).count <= 256,
      current.displayID != 0
    else { return false }
    return !(latestModifiers.contains(.control) && latestModifiers.contains(.option))
  }

  private func reconcile(_ input: ExplanationOrbitState.Input) {
    let wasScrolling = state.phase == .scrolling
    state.update(input)
    if wasScrolling, state.phase != .scrolling {
      scrollCancels = min(1_000_000, scrollCancels + 1)
    }
  }

  /// Only the canvas/SCNView's native scrollWheel dispatch enters here. The
  /// method is also a deterministic own-event seam; it never posts input.
  @discardableResult func consumeScrollEvent(_ event: NSEvent) -> Bool {
    guard !closed, event.type == .scrollWheel, let canvas, let panel,
      event.window === panel
    else { return false }
    return consumeScrollInput(
      window: event.window, point: canvas.convert(event.locationInWindow, from: nil),
      flags: event.modifierFlags, deltaX: Double(event.scrollingDeltaX),
      deltaY: Double(event.scrollingDeltaY), precise: event.hasPreciseScrollingDeltas,
      phase: event.phase, momentumPhase: event.momentumPhase, timestamp: event.timestamp)
  }

  /// The same bounded local-event reducer can be exercised with authored
  /// own-window metadata. It does not dispatch or post an NSEvent.
  @discardableResult func consumeScrollInput(
    window: NSWindow?, point: CGPoint, flags: NSEvent.ModifierFlags,
    deltaX: Double, deltaY: Double, precise: Bool,
    phase: NSEvent.Phase, momentumPhase: NSEvent.Phase, timestamp: TimeInterval
  ) -> Bool {
    guard !closed, let canvas, let panel, window === panel else { return false }
    let pointer = panel.convertPoint(toScreen: canvas.convert(point, to: nil))
    let values = currentInputValues()
    let current = input(
      pointer: pointer, modifiers: Self.modifiers(flags), buttons: values.2,
      canvasPoint: point, forLocalScroll: true)
    let wasScrolling = state.phase == .scrolling
    guard timestamp.isFinite, timestamp >= authorityObservedAt,
      let delta = ExplanationOrbitState.scrollDelta(
        x: deltaX, y: deltaY, precise: precise)
    else {
      cancelScroll()
      return wasScrolling
    }
    let momentum = !momentumPhase.isEmpty
    let cancelled = phase.contains(.cancelled) || momentumPhase.contains(.cancelled)
    if cancelled || momentum && reduceMotion() {
      cancelScroll()
      return wasScrolling
    }
    if wasScrolling {
      state.update(current)
      guard state.phase == .scrolling else {
        scrollCancels = min(1_000_000, scrollCancels + 1)
        applyOwnership()
        return true
      }
    } else {
      // Orphaned momentum/changed tails never acquire a new presentation.
      let begins = phase.contains(.began) || phase.contains(.mayBegin)
      let discrete = phase.isEmpty && momentumPhase.isEmpty
      guard !momentum, begins || discrete, state.beginScroll(current) else {
        applyOwnership()
        return false
      }
      scrollStarts = min(1_000_000, scrollStarts + 1)
    }
    applyOwnership()
    guard !closed, state.phase == .scrolling, state.authority == current.authority else {
      return true
    }
    if delta != .zero {
      guard canvas.orbitOverlayCamera(delta: delta) else {
        cancelScroll()
        return true
      }
      scrollEvents = min(1_000_000, scrollEvents + 1)
    }
    if momentumPhase.contains(.ended) || reduceMotion() && phase.contains(.ended) {
      endScroll()
    } else {
      // Trackpad momentum is supplied by the OS, not generated here. A single
      // idle timer releases a lost terminal event or a phase-less mouse wheel.
      scheduleScrollEnd()
    }
    return true
  }

  private func scheduleScrollEnd() {
    guard let owner = state.authority, state.phase == .scrolling else { return }
    scrollTimerAuthority = owner
    if let timer = scrollEndTimer {
      timer.fireDate = Date(timeIntervalSinceNow: 0.20)
      return
    }
    let timer = Timer(timeInterval: 0.20, repeats: false) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self, !self.closed, self.state.phase == .scrolling,
          self.state.authority == self.scrollTimerAuthority
        else { return }
        self.endScroll()
      }
    }
    scrollEndTimer = timer
    RunLoop.main.add(timer, forMode: .common)
  }

  private func cancelScrollTimer() {
    scrollEndTimer?.invalidate()
    scrollEndTimer = nil
    scrollTimerAuthority = nil
  }

  private func endScroll() {
    guard state.phase == .scrolling else { return }
    let values = currentInputValues()
    let current = input(
      pointer: values.0, modifiers: values.1, buttons: values.2, forLocalScroll: true)
    if state.endScroll(current) {
      scrollEnds = min(1_000_000, scrollEnds + 1)
    } else {
      scrollCancels = min(1_000_000, scrollCancels + 1)
      state.cancel()
    }
    cancelScrollTimer()
    applyOwnership()
  }

  private func cancelScroll() {
    if state.phase == .scrolling { scrollCancels = min(1_000_000, scrollCancels + 1) }
    state.cancel()
    cancelScrollTimer()
    applyOwnership()
  }

  private func begin(atCanvasPoint point: CGPoint, flags: NSEvent.ModifierFlags) -> Bool {
    guard !closed, let canvas, let panel else { return false }
    if observeInput, !CGPreflightListenEventAccess(), !AXIsProcessTrusted() {
      state.cancel()
      registration = nil
      applyOwnership()
      return false
    }
    let pointer = panel.convertPoint(toScreen: canvas.convert(point, to: nil))
    let current = input(
      pointer: pointer, modifiers: Self.modifiers(flags), buttons: .left, canvasPoint: point)
    guard current.authority == state.authority else {
      state.cancel()
      applyOwnership()
      return false
    }
    let admitted = state.beginDrag(current)
    if admitted, !observeInput {
      manualInput = (pointer, Self.modifiers(flags), .left)
    }
    if !admitted { applyOwnership() }
    return admitted
  }

  private func cameraInteraction(_ event: CanvasCameraInteractionEvent) {
    guard !closed, !applying else { return }
    switch event {
    case .began:
      starts = min(1_000_000, starts + 1)
    case .ended:
      ends = min(1_000_000, ends + 1)
      let values = currentInputValues()
      if !observeInput { manualInput = (values.0, values.1, []) }
      _ = state.endDrag(
        input(pointer: values.0, modifiers: values.1, buttons: [], requireFreshHit: true))
    case .cancelled:
      if state.phase == .dragging { cancels = min(1_000_000, cancels + 1) }
      state.cancel()
    }
    applyOwnership()
  }

  private func applyOwnership() {
    guard !applying else { return }
    applying = true
    let accepts = !closed && (state.phase == .armed || state.phase == .dragging)
    if !accepts, canvas?.isOverlayCameraDragging == true {
      cancels = min(1_000_000, cancels + 1)
      canvas?.cancelOverlayCameraInteraction()
    }
    canvas?.overlayCameraArmed = accepts
    let surface = surfaceAvailable
    canvas?.overlaySurfaceInteractive = surface
    panel?.ignoresMouseEvents = !surface
    if state.phase != .scrolling { cancelScrollTimer() }
    let phaseChanged = state.phase != lastPhase
    lastPhase = state.phase
    applying = false
    if phaseChanged { onPhaseChange(state.phase) }
  }

  private func currentInputValues()
    -> (CGPoint, ExplanationOrbitState.Modifiers, ExplanationOrbitState.Buttons)
  {
    if !observeInput, let manualInput { return manualInput }
    return (NSEvent.mouseLocation, Self.modifiers(NSEvent.modifierFlags), Self.buttons())
  }

  private func installObservation() {
    // Reuse the user's existing Input Monitoring / Accessibility authorization;
    // this read-only listener never prompts for a new privacy grant.
    guard CGPreflightListenEventAccess() || AXIsProcessTrusted() else { return }
    let context = ExplanationOrbitTapContext(owner: self)
    guard
      let tap = CGEvent.tapCreate(
        tap: .cgSessionEventTap, place: .tailAppendEventTap, options: .listenOnly,
        eventsOfInterest: CGEventMask(1) << CGEventType.flagsChanged.rawValue,
        callback: Self.tapCallback, userInfo: Unmanaged.passUnretained(context).toOpaque()),
      let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
    else { return }
    let owned = ExplanationOrbitTapRegistration(tap: tap, source: source, context: context)
    registration = owned
    CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    CGEvent.tapEnable(tap: tap, enable: true)
    guard CGEvent.tapIsEnabled(tap: tap) else {
      registration = nil
      return
    }
    lastObservedOption = NSEvent.modifierFlags.contains(.option)
    let mask: NSEvent.EventTypeMask = [
      .mouseMoved, .leftMouseDown, .leftMouseDragged, .leftMouseUp,
      .rightMouseDown, .rightMouseDragged, .rightMouseUp,
      .otherMouseDown, .otherMouseDragged, .otherMouseUp,
    ]
    globalMouse = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] _ in
      MainActor.assumeIsolated { self?.pointerObserved() }
    }
    localMouse = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
      MainActor.assumeIsolated { self?.consumeLocalEvent(event) }
      return event
    }
    let health = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self, !self.closed else { return }
        if self.registration.map({ CGEvent.tapIsEnabled(tap: $0.tap) }) != true
          || (!CGPreflightListenEventAccess() && !AXIsProcessTrusted())
        {
          self.state.cancel()
          self.applyOwnership()
          self.registration = nil
        } else if self.state.phase != .passive {
          self.refresh()
        }
      }
    }
    owned.healthTimer = health
    RunLoop.main.add(health, forMode: .common)
  }

  /// Own mouse-down must reach the canvas veto before generic button-state
  /// reconciliation; an already-down external gesture must never arm a panel.
  func consumeLocalEvent(_ event: NSEvent) {
    guard !closed else { return }
    if event.window === panel, event.type == .leftMouseDown { return }
    if event.window === panel, let panel {
      let flags = Self.modifiers(event.modifierFlags)
      let optionOnly = flags.subtracting([.capsLock, .numericPad]) == .option
      if event.type == .leftMouseUp, optionOnly { return }
      if state.acceptsMouseEvents {
        let pointer = panel.convertPoint(toScreen: event.locationInWindow)
        let buttons: ExplanationOrbitState.Buttons =
          event.type == .leftMouseDragged ? .left : Self.buttons()
        reconcile(input(pointer: pointer, modifiers: flags, buttons: buttons))
        applyOwnership()
        return
      }
    }
    pointerObserved()
  }

  private func pointerObserved() {
    guard !closed else { return }
    pointerEvents = min(1_000_000, pointerEvents + 1)
    let now = ProcessInfo.processInfo.systemUptime
    if now - lastPointerRefresh >= 1 / 60 {
      lastPointerRefresh = now
      refresh()
    } else if !pointerRefreshScheduled {
      pointerRefreshScheduled = true
      DispatchQueue.main.asyncAfter(deadline: .now() + 1 / 60) { [weak self] in
        guard let self else { return }
        self.pointerRefreshScheduled = false
        guard !self.closed else { return }
        self.lastPointerRefresh = ProcessInfo.processInfo.systemUptime
        self.refresh()
      }
    }
  }

  private func modifierObserved(type: CGEventType, flags: NSEvent.ModifierFlags) {
    guard !closed else { return }
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
      state.cancel()
      applyOwnership()
      registration = nil
      return
    }
    observedModifiers = min(1_000_000, observedModifiers + 1)
    let option = flags.contains(.option)
    if option != lastObservedOption {
      if option {
        optionPresses = min(1_000_000, optionPresses + 1)
      } else {
        optionReleases = min(1_000_000, optionReleases + 1)
      }
      lastObservedOption = option
    }
    // The tap runs before AppKit necessarily updates its process-wide flag
    // cache. Use this event's actual flags for immediate release/PTT priority.
    reconcile(
      input(
        pointer: NSEvent.mouseLocation, modifiers: Self.modifiers(flags), buttons: Self.buttons()))
    applyOwnership()
  }

  private nonisolated static let tapCallback: CGEventTapCallBack = { _, type, event, info in
    guard let info else { return Unmanaged.passUnretained(event) }
    let context = Unmanaged<ExplanationOrbitTapContext>.fromOpaque(info).takeUnretainedValue()
    let owner = context.owner
    let flags = NSEvent.ModifierFlags(rawValue: UInt(event.flags.rawValue))
    MainActor.assumeIsolated { owner?.modifierObserved(type: type, flags: flags) }
    return Unmanaged.passUnretained(event)
  }

  static func modifiers(_ flags: NSEvent.ModifierFlags) -> ExplanationOrbitState.Modifiers {
    var result: ExplanationOrbitState.Modifiers = []
    for (native, own) in [
      (NSEvent.ModifierFlags.option, ExplanationOrbitState.Modifiers.option),
      (.control, .control), (.command, .command), (.shift, .shift), (.function, .function),
      (.capsLock, .capsLock), (.numericPad, .numericPad), (.help, .help),
    ] where flags.contains(native) { result.insert(own) }
    let known: NSEvent.ModifierFlags = [
      .option, .control, .command, .shift, .function, .capsLock, .numericPad, .help,
    ]
    if !flags.intersection(.deviceIndependentFlagsMask).subtracting(known).isEmpty {
      result.insert(.init(rawValue: 1 << 15))
    }
    // Device-specific low bits describe left/right hardware; the standard
    // device-independent mask above determines the semantic modifier chord.
    return result
  }

  private static func buttons() -> ExplanationOrbitState.Buttons {
    let native = NSEvent.pressedMouseButtons
    var result: ExplanationOrbitState.Buttons = []
    if native & 1 != 0 { result.insert(.left) }
    if native & 2 != 0 { result.insert(.right) }
    if native & ~3 != 0 { result.insert(.other) }
    return result
  }
}

private final class ExplanationOrbitTapContext {
  weak var owner: ExplanationOrbitController?
  init(owner: ExplanationOrbitController) { self.owner = owner }
}

private final class ExplanationOrbitTapRegistration {
  let tap: CFMachPort
  let source: CFRunLoopSource
  let context: ExplanationOrbitTapContext
  var healthTimer: Timer?
  init(tap: CFMachPort, source: CFRunLoopSource, context: ExplanationOrbitTapContext) {
    self.tap = tap
    self.source = source
    self.context = context
  }
  deinit {
    healthTimer?.invalidate()
    CGEvent.tapEnable(tap: tap, enable: false)
    CFMachPortInvalidate(tap)
    CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
  }
}
