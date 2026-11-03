import AppKit
import Combine
import QuartzCore
@preconcurrency import ScreenCaptureKit
import SwiftUI

enum CompanionAnchor: String, CaseIterable, Identifiable {
  case notch, dock, floating
  var id: String { rawValue }
}

struct CompanionShellGeometry: Codable, Sendable {
  let anchor: String
  let expanded: Bool
  let frame: CGRect
  let displayFrame: CGRect
  let safeAreaTop: CGFloat
  let surface: String
  let cutoutFrame: CGRect?
}

private enum ShellCaptureSource { case display, window, region, scribble }

enum ShellCaptureCompletion: Equatable {
  case waiting, completed, invalidated
}

/// Capture publication and task cancellation are independent clocks. A generic
/// audio/UI "Ready" transition never proves that a selected frame arrived.
struct ShellCaptureExpectation {
  let taskGeneration: UInt64
  let previousFrameID: UUID?
  let publicationRevision: UInt64

  func completion(
    taskGeneration currentGeneration: UInt64, publicationRevision currentRevision: UInt64,
    frameID: UUID?
  ) -> ShellCaptureCompletion {
    guard currentGeneration == taskGeneration, currentRevision <= publicationRevision else {
      return .invalidated
    }
    guard currentRevision == publicationRevision, let frameID, frameID != previousFrameID else {
      return .waiting
    }
    return .completed
  }
}

private enum ShellPalette {
  static let background = Color.black
  static let inset = Color(white: 0.065)
  static let text = Color(white: 0.95)
  static let secondary = Color(white: 0.61)
  static let accent = Color(white: 0.86)
}

@MainActor private final class ShellPresentation: ObservableObject {
  @Published var expanded = false
  @Published var peeked = false
  @Published var topInset: CGFloat = 0
  @Published var hasCutout = false
  @Published var focusEpoch = 0
  @Published var anchor: CompanionAnchor = .notch
}

private final class ResidentCompanionPanel: NSPanel {
  var permitsKeyboard = false
  override var canBecomeKey: Bool { permitsKeyboard }
  override var canBecomeMain: Bool { false }
}

/// A resident companion surface. The ordinary workspace is opened only by an
/// explicit utility action; collapsing leaves the foreground app's typing alone.
@MainActor final class CompanionShell {
  /// Synthetic panel acceptance opts out explicitly; ordinary app instances
  /// always observe the real pointer independently of the model's test mode.
  let observesPointer: Bool
  private let model: AppModel
  private let onOpenWorkspace: () -> Void
  private let presentation = ShellPresentation()
  private let panel: ResidentCompanionPanel
  private let motion = ShellFrameMotion()
  private var screen: NSScreen?
  private var previousApplication: NSRunningApplication?
  private var subscriptions: Set<AnyCancellable> = []
  private var captureExpectation: ShellCaptureExpectation?
  private var captureStarted = false
  private var captureInitialError: String?
  private var lastWindowPickerPresented = false
  private var pendingInvocationID: UUID?
  private var pendingTaskGeneration: UInt64?
  private var pendingInvocation: Task<Void, Never>?
  private var globalPointerMonitor: Any?
  private var localPointerMonitor: Any?
  private var pointerPolling: NotchPointerPolling?
  private var hoverTransition: Task<Void, Never>?
  private var hoverTransitionID: UUID?
  private var hoverAction = NotchHoverPolicy.Action.none
  private var hoverPolicy = NotchHoverPolicy()
  private var lastPointer = CGPoint.zero
  private var voicePresentation = false
  private var voiceTuck: Task<Void, Never>?
  private let dockArt = CompanionDockTileView(frame: NSRect(x: 0, y: 0, width: 128, height: 128))

  init(model: AppModel, observePointer: Bool = true, onOpenWorkspace: @escaping () -> Void) {
    self.observesPointer = observePointer
    self.model = model
    self.onOpenWorkspace = onOpenWorkspace
    panel = ResidentCompanionPanel(
      contentRect: CGRect(x: 0, y: 0, width: 96, height: 48),
      styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = true
    panel.hidesOnDeactivate = false
    panel.isReleasedWhenClosed = false
    panel.acceptsMouseMovedEvents = true
    panel.level = .floating
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
    panel.appearance = NSAppearance(named: .darkAqua)
    panel.identifier = NSUserInterfaceItemIdentifier("org.opencompanion.resident")
    panel.setAccessibilityLabel("OpenCompanion notch companion")
    let content = CompanionShellView(
      model: model, presentation: presentation, expand: { [weak self] in self?.expand() },
      collapse: { [weak self] in self?.collapse() },
      capture: { [weak self] source in self?.captureScreen(source) },
      send: { [weak self] in self?.send() },
      selectWindow: { [weak self] window in self?.selectWindow(window) },
      open: { [weak self] section in self?.openWorkspace(section) })
    let hosting = NSHostingView(rootView: content)
    hosting.autoresizingMask = [.width, .height]
    panel.contentView = hosting
    NSApp.dockTile.contentView = dockArt
    NSApp.dockTile.display()
    model.objectWillChange.sink { [weak self] _ in
      Task { @MainActor in self?.updateState() }
    }.store(in: &subscriptions)
    NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
      .sink { [weak self] _ in
        Task { @MainActor in
          guard let self else { return }
          self.screen = nil
          self.position(animated: false)
        }
      }.store(in: &subscriptions)
    if observePointer {
      globalPointerMonitor = NSEvent.addGlobalMonitorForEvents(matching: [
        .mouseMoved, .leftMouseDragged,
      ]) { [weak self] _ in
        MainActor.assumeIsolated { self?.observeCurrentPointer() }
      }
      localPointerMonitor = NSEvent.addLocalMonitorForEvents(matching: [
        .mouseMoved, .leftMouseDragged,
      ]) { [weak self] event in
        MainActor.assumeIsolated { self?.observeCurrentPointer() }
        return event
      }
      pointerPolling = NotchPointerPolling { [weak self] location in
        guard let self, self.panel.isVisible, self.presentation.anchor == .notch else { return }
        self.pointerMoved(to: location)
      }
    }
  }

  func show(anchor: CompanionAnchor = .notch) {
    presentation.anchor = anchor
    screen = preferredScreen()
    position(animated: false)
    panel.orderFrontRegardless()
    if anchor == .notch { pointerPolling?.start() } else { pointerPolling?.stop() }
    updateState()
    observeCurrentPointer()
  }

  var geometry: CompanionShellGeometry {
    let display = screen ?? NSScreen.main
    return CompanionShellGeometry(
      anchor: presentation.anchor.rawValue, expanded: presentation.expanded, frame: panel.frame,
      displayFrame: display?.frame ?? .zero, safeAreaTop: display?.safeAreaInsets.top ?? 0,
      surface: surface.rawValue, cutoutFrame: layout?.cutout)
  }

  private var surface: NotchSurface {
    presentation.expanded ? .conversation : presentation.peeked ? .peek : .tucked
  }
  private var layout: NotchLayout? {
    guard let display = screen ?? preferredScreen() else { return nil }
    return NotchLayout(
      display: display.frame, visible: display.visibleFrame,
      safeTop: display.safeAreaInsets.top, left: display.auxiliaryTopLeftArea,
      right: display.auxiliaryTopRightArea)
  }
  private func preferredScreen() -> NSScreen? {
    NSScreen.screens.first(where: {
      $0.safeAreaInsets.top > 0 && $0.auxiliaryTopLeftArea != nil && $0.auxiliaryTopRightArea != nil
    })
      ?? NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) })
      ?? NSScreen.main ?? NSScreen.screens.first
  }

  /// Reveal without activating the app or taking the foreground application's keyboard.
  func showVoiceActivity() {
    voiceTuck?.cancel()
    voicePresentation = true
    if !presentation.expanded { presentPeek() }
  }

  func shutdown() {
    pointerPolling?.stop()
    hoverTransition?.cancel()
    voiceTuck?.cancel()
    motion.stop()
    if let globalPointerMonitor { NSEvent.removeMonitor(globalPointerMonitor) }
    if let localPointerMonitor { NSEvent.removeMonitor(localPointerMonitor) }
    globalPointerMonitor = nil
    localPointerMonitor = nil
  }

  private func presentPeek() {
    hoverTransition?.cancel()
    hoverAction = .none
    presentation.peeked = true
    panel.permitsKeyboard = false
    position(animated: true)
    panel.orderFrontRegardless()
  }

  private func observeCurrentPointer() {
    guard observesPointer else { return }
    pointerMoved(to: NSEvent.mouseLocation)
  }

  func pointerMoved(to location: CGPoint) {
    lastPointer = location
    guard presentation.anchor == .notch, let layout else { return }
    let action = hoverPolicy.action(
      pointer: location, layout: layout, surface: surface,
      displayedFrame: panel.frame, voiceActive: voicePresentation)
    if action == .none {
      hoverTransition?.cancel()
      hoverTransition = nil
      hoverTransitionID = nil
      hoverAction = .none
      return
    }
    guard action != hoverAction else { return }
    hoverTransition?.cancel()
    hoverAction = action
    let requestID = UUID()
    hoverTransitionID = requestID
    hoverTransition = Task { @MainActor [weak self] in
      do {
        try await Task.sleep(for: action == .reveal ? .milliseconds(70) : .milliseconds(230))
      } catch {}
      guard let self, self.hoverTransitionID == requestID else { return }
      defer {
        if self.hoverTransitionID == requestID {
          self.hoverTransitionID = nil
          self.hoverTransition = nil
          self.hoverAction = .none
        }
      }
      guard !Task.isCancelled, let currentLayout = self.layout,
        self.hoverPolicy.action(
          pointer: self.lastPointer, layout: currentLayout, surface: self.surface,
          displayedFrame: self.panel.frame,
          voiceActive: self.voicePresentation) == action
      else { return }
      self.hoverAction = .none
      if action == .reveal {
        self.model.record("notch.hoverRevealed")
        self.presentPeek()
      } else {
        self.model.record("notch.hoverTucked")
        self.collapse(restoringFocus: false)
      }
    }
  }

  private var voiceIsActive: Bool {
    model.busy || model.listening || model.pushToTalkActive || model.state == "Speaking"
      || model.state == "Finishing speech" || model.state == "Preparing microphone"
  }

  func toggle() { presentation.expanded ? collapse() : expand() }
  func open() { expand() }

  func captureSelectedDisplay() {
    if let foreground = NSWorkspace.shared.frontmostApplication,
      foreground.processIdentifier != ProcessInfo.processInfo.processIdentifier
    {
      previousApplication = foreground
    }
    captureScreen(.display)
  }

  func collapse() {
    invalidateInvocations()
    hoverPolicy.suppressedUntilExit = true
    voicePresentation = false
    voiceTuck?.cancel()
    collapse(restoringFocus: true)
  }

  private func invalidateInvocations() {
    model.cancelWindowPicker()
    pendingInvocation?.cancel()
    pendingInvocation = nil
    pendingInvocationID = nil
    pendingTaskGeneration = nil
    captureExpectation = nil
    captureStarted = false
    captureInitialError = nil
  }

  private func collapse(restoringFocus: Bool) {
    hoverTransition?.cancel()
    hoverAction = .none
    guard presentation.expanded || presentation.peeked else { return }
    presentation.expanded = false
    presentation.peeked = false
    panel.permitsKeyboard = false
    panel.resignKey()
    position(animated: true)
    if restoringFocus,
      NSWorkspace.shared.frontmostApplication?.processIdentifier
        == ProcessInfo.processInfo.processIdentifier
    {
      previousApplication?.activate(options: [])
    }
  }

  private func expand() {
    hoverTransition?.cancel()
    hoverAction = .none
    voiceTuck?.cancel()
    if let foreground = NSWorkspace.shared.frontmostApplication,
      foreground.processIdentifier != ProcessInfo.processInfo.processIdentifier
    {
      previousApplication = foreground
    }
    presentation.expanded = true
    presentation.peeked = false
    panel.permitsKeyboard = true
    position(animated: true)
    // This activation follows an explicit click/hotkey/Dock invocation.
    NSApp.activate(ignoringOtherApps: true)
    panel.makeKeyAndOrderFront(nil)
    presentation.focusEpoch += 1
  }

  private func openWorkspace(_ section: String) {
    invalidateInvocations()
    collapse(restoringFocus: false)
    model.section = section
    onOpenWorkspace()
  }

  private func captureScreen(_ source: ShellCaptureSource) {
    invalidateInvocations()
    if source == .window {
      model.chooseWindow()
      return
    }
    let generation = model.taskGeneration
    let previousFrameID = model.captureResultID
    let initialError = model.error
    let invocationID = UUID()
    pendingInvocationID = invocationID
    pendingTaskGeneration = generation
    collapse(restoringFocus: true)
    let expectedPID = previousApplication?.processIdentifier
    pendingInvocation = Task { @MainActor [weak self] in
      guard let self,
        await self.waitForForeground(
          expectedPID, generation: generation, invocationID: invocationID)
      else { return }
      guard self.invocationPermitted(invocationID, generation: generation) else { return }
      self.finishPendingInvocation()
      switch source {
      case .display: self.model.observe()
      case .region: self.model.chooseRegion(.region)
      case .scribble: self.model.chooseRegion(.scribble)
      case .window: return
      }
      // Region/scribble selection has its own invalidation, followed by the
      // capture's invalidation after the user completes the selection.
      let selectionStage: UInt64 = source == .region || source == .scribble ? 1 : 0
      self.captureExpectation = ShellCaptureExpectation(
        taskGeneration: generation, previousFrameID: previousFrameID,
        publicationRevision: self.model.capturePublicationRevision &+ selectionStage)
      self.captureInitialError = initialError
      self.updateState()
    }
  }

  private func selectWindow(_ window: CaptureWindow) {
    model.showingWindowPicker = false
    invalidateInvocations()
    let generation = model.taskGeneration
    let previousFrameID = model.captureResultID
    let initialError = model.error
    let invocationID = UUID()
    pendingInvocationID = invocationID
    pendingTaskGeneration = generation
    collapse(restoringFocus: true)
    let expectedPID = previousApplication?.processIdentifier
    pendingInvocation = Task { @MainActor [weak self] in
      guard let self,
        await self.waitForForeground(
          expectedPID, generation: generation, invocationID: invocationID)
      else { return }
      guard self.invocationPermitted(invocationID, generation: generation) else { return }
      self.finishPendingInvocation()
      self.model.performCapture(window: window)
      self.captureExpectation = ShellCaptureExpectation(
        taskGeneration: generation, previousFrameID: previousFrameID,
        publicationRevision: self.model.capturePublicationRevision)
      self.captureInitialError = initialError
      self.updateState()
    }
  }

  private func send() {
    invalidateInvocations()
    guard model.evidence != nil else {
      model.send()
      return
    }
    let generation = model.taskGeneration
    let requestedInput = model.input
    let requestedFrameID = model.captureResultID
    let invocationID = UUID()
    pendingInvocationID = invocationID
    pendingTaskGeneration = generation
    collapse(restoringFocus: true)
    let expectedPID = previousApplication?.processIdentifier
    pendingInvocation = Task { @MainActor [weak self] in
      guard let self,
        await self.waitForForeground(
          expectedPID, generation: generation, invocationID: invocationID)
      else { return }
      guard self.invocationPermitted(invocationID, generation: generation) else { return }
      self.finishPendingInvocation()
      guard self.model.input == requestedInput, self.model.captureResultID == requestedFrameID
      else {
        self.model.notice =
          "The draft or selected screen changed before sending. Review it and send again."
        return
      }
      self.model.send()
    }
  }

  private func invocationPermitted(_ id: UUID, generation: UInt64) -> Bool {
    !Task.isCancelled && pendingInvocationID == id && model.taskGeneration == generation
  }

  private func finishPendingInvocation() {
    pendingInvocation = nil
    pendingInvocationID = nil
    pendingTaskGeneration = nil
  }

  /// App activation is asynchronous. Poll observed focus, bounded to 240 ms,
  /// rather than assuming that sleeping for a fixed interval restored it.
  private func waitForForeground(_ expectedPID: pid_t?, generation: UInt64, invocationID: UUID)
    async -> Bool
  {
    let deadline = ProcessInfo.processInfo.systemUptime + 0.24
    while invocationPermitted(invocationID, generation: generation) {
      let foregroundPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
      let external =
        foregroundPID != nil && foregroundPID != ProcessInfo.processInfo.processIdentifier
      if external && (expectedPID == nil || foregroundPID == expectedPID) { return true }
      if ProcessInfo.processInfo.systemUptime >= deadline { break }
      do { try await Task.sleep(for: .milliseconds(12)) } catch { return false }
    }
    guard invocationPermitted(invocationID, generation: generation) else { return false }
    finishPendingInvocation()
    model.error = "The previous app did not regain focus. Bring it forward and try again."
    return false
  }

  /// Render the current mounted surface for visual acceptance without asking
  /// for screen-capture permission or including any other application's pixels.
  func exportSnapshot(to url: URL) throws {
    guard let view = panel.contentView else { throw CocoaError(.fileWriteUnknown) }
    view.layoutSubtreeIfNeeded()
    guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
      throw CocoaError(.fileWriteUnknown)
    }
    view.cacheDisplay(in: view.bounds, to: bitmap)
    guard let data = bitmap.representation(using: .png, properties: [:]) else {
      throw CocoaError(.fileWriteUnknown)
    }
    try data.write(to: url, options: .atomic)
  }

  /// Capture only this exact application's own panel for visual QA. A view's
  /// cacheDisplay can omit compositor-backed SwiftUI controls while inactive.
  func exportLiveSnapshot(to url: URL) async throws {
    let inventory = try await SCShareableContent.excludingDesktopWindows(
      false, onScreenWindowsOnly: true)
    guard
      let window = inventory.windows.first(where: {
        $0.windowID == CGWindowID(panel.windowNumber)
          && $0.owningApplication?.processID == ProcessInfo.processInfo.processIdentifier
      })
    else {
      throw ProviderError.message(
        "The companion panel is not available for its own visual capture.")
    }
    let configuration = SCStreamConfiguration()
    let scale = panel.backingScaleFactor
    configuration.width = Int(panel.frame.width * scale)
    configuration.height = Int(panel.frame.height * scale)
    configuration.showsCursor = false
    let image = try await SCScreenshotManager.captureImage(
      contentFilter: SCContentFilter(desktopIndependentWindow: window), configuration: configuration
    )
    guard let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    else {
      throw ProviderError.message("The own-panel capture could not be encoded.")
    }
    try data.write(to: url, options: .atomic)
  }

  func updateState() {
    dockArt.state = model.state
    dockArt.active = model.busy || model.listening || model.state == "Speaking"
    dockArt.needsDisplay = true
    NSApp.dockTile.display()
    if voicePresentation && !voiceIsActive && model.error == nil && !presentation.expanded
      && voiceTuck == nil
    {
      voiceTuck = Task { @MainActor [weak self] in
        do { try await Task.sleep(for: .milliseconds(1200)) } catch { return }
        guard let self, !self.voiceIsActive else { return }
        self.voicePresentation = false
        self.voiceTuck = nil
        self.observeCurrentPointer()
      }
    } else if voiceIsActive {
      voiceTuck?.cancel()
      voiceTuck = nil
    }
    if let pendingTaskGeneration, pendingTaskGeneration != model.taskGeneration {
      invalidateInvocations()
    }
    let pickerAppeared = model.showingWindowPicker && !lastWindowPickerPresented
    lastWindowPickerPresented = model.showingWindowPicker
    if pickerAppeared && !presentation.expanded { expand() }
    guard let expectation = captureExpectation else { return }
    switch expectation.completion(
      taskGeneration: model.taskGeneration,
      publicationRevision: model.capturePublicationRevision,
      frameID: model.captureResultID)
    {
    case .invalidated:
      captureExpectation = nil
      captureStarted = false
    case .completed:
      captureExpectation = nil
      captureStarted = false
      expand()
    case .waiting:
      if model.state == "Observing" { captureStarted = true }
      let failed = model.error != nil && model.error != captureInitialError
      let endedWithoutFrame =
        captureStarted && model.state == "Ready" && model.captureResultID == nil
      if failed || endedWithoutFrame {
        captureExpectation = nil
        captureStarted = false
      }
    }
  }

  private func position(animated: Bool) {
    guard let display = screen ?? preferredScreen() else { return }
    screen = display
    let notch = NotchLayout(
      display: display.frame, visible: display.visibleFrame,
      safeTop: display.safeAreaInsets.top, left: display.auxiliaryTopLeftArea,
      right: display.auxiliaryTopRightArea)
    presentation.topInset = presentation.anchor == .notch ? notch.topInset : 0
    presentation.hasCutout = presentation.anchor == .notch && notch.cutout != nil
    panel.hasShadow = surface != .tucked || !presentation.hasCutout
    panel.level =
      presentation.hasCutout
      ? NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1) : .floating
    let size = notch.frame(for: surface).size
    let bounds = display.frame
    let visible = display.visibleFrame
    var origin: CGPoint
    switch presentation.anchor {
    case .notch:
      origin = notch.frame(for: surface).origin
    case .dock:
      if visible.minX > bounds.minX + 6 {
        origin = CGPoint(x: visible.minX + 10, y: visible.midY - size.height / 2)
      } else if visible.maxX < bounds.maxX - 6 {
        origin = CGPoint(x: visible.maxX - size.width - 10, y: visible.midY - size.height / 2)
      } else {
        origin = CGPoint(x: visible.midX - size.width / 2, y: visible.minY + 10)
      }
    case .floating:
      origin = CGPoint(x: visible.maxX - size.width - 24, y: visible.minY + 24)
    }
    if !(presentation.anchor == .notch && surface == .tucked && notch.cutout != nil) {
      origin.x = min(max(bounds.minX + 6, origin.x), bounds.maxX - size.width - 6)
    }
    origin.y = max(bounds.minY + 6, origin.y)
    let frame = CGRect(origin: origin, size: size)
    let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    if animated && !reduceMotion {
      motion.move(
        panel, to: frame, duration: presentation.expanded ? 0.28 : 0.22,
        framesPerSecond: display.maximumFramesPerSecond)
    } else {
      motion.stop()
      panel.setFrame(frame, display: true)
    }
  }
}

/// Retargets from the window's last actually presented frame. Reasoning/network
/// work never touches this local monotonic animation clock.
@MainActor private final class ShellFrameMotion {
  private var timer: Timer?
  private weak var window: NSWindow?
  private var from = CGRect.zero
  private var to = CGRect.zero
  private var started = 0.0
  private var duration = 0.25
  func move(_ window: NSWindow, to frame: CGRect, duration: Double, framesPerSecond: Int) {
    stop()
    self.window = window
    from = window.frame
    to = frame
    started = ProcessInfo.processInfo.systemUptime
    self.duration = duration
    let timer = Timer(timeInterval: 1 / Double(min(120, max(30, framesPerSecond))), repeats: true) {
      [weak self] _ in
      MainActor.assumeIsolated { self?.tick() }
    }
    self.timer = timer
    RunLoop.main.add(timer, forMode: .common)
    tick()
  }
  private func tick() {
    guard let window else {
      stop()
      return
    }
    let progress = min(1, max(0, (ProcessInfo.processInfo.systemUptime - started) / duration))
    let eased = progress * progress * (3 - 2 * progress)
    func mix(_ first: CGFloat, _ second: CGFloat) -> CGFloat { first + (second - first) * eased }
    window.setFrame(
      CGRect(
        x: mix(from.minX, to.minX), y: mix(from.minY, to.minY), width: mix(from.width, to.width),
        height: mix(from.height, to.height)), display: true)
    if progress >= 1 { stop() }
  }
  func stop() {
    timer?.invalidate()
    timer = nil
  }
}

private struct ShellMaterial: NSViewRepresentable {
  func makeNSView(context: Context) -> NSVisualEffectView {
    let view = NSVisualEffectView()
    view.material = .hudWindow
    view.blendingMode = .behindWindow
    view.state = .active
    view.appearance = NSAppearance(named: .darkAqua)
    return view
  }
  func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

private struct CompanionShellView: View {
  @ObservedObject var model: AppModel
  @ObservedObject var presentation: ShellPresentation
  let expand: () -> Void
  let collapse: () -> Void
  let capture: (ShellCaptureSource) -> Void
  let send: () -> Void
  let selectWindow: (CaptureWindow) -> Void
  let open: (String) -> Void
  @FocusState private var inputFocused: Bool
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  private var active: Bool { model.busy || model.listening || model.state == "Speaking" }
  private var stateTitle: String {
    if model.state == "Preparing microphone" { return "Getting ready to listen" }
    if model.state == "Finishing speech" { return "Finishing your thought" }
    if model.listening { return "I'm listening" }
    if model.busy { return "Thinking it through" }
    if model.state == "Speaking" { return "Let's talk it through" }
    if model.state == "Observing" { return "Taking a look" }
    return "OpenCompanion"
  }
  var body: some View {
    GeometryReader { geometry in
      ZStack(alignment: .top) {
        if !presentation.hasCutout { ShellMaterial() }
        ShellPalette.background
        expandedContent.frame(width: 430, height: 330).padding(.top, presentation.topInset)
          .opacity(presentation.expanded ? 1 : 0)
          .allowsHitTesting(presentation.expanded).accessibilityHidden(!presentation.expanded)
        peekContent.frame(width: 380, height: 142).padding(.top, presentation.topInset)
          .opacity(presentation.peeked ? 1 : 0).allowsHitTesting(presentation.peeked)
          .accessibilityHidden(!presentation.peeked)
        Button(action: expand) {
          HStack(spacing: 8) {
            CompanionMote(state: model.state, active: active).frame(width: 34, height: 34)
            if active {
              ShellSignal(state: model.state).frame(width: 20, height: 18)
            } else {
              Image(systemName: "ellipsis").font(.system(size: 17, weight: .medium))
                .foregroundStyle(ShellPalette.secondary)
            }
          }.frame(width: 96, height: 36).contentShape(Rectangle())
        }.buttonStyle(.plain).opacity(
          presentation.expanded || presentation.peeked || presentation.hasCutout ? 0 : 1
        ).allowsHitTesting(
          !presentation.expanded && !presentation.peeked
        ).accessibilityHidden(presentation.expanded || presentation.peeked)
          .accessibilityLabel("Open OpenCompanion. \(model.state)").accessibilityIdentifier(
            "companion.expand"
          ).help("Open companion · \(ShortcutPreferences.load().openShortcut.displayName)")
      }
      .frame(width: geometry.size.width, height: geometry.size.height, alignment: .top)
      .clipShape(
        UnevenRoundedRectangle(
          topLeadingRadius: 12, bottomLeadingRadius: 24, bottomTrailingRadius: 24,
          topTrailingRadius: 12)
      )
      .overlay(
        UnevenRoundedRectangle(
          topLeadingRadius: 12, bottomLeadingRadius: 24, bottomTrailingRadius: 24,
          topTrailingRadius: 12
        ).stroke(.white.opacity(presentation.hasCutout ? 0 : 0.11), lineWidth: 0.7)
      )
      .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: presentation.expanded)
    }
    .preferredColorScheme(.dark)
    .tint(ShellPalette.accent)
    .onChange(of: presentation.focusEpoch) { _, _ in inputFocused = true }
    .onChange(of: presentation.expanded) { _, expanded in if !expanded { inputFocused = false } }
    .onExitCommand {
      model.stop()
      collapse()
    }
    .sheet(isPresented: $model.showingWindowPicker) {
      VStack(alignment: .leading, spacing: 14) {
        Text("Choose a window to share").font(.system(size: 19, weight: .semibold))
        Text("Only the window you choose is included.").font(.callout).foregroundStyle(.secondary)
        List(model.captureWindows) { window in
          Button {
            selectWindow(window)
          } label: {
            VStack(alignment: .leading, spacing: 4) {
              Text(window.title.isEmpty ? "Untitled window" : window.title).lineLimit(1)
              Text(window.appName).font(.caption).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 4)
          }.buttonStyle(.plain)
        }.frame(height: 210)
        Button("Cancel") { model.showingWindowPicker = false }.keyboardShortcut(.cancelAction)
      }.padding(22).frame(width: 430).preferredColorScheme(.dark)
    }
  }
  private var peekContent: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 10) {
        CompanionMote(state: model.state, active: active).frame(width: 31, height: 31)
        VStack(alignment: .leading, spacing: 2) {
          Text(stateTitle).font(.system(size: 13, weight: .semibold)).foregroundStyle(
            ShellPalette.text)
          Text(
            model.pushToTalkActive
              ? "Release ⌃⌥ to send"
              : model.voiceShortcutAvailable ? "Hold ⌃⌥ to talk" : "Open chat to talk or type"
          )
          .font(.system(size: 10.5)).foregroundStyle(ShellPalette.secondary)
        }
        Spacer(minLength: 6)
        if active { ShellSignal(state: model.state).frame(width: 24, height: 18) }
        if active {
          Button {
            model.stop()
            collapse()
          } label: {
            Image(systemName: "stop.circle").font(.system(size: 15)).frame(width: 25, height: 28)
          }.buttonStyle(.plain).foregroundStyle(ShellPalette.secondary).accessibilityLabel(
            "Stop response")
        }
        Button(action: expand) {
          Image(systemName: "arrow.up.left.and.arrow.down.right").font(.system(size: 12)).frame(
            width: 25, height: 28)
        }.buttonStyle(.plain).foregroundStyle(ShellPalette.secondary).accessibilityLabel(
          "Open full conversation")
        Button {
          open("Settings")
        } label: {
          Image(systemName: "slider.horizontal.3").font(.system(size: 12)).frame(
            width: 25, height: 28)
        }.buttonStyle(.plain).foregroundStyle(ShellPalette.secondary).accessibilityLabel(
          "Open settings")
      }
      Group {
        if let error = model.error {
          Text(error).foregroundStyle(ShellPalette.text)
        } else if let notice = model.voiceNotice {
          Text(notice).foregroundStyle(ShellPalette.secondary)
        } else if !model.voiceTranscript.isEmpty
          && (model.pushToTalkActive || model.listening || model.state == "Finishing speech")
        {
          Text(model.voiceTranscript).foregroundStyle(ShellPalette.text)
        } else if model.busy {
          Text("Thinking through your question…").foregroundStyle(ShellPalette.secondary)
        } else if let answer = model.messages.last(where: { $0.role == "assistant" }),
          model.state == "Speaking"
        {
          Text(answer.text).foregroundStyle(ShellPalette.text)
        } else if !model.voiceShortcutAvailable {
          Text("The voice shortcut needs setup. Open Settings to enable it.")
            .foregroundStyle(ShellPalette.secondary)
        } else {
          Text("Ask out loud, or open your conversation.").foregroundStyle(ShellPalette.secondary)
        }
      }.font(.system(size: 12)).lineLimit(2).frame(
        maxWidth: .infinity, minHeight: 30, alignment: .leading)
      HStack(spacing: 14) {
        Button("Open chat", action: expand)
        if !model.voiceShortcutAvailable {
          Button("Set up voice") { open("Settings") }
        }
        if model.scene != nil { Button("Notebook") { open("Notebook") } }
        Button("Library") { open("Library") }
        Spacer(minLength: 0)
      }.font(.system(size: 11, weight: .medium)).buttonStyle(.plain).foregroundStyle(
        ShellPalette.accent)
    }.padding(.horizontal, 19).padding(.vertical, 11)
  }
  private var expandedContent: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 10) {
        CompanionMote(state: model.state, active: active).frame(width: 38, height: 38)
        VStack(alignment: .leading, spacing: 3) {
          Text(stateTitle).font(.system(size: 14, weight: .semibold)).foregroundStyle(
            ShellPalette.text)
          HStack(spacing: 5) {
            Circle().fill(active ? ShellPalette.accent : ShellPalette.secondary.opacity(0.7)).frame(
              width: 4, height: 4)
            Text(
              model.listening
                ? (model.pushToTalkActive ? "Release ⌃⌥ to send" : "Press the mic to finish")
                : active ? "You can stop me anytime" : "Right here when you need a hand"
            ).font(.system(size: 10.5)).foregroundStyle(ShellPalette.secondary)
          }
        }
        Spacer(minLength: 5)
        Menu {
          Button("Open notebook") { open("Notebook") }
          Button("Open library") { open("Library") }
          Divider()
          Button("Settings") { open("Settings") }
        } label: {
          Image(systemName: "slider.horizontal.3").font(.system(size: 13)).frame(
            width: 25, height: 28)
        }.menuStyle(.borderlessButton).fixedSize().foregroundStyle(ShellPalette.secondary).help(
          "Settings and saved work")
        Button(action: collapse) {
          Image(systemName: "chevron.up").font(.system(size: 11, weight: .semibold)).frame(
            width: 25, height: 28)
        }.buttonStyle(.plain).foregroundStyle(ShellPalette.secondary).help(
          "Collapse companion · Escape"
        ).accessibilityLabel("Collapse companion")
      }.padding(.horizontal, 19).padding(.top, 13).padding(.bottom, 10)
      Rectangle().fill(.white.opacity(0.075)).frame(height: 0.5).padding(.horizontal, 19)
      conversation.padding(.horizontal, 21).frame(maxWidth: .infinity, maxHeight: .infinity)
      if let error = model.error {
        HStack(alignment: .top, spacing: 7) {
          Image(systemName: "exclamationmark.circle").foregroundStyle(ShellPalette.accent)
          Text(error).lineLimit(2).font(.system(size: 10.5)).foregroundStyle(ShellPalette.text)
          Spacer(minLength: 0)
          Button {
            model.error = nil
          } label: {
            Image(systemName: "xmark").font(.system(size: 9))
          }.buttonStyle(.plain)
        }.padding(.horizontal, 20).padding(.bottom, 8).accessibilityElement(children: .combine)
      }
      composer.padding(.horizontal, 15).padding(.bottom, 13)
    }
  }
  @ViewBuilder private var conversation: some View {
    if model.messages.isEmpty {
      VStack(alignment: .leading, spacing: 9) {
        Text("What would you\nlike to figure out?").font(
          .system(size: 24, weight: .medium, design: .rounded)
        ).tracking(-0.65).lineSpacing(1).foregroundStyle(ShellPalette.text)
        Text("Ask, talk, or show me what you're looking at.").font(.system(size: 12))
          .foregroundStyle(ShellPalette.secondary)
        if model.scene != nil {
          Button {
            open("Notebook")
          } label: {
            Label("Open explanation", systemImage: "rectangle.and.pencil.and.ellipsis").font(
              .system(size: 11, weight: .medium))
          }.buttonStyle(.plain).foregroundStyle(ShellPalette.accent)
        }
      }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    } else {
      ScrollViewReader { proxy in
        ScrollView {
          VStack(alignment: .leading, spacing: 11) {
            ForEach(Array(model.messages.suffix(8))) { message in
              VStack(alignment: .leading, spacing: 4) {
                if message.role == "user" {
                  Text("You").font(.system(size: 10, weight: .medium)).foregroundStyle(
                    ShellPalette.accent)
                }
                Text(message.text).font(.system(size: 13)).lineSpacing(3).foregroundStyle(
                  message.role == "user" ? ShellPalette.secondary : ShellPalette.text
                ).textSelection(.enabled)
              }.frame(maxWidth: .infinity, alignment: .leading).id(message.id)
            }
            if model.scene != nil {
              Button {
                open("Notebook")
              } label: {
                Label("Open explanation", systemImage: "rectangle.and.pencil.and.ellipsis").font(
                  .system(size: 11, weight: .medium))
              }.buttonStyle(.plain).foregroundStyle(ShellPalette.accent)
            }
          }.padding(.vertical, 13)
        }.scrollIndicators(.hidden).onChange(of: model.messages.count) { _, _ in
          if let last = model.messages.last {
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.16)) {
              proxy.scrollTo(last.id, anchor: .bottom)
            }
          }
        }
      }
    }
  }
  private var composer: some View {
    VStack(alignment: .leading, spacing: 8) {
      if !model.contextTitle.isEmpty {
        HStack(spacing: 5) {
          Image(systemName: "doc.viewfinder").font(.system(size: 10))
          Text(model.contextTitle).font(.system(size: 10)).lineLimit(1)
          Button {
            model.clearContext()
          } label: {
            Image(systemName: "xmark.circle.fill").font(.system(size: 10))
          }.buttonStyle(.plain).accessibilityLabel("Remove selected context")
          Spacer()
        }.foregroundStyle(ShellPalette.accent).padding(.horizontal, 5)
      }
      HStack(alignment: .center, spacing: 8) {
        TextField(
          model.listening ? "Listening…" : "Ask anything…", text: $model.input, axis: .vertical
        )
        .textFieldStyle(.plain).font(.system(size: 13)).foregroundStyle(ShellPalette.text)
        .lineLimit(1...2).focused($inputFocused).onSubmit {
          if !model.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { send() }
        }.accessibilityLabel("Message companion").accessibilityIdentifier("companion.input")
        if active {
          Button {
            model.stop()
          } label: {
            Image(systemName: "stop.fill").font(.system(size: 10, weight: .bold)).frame(
              width: 27, height: 27
            ).background(.white.opacity(0.12), in: Circle())
          }.buttonStyle(.plain).foregroundStyle(ShellPalette.text).accessibilityLabel(
            "Stop response"
          ).help("Stop response")
        } else {
          Button(action: send) {
            Image(systemName: "arrow.up").font(.system(size: 12, weight: .semibold)).frame(
              width: 27, height: 27
            ).background(ShellPalette.accent, in: Circle()).foregroundStyle(ShellPalette.background)
          }.buttonStyle(.plain).disabled(
            model.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
          ).opacity(model.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.4 : 1)
            .accessibilityLabel("Send message")
        }
      }.padding(.horizontal, 12).padding(.vertical, 10).background(
        ShellPalette.inset, in: RoundedRectangle(cornerRadius: 13)
      ).overlay(RoundedRectangle(cornerRadius: 13).stroke(.white.opacity(0.075), lineWidth: 0.5))
      HStack(spacing: 14) {
        Menu {
          Button("Share display") { capture(.display) }
          Button("Choose a window…") { capture(.window) }
          Button("Select a region…") { capture(.region) }
          Button("Draw what you mean…") { capture(.scribble) }
        } label: {
          Label("Screen", systemImage: "viewfinder")
        }.menuStyle(.borderlessButton).fixedSize().help("Choose exactly what to show")
        Button {
          model.importFile()
        } label: {
          Label("File", systemImage: "paperclip")
        }.help("Choose a file to include")
        Spacer()
        Button {
          model.toggleVoice()
        } label: {
          Label(
            model.listening ? "Finish" : "Talk", systemImage: model.listening ? "waveform" : "mic")
        }.foregroundStyle(model.listening ? ShellPalette.accent : ShellPalette.secondary).help(
          "Start listening, then press again to finish")
      }.font(.system(size: 10.5, weight: .medium)).buttonStyle(.plain).foregroundStyle(
        ShellPalette.secondary
      ).padding(.horizontal, 5)
    }
  }
}

/// Original, locally drawn folded-manta character. Its eyes and small fin carry
/// activity rather than a remote animation, image asset, or model-driven frames.
private struct CompanionMote: View {
  let state: String
  let active: Bool
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  var body: some View {
    TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !active || reduceMotion)) { _ in
      let time = reduceMotion ? 0 : ProcessInfo.processInfo.systemUptime
      let talking = state == "Speaking"
      let listening = state == "Listening"
      let drift = active ? sin(time * (talking ? 5 : 2.6)) : 0
      Canvas { context, size in
        let scale = min(size.width, size.height) / 40
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: 0, y: active ? drift * 0.7 : 0)
        var body = Path()
        body.move(to: CGPoint(x: 5, y: 15))
        body.addCurve(
          to: CGPoint(x: 14, y: 6), control1: CGPoint(x: 6, y: 7), control2: CGPoint(x: 10, y: 5))
        body.addCurve(
          to: CGPoint(x: 32, y: 11), control1: CGPoint(x: 20, y: 7), control2: CGPoint(x: 31, y: 4))
        body.addCurve(
          to: CGPoint(x: 35, y: 28), control1: CGPoint(x: 36, y: 15),
          control2: CGPoint(x: 38, y: 25))
        body.addCurve(
          to: CGPoint(x: 26, y: 32), control1: CGPoint(x: 33, y: 31),
          control2: CGPoint(x: 30, y: 32))
        body.addLine(to: CGPoint(x: 28, y: 37))
        body.addCurve(
          to: CGPoint(x: 17, y: 33), control1: CGPoint(x: 23, y: 37),
          control2: CGPoint(x: 19, y: 35))
        body.addCurve(
          to: CGPoint(x: 5, y: 26), control1: CGPoint(x: 9, y: 34), control2: CGPoint(x: 4, y: 31))
        body.addCurve(
          to: CGPoint(x: 5, y: 15), control1: CGPoint(x: 3, y: 22), control2: CGPoint(x: 4, y: 18))
        body.closeSubpath()
        context.fill(body, with: .color(ShellPalette.accent))
        var fold = Path()
        fold.move(to: CGPoint(x: 25, y: 7))
        fold.addQuadCurve(to: CGPoint(x: 33, y: 16), control: CGPoint(x: 29, y: 13))
        fold.addLine(to: CGPoint(x: 34, y: 10))
        fold.closeSubpath()
        context.fill(fold, with: .color(.white.opacity(0.3)))
        let eyeHeight: CGFloat = listening ? 7.5 : talking ? 4.5 + abs(drift) * 2.5 : 6
        for x: CGFloat in [13, 24] {
          context.fill(
            Path(
              roundedRect: CGRect(x: x, y: 18 - eyeHeight / 2, width: 3.8, height: eyeHeight),
              cornerRadius: 2), with: .color(ShellPalette.background))
        }
      }
    }.accessibilityHidden(true)
  }
}

private struct ShellSignal: View {
  let state: String
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  var body: some View {
    TimelineView(.animation(minimumInterval: 1.0 / 24, paused: reduceMotion)) { _ in
      let time = reduceMotion ? 0 : ProcessInfo.processInfo.systemUptime
      HStack(alignment: .center, spacing: 2.5) {
        ForEach(0..<3) { index in
          Capsule().fill(ShellPalette.accent.opacity(0.8)).frame(
            width: 2, height: reduceMotion ? 7 : 4 + abs(sin(time * 3.5 + Double(index) * 0.9)) * 10
          )
        }
      }
    }.accessibilityHidden(true)
  }
}

/// Native Dock drawing shares the character's silhouette and reports actual
/// state. It does not claim audio output or measured acoustic activity.
@MainActor private final class CompanionDockTileView: NSView {
  var state = "Ready"
  var active = false
  override func draw(_ dirtyRect: NSRect) {
    NSGraphicsContext.saveGraphicsState()
    let scale = min(bounds.width, bounds.height) / 128
    let transform = NSAffineTransform()
    transform.scale(by: scale)
    transform.concat()
    NSColor.black.setFill()
    NSBezierPath(
      roundedRect: NSRect(x: 10, y: 9, width: 108, height: 110), xRadius: 27, yRadius: 27
    ).fill()
    let shape = NSBezierPath()
    shape.move(to: NSPoint(x: 30, y: 76))
    shape.curve(
      to: NSPoint(x: 47, y: 98), controlPoint1: NSPoint(x: 30, y: 93),
      controlPoint2: NSPoint(x: 36, y: 100))
    shape.curve(
      to: NSPoint(x: 88, y: 87), controlPoint1: NSPoint(x: 62, y: 94),
      controlPoint2: NSPoint(x: 88, y: 104))
    shape.curve(
      to: NSPoint(x: 97, y: 48), controlPoint1: NSPoint(x: 98, y: 79),
      controlPoint2: NSPoint(x: 103, y: 53))
    shape.curve(
      to: NSPoint(x: 77, y: 40), controlPoint1: NSPoint(x: 93, y: 41),
      controlPoint2: NSPoint(x: 86, y: 39))
    shape.line(to: NSPoint(x: 82, y: 28))
    shape.curve(
      to: NSPoint(x: 56, y: 38), controlPoint1: NSPoint(x: 70, y: 28),
      controlPoint2: NSPoint(x: 61, y: 33))
    shape.curve(
      to: NSPoint(x: 30, y: 53), controlPoint1: NSPoint(x: 36, y: 36),
      controlPoint2: NSPoint(x: 28, y: 42))
    shape.curve(
      to: NSPoint(x: 30, y: 76), controlPoint1: NSPoint(x: 26, y: 61),
      controlPoint2: NSPoint(x: 29, y: 69))
    shape.close()
    NSColor(white: 0.86, alpha: 1).setFill()
    shape.fill()
    NSColor.black.setFill()
    let eyeHeight: CGFloat = state == "Listening" ? 19 : 14
    for x: CGFloat in [48, 75] {
      NSBezierPath(
        roundedRect: NSRect(x: x, y: 68 - eyeHeight / 2, width: 8, height: eyeHeight), xRadius: 4,
        yRadius: 4
      ).fill()
    }
    if active {
      NSColor.white.setFill()
      NSBezierPath(ovalIn: NSRect(x: 95, y: 96, width: 11, height: 11)).fill()
    }
    NSGraphicsContext.restoreGraphicsState()
  }
}
