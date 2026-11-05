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
  let panelIgnoresMouseEvents: Bool
  let canvasArmed: Bool
}

/// Option explicitly reserves this bounded native panel. Global input is only
/// observed: it is never swallowed, modified, reposted or used to capture a
/// screen. The canvas still rechecks an actual mesh and current authority at
/// mouse-down; a transparent window is not treated as a cross-app mouse hole.
@MainActor final class ExplanationOrbitController {
  typealias Authority = ExplanationOrbitState.Authority
  private weak var canvas: RetainedCanvasView?
  private weak var panel: AnnotationPanel?
  private let authority: @MainActor () -> Authority?
  private let available: @MainActor () -> Bool
  private let onPhaseChange: @MainActor (ExplanationOrbitState.Phase) -> Void
  private let observeInput: Bool
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

  init(
    canvas: RetainedCanvasView, panel: AnnotationPanel, observeInput: Bool = true,
    authority: @escaping @MainActor () -> Authority?,
    available: @escaping @MainActor () -> Bool,
    onPhaseChange: @escaping @MainActor (ExplanationOrbitState.Phase) -> Void = { _ in }
  ) {
    self.canvas = canvas
    self.panel = panel
    self.observeInput = observeInput
    self.authority = authority
    self.available = available
    self.onPhaseChange = onPhaseChange
    canvas.shouldBeginOverlayCameraInteraction = { [weak self] point, flags in
      self?.begin(atCanvasPoint: point, flags: flags) == true
    }
    canvas.onOverlayCameraInteraction = { [weak self] event in self?.cameraInteraction(event) }
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
    state.update(input(pointer: values.0, modifiers: values.1, buttons: values.2))
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
    state.cancel()
    applyOwnership()
    canvas?.shouldBeginOverlayCameraInteraction = nil
    canvas?.onOverlayCameraInteraction = nil
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
    requireFreshHit: Bool = false
  ) -> ExplanationOrbitState.Input {
    let current = authority()
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
    return .init(
      authority: current, modifiers: modifiers, buttons: buttons,
      presentationVisible: visible, awake: isAvailable, sessionActive: isAvailable,
      displayAvailable: current != nil,
      spatialReady: observationAvailable && canvas?.spatialStage != nil,
      pointerOnVisibleMesh: hit)
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
    defer { applying = false }
    let accepts = !closed && state.acceptsMouseEvents
    if !accepts, canvas?.isOverlayCameraDragging == true {
      cancels = min(1_000_000, cancels + 1)
      canvas?.cancelOverlayCameraInteraction()
    }
    canvas?.overlayCameraArmed = accepts
    panel?.ignoresMouseEvents = !accepts
    if state.phase != lastPhase {
      lastPhase = state.phase
      onPhaseChange(state.phase)
    }
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
        state.update(input(pointer: pointer, modifiers: flags, buttons: buttons))
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
    state.update(
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
