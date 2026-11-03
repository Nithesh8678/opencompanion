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

struct NotchMotionStatistics: Codable {
  let displayLinkCallbacks: Int
  let medianIntervalMS: Double
  let p95IntervalMS: Double
  let maximumIntervalMS: Double
  let retargetsWhileMoving: Int
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
  static let blue = Color(red: 0.72, green: 0.83, blue: 1)
  static let mint = Color(red: 0.77, green: 0.94, blue: 0.84)
}

@MainActor private final class ShellPresentation: ObservableObject {
  @Published var state = NotchPresentationState()
  var expanded: Bool { state.exposure == .interactive }
  var peeked: Bool { state.exposure == .hover }
  var destination: NotchDestination { state.destination }
  @Published var contentSize = CGSize(width: 516, height: 160)
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
  private var surfaceHost: ShellSurfaceHost?
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
  private var outsideClickMonitor: Any?
  private var pointerPolling: NotchPointerPolling?
  private var hoverTransition: Task<Void, Never>?
  private var hoverTransitionID: UUID?
  private var hoverAction = NotchHoverPolicy.Action.none
  private var hoverPolicy = NotchHoverPolicy()
  private var lastPointer = CGPoint.zero
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
      navigate: { [weak self] destination in self?.navigate(to: destination) },
      collapse: { [weak self] in self?.collapse() },
      dismissFeedback: { [weak self] in self?.dismissFeedback() },
      capture: { [weak self] source in self?.captureScreen(source) },
      send: { [weak self] in self?.send() },
      selectWindow: { [weak self] window in self?.selectWindow(window) },
      open: { [weak self] section in self?.openWorkspace(section) })
    let host = ShellSurfaceHost(rootView: content)
    surfaceHost = host
    panel.contentView = host
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
      outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [
        .leftMouseDown, .rightMouseDown,
      ]) {
        [weak self] _ in
        MainActor.assumeIsolated {
          guard let self, self.presentation.expanded, !self.model.showingWindowPicker
          else { return }
          self.collapse()
        }
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

  var motionStatistics: NotchMotionStatistics { motion.statistics }

  private var surface: NotchSurface {
    if presentation.state.exposure == .tucked { return .tucked }
    switch presentation.destination {
    case .home: return .peek
    case .chat: return .conversation
    case .settings: return .settings
    }
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

  /// The hold shortcut owns audio only. Pointer presence alone owns the HUD.
  func showVoiceActivity() { observeCurrentPointer() }

  func shutdown() {
    pointerPolling?.stop()
    hoverTransition?.cancel()
    motion.stop()
    if let globalPointerMonitor { NSEvent.removeMonitor(globalPointerMonitor) }
    if let localPointerMonitor { NSEvent.removeMonitor(localPointerMonitor) }
    if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
    globalPointerMonitor = nil
    localPointerMonitor = nil
    outsideClickMonitor = nil
  }

  private func presentPeek() {
    hoverTransition?.cancel()
    hoverAction = .none
    presentation.state.revealHome()
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
      displayedFrame: panel.frame)
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
          displayedFrame: self.panel.frame) == action
      else { return }
      self.hoverAction = .none
      if action == .reveal {
        self.model.record("notch.hoverRevealed")
        self.presentPeek()
      } else {
        self.model.record("notch.hoverTucked")
        self.collapse(restoringFocus: self.presentation.expanded)
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
    presentation.state.tuck()
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

  private func expand() { navigate(to: .chat) }

  func openSettings() { navigate(to: .settings) }

  func navigate(to destination: NotchDestination) {
    // External keyboard/menu invocations must not reveal a HUD away from the
    // notch. Synthetic acceptance opts out of physical pointer observation.
    if observesPointer && presentation.anchor == .notch, let layout,
      !layout.containsPointer(NSEvent.mouseLocation, surface: surface, displayedFrame: panel.frame)
    {
      return
    }
    hoverTransition?.cancel()
    hoverAction = .none
    if let foreground = NSWorkspace.shared.frontmostApplication,
      foreground.processIdentifier != ProcessInfo.processInfo.processIdentifier
    {
      previousApplication = foreground
    }
    presentation.state.open(destination)
    panel.permitsKeyboard = true
    position(animated: true)
    // This activation follows an explicit click/hotkey/Dock invocation.
    NSApp.activate(ignoringOtherApps: true)
    panel.makeKeyAndOrderFront(nil)
    if destination == .chat { presentation.focusEpoch += 1 }
  }

  private func openWorkspace(_ section: String) {
    invalidateInvocations()
    collapse(restoringFocus: false)
    model.section = section
    onOpenWorkspace()
  }

  private func dismissFeedback() {
    model.error = nil
    model.voiceNotice = nil
    if !voiceIsActive {
      observeCurrentPointer()
    }
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
    if surface != .tucked {
      let contentSize = CGSize(
        width: size.width - (presentation.hasCutout ? 14 : 0), height: size.height)
      presentation.contentSize = contentSize
      surfaceHost?.configure(size: contentSize, attached: presentation.hasCutout)
    }
    let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    if animated && !reduceMotion {
      motion.move(panel, to: frame)
    } else {
      motion.stop()
      panel.setFrame(frame, display: true)
    }
  }
}

/// A tight native viewport avoids a screen-sized invisible input surface. The
/// hosted SwiftUI content keeps its final layout during the animation; only its
/// origin, a native mask and the viewport change on display callbacks.
@MainActor private final class ShellSurfaceHost: NSView {
  private let hosting: NSHostingView<CompanionShellView>
  private let surfaceMask = CAShapeLayer()
  private var contentSize = CGSize(width: 516, height: 160)
  var attached = true

  init(rootView: CompanionShellView) {
    hosting = NSHostingView(rootView: rootView)
    super.init(frame: .zero)
    wantsLayer = true
    layer?.backgroundColor = NSColor.black.cgColor
    layer?.mask = surfaceMask
    addSubview(hosting)
  }
  required init?(coder: NSCoder) { nil }

  func configure(size: CGSize, attached: Bool) {
    contentSize = size
    self.attached = attached
    needsLayout = true
  }

  override func layout() {
    super.layout()
    hosting.frame = CGRect(
      x: (bounds.width - contentSize.width) / 2,
      y: bounds.height - contentSize.height, width: contentSize.width, height: contentSize.height)
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    surfaceMask.frame = bounds
    surfaceMask.path = Self.path(in: bounds, attached: attached)
    CATransaction.commit()
  }

  private static func path(in rect: CGRect, attached: Bool) -> CGPath {
    guard attached else {
      return CGPath(roundedRect: rect, cornerWidth: 24, cornerHeight: 24, transform: nil)
    }
    let w = rect.width
    let h = rect.height
    let inset = min(7, max(0, (w - 190) / 40))
    let radius = min(24, h / 3)
    let shoulder = min(12, h / 4)
    let left = inset
    let right = w - inset
    let path = CGMutablePath()
    path.move(to: CGPoint(x: 0, y: h))
    path.addCurve(
      to: CGPoint(x: left, y: h - shoulder),
      control1: CGPoint(x: left, y: h), control2: CGPoint(x: left, y: h - shoulder / 2))
    path.addLine(to: CGPoint(x: left, y: radius))
    path.addQuadCurve(to: CGPoint(x: left + radius, y: 0), control: CGPoint(x: left, y: 0))
    path.addLine(to: CGPoint(x: right - radius, y: 0))
    path.addQuadCurve(to: CGPoint(x: right, y: radius), control: CGPoint(x: right, y: 0))
    path.addLine(to: CGPoint(x: right, y: h - shoulder))
    path.addCurve(
      to: CGPoint(x: w, y: h), control1: CGPoint(x: right, y: h),
      control2: CGPoint(x: w - inset / 2, y: h))
    path.closeSubpath()
    return path
  }
}

/// One local display-synchronized clock, independent of inference or audio IO.
/// The analytic spring preserves pose and velocity when retargeted.
@MainActor private final class ShellFrameMotion: NSObject {
  private var link: CADisplayLink?
  private weak var window: NSWindow?
  private var x = NotchSpring(0), y = NotchSpring(0)
  private var width = NotchSpring(0), height = NotchSpring(0)
  private var lastTick = 0.0
  private var target = CGRect.zero
  private var intervals: [Double] = []
  private var retargets = 0

  var statistics: NotchMotionStatistics {
    let sorted = intervals.sorted()
    func percentile(_ fraction: Double) -> Double {
      guard !sorted.isEmpty else { return 0 }
      return sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * fraction))] * 1_000
    }
    return NotchMotionStatistics(
      displayLinkCallbacks: sorted.count, medianIntervalMS: percentile(0.5),
      p95IntervalMS: percentile(0.95), maximumIntervalMS: percentile(1),
      retargetsWhileMoving: retargets)
  }

  func move(_ window: NSWindow, to frame: CGRect) {
    if link != nil { retargets += 1 }
    if self.window !== window || link == nil {
      let current = window.frame
      x = NotchSpring(current.minX)
      y = NotchSpring(current.minY)
      width = NotchSpring(current.width)
      height = NotchSpring(current.height)
    }
    self.window = window
    target = frame
    x.target = frame.minX
    y.target = frame.minY
    width.target = frame.width
    height.target = frame.height
    lastTick = ProcessInfo.processInfo.systemUptime
    if link == nil, let view = window.contentView {
      let displayLink = view.displayLink(target: self, selector: #selector(tick(_:)))
      displayLink.add(to: .main, forMode: .common)
      link = displayLink
    }
    link?.isPaused = false
  }

  @objc private func tick(_ sender: CADisplayLink) {
    guard let window, window.isVisible else {
      stop()
      return
    }
    let now = ProcessInfo.processInfo.systemUptime
    let delta = max(0, now - lastTick)
    if intervals.count < 2_400 { intervals.append(delta) }
    lastTick = now
    x.advance(by: delta)
    y.advance(by: delta)
    width.advance(by: delta)
    height.advance(by: delta)
    let settled = x.isSettled && y.isSettled && width.isSettled && height.isSettled
    window.setFrame(
      settled
        ? target
        : CGRect(
          x: x.value, y: y.value, width: max(1, width.value), height: max(1, height.value)),
      display: true)
    if settled {
      window.invalidateShadow()
      stop()
    }
  }
  func stop() {
    link?.invalidate()
    link = nil
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
  let navigate: (NotchDestination) -> Void
  let collapse: () -> Void
  let dismissFeedback: () -> Void
  let capture: (ShellCaptureSource) -> Void
  let send: () -> Void
  let selectWindow: (CaptureWindow) -> Void
  let open: (String) -> Void
  @FocusState private var inputFocused: Bool
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  private var visible: Bool { presentation.state.exposure != .tucked }
  private var active: Bool {
    model.busy || model.listening || model.pushToTalkActive || model.state == "Speaking"
  }
  private var headerHeight: CGFloat { max(36, presentation.topInset) }

  var body: some View {
    ZStack(alignment: .top) {
      home.frame(
        width: presentation.contentSize.width,
        height: presentation.contentSize.height - headerHeight
      )
      .clipped().padding(.top, headerHeight)
      .opacity(visible && presentation.destination == .home ? 1 : 0)
      .allowsHitTesting(visible && presentation.destination == .home)
      .accessibilityHidden(!visible || presentation.destination != .home)
      chat.frame(
        width: presentation.contentSize.width,
        height: presentation.contentSize.height - headerHeight
      )
      .clipped().padding(.top, headerHeight)
      .opacity(visible && presentation.destination == .chat ? 1 : 0)
      .allowsHitTesting(visible && presentation.destination == .chat)
      .disabled(!visible || presentation.destination != .chat)
      .accessibilityHidden(!visible || presentation.destination != .chat)
      CompanionSettingsView(model: model, openDestination: open)
        .frame(
          width: presentation.contentSize.width,
          height: max(0, presentation.contentSize.height - headerHeight - 12)
        )
        .clipped().padding(.top, headerHeight + 12)
        .opacity(visible && presentation.destination == .settings ? 1 : 0)
        .allowsHitTesting(visible && presentation.destination == .settings)
        .disabled(!visible || presentation.destination != .settings)
        .accessibilityHidden(!visible || presentation.destination != .settings)
      header.frame(width: presentation.contentSize.width, height: headerHeight)
        .opacity(visible ? 1 : 0).allowsHitTesting(visible).accessibilityHidden(!visible)
      if !presentation.hasCutout && !visible {
        Button(action: expand) {
          HStack(spacing: 10) {
            CompanionMote(state: model.state, active: active).frame(width: 28, height: 28)
            Image(systemName: "ellipsis").foregroundStyle(ShellPalette.secondary)
          }.frame(width: 96, height: 36)
        }.buttonStyle(.plain).accessibilityLabel("Open OpenCompanion")
      }
    }
    .frame(width: presentation.contentSize.width, height: presentation.contentSize.height)
    .background(.black)
    .preferredColorScheme(.dark).tint(ShellPalette.blue)
    .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: presentation.destination)
    .animation(reduceMotion ? nil : .easeOut(duration: 0.10), value: visible)
    .onChange(of: presentation.focusEpoch) { _, _ in inputFocused = true }
    .onChange(of: presentation.destination) { _, value in if value != .chat { inputFocused = false }
    }
    .onChange(of: presentation.state.exposure) { _, value in
      if value != .interactive { inputFocused = false }
    }
    .onExitCommand {
      model.stop()
      collapse()
    }
    .sheet(isPresented: $model.showingWindowPicker) {
      VStack(alignment: .leading, spacing: 14) {
        Text("Choose a window to share").font(
          .system(size: 19, weight: .semibold, design: .rounded))
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
      }.padding(22).frame(width: 480).preferredColorScheme(.dark)
    }
  }

  private var header: some View {
    HStack(spacing: 8) {
      HStack(spacing: 2) {
        navigationButton(.home, symbol: "waveform.path", label: "Home")
        navigationButton(.chat, symbol: "bubble.left.and.bubble.right.fill", label: "Chat")
      }.padding(3).background(Color(white: 0.055), in: Capsule())
      Spacer(minLength: 8)
      // This space stays black behind the hardware camera housing.
      if active {
        Button {
          model.stop()
        } label: {
          Image(systemName: "stop.fill").font(.system(size: 10)).frame(width: 28, height: 26)
        }
        .buttonStyle(.plain).foregroundStyle(ShellPalette.text).accessibilityLabel("Stop response")
      }
      Button {
        open("Companion")
      } label: {
        Image(systemName: "arrow.up.left.and.arrow.down.right").font(
          .system(size: 11, weight: .semibold)
        )
        .frame(width: 32, height: 27).background(Color(white: 0.055), in: Capsule())
      }.buttonStyle(.plain).foregroundStyle(ShellPalette.secondary)
        .accessibilityLabel("Open chat in a window").help("Open chat in a window")
      navigationButton(.settings, symbol: "gearshape.fill", label: "Settings")
    }.frame(height: headerHeight).padding(.horizontal, 20)
  }

  private func navigationButton(_ destination: NotchDestination, symbol: String, label: String)
    -> some View
  {
    Button {
      navigate(destination)
    } label: {
      Image(systemName: symbol).font(.system(size: 13, weight: .semibold))
        .foregroundStyle(
          presentation.destination == destination ? ShellPalette.text : ShellPalette.secondary
        )
        .frame(width: destination == .settings ? 34 : 36, height: 26)
        .background(
          presentation.destination == destination ? Color(white: 0.17) : .clear, in: Capsule())
    }.buttonStyle(.plain).accessibilityLabel(label)
      .accessibilityAddTraits(presentation.destination == destination ? .isSelected : [])
      .help(label)
  }

  private var greeting: String {
    switch Calendar.current.component(.hour, from: Date()) {
    case 5..<12: return "Good morning."
    case 12..<17: return "Good afternoon."
    default: return "Good evening."
    }
  }

  private var home: some View {
    VStack(spacing: 0) {
      Spacer(minLength: 4)
      if active || model.error != nil || model.voiceNotice != nil {
        VStack(spacing: 6) {
          HStack(spacing: 10) {
            Text(model.listening ? "Listening…" : model.state)
              .font(.system(size: 20, weight: .semibold, design: .rounded))
            if model.listening {
              ShellSignal(level: model.microphoneLevel).frame(width: 28, height: 21)
            } else if model.busy {
              ProgressView().controlSize(.small)
            }
            if !active && (model.error != nil || model.voiceNotice != nil) {
              Button(action: dismissFeedback) {
                Image(systemName: "xmark.circle.fill").font(.system(size: 13))
                  .foregroundStyle(ShellPalette.secondary)
              }.buttonStyle(.plain).accessibilityLabel("Dismiss voice feedback")
            }
          }
          Text(homeFeedback).font(.system(size: 12, weight: .medium, design: .rounded))
            .foregroundStyle(ShellPalette.secondary).lineLimit(2).multilineTextAlignment(.center)
        }.frame(maxWidth: .infinity)
      } else {
        Text(greeting).font(.system(size: 20, weight: .semibold, design: .rounded)).tracking(-0.5)
        Text(
          model.voiceShortcutAvailable
            ? "Hold Control + Option and tell me what’s on your mind."
            : "Ask a question, or open Chat to get started."
        )
        .font(.system(size: 12, weight: .medium, design: .rounded)).foregroundStyle(
          ShellPalette.secondary
        )
        .padding(.top, 5)
      }
      Spacer(minLength: 8)
      HStack(spacing: 8) {
        Button {
          open(model.scene == nil ? "Library" : "Notebook")
        } label: {
          Label(
            model.scene == nil ? "Your library" : "Open notebook",
            systemImage: model.scene == nil ? "books.vertical" : "square.and.pencil"
          )
          .font(.system(size: 11.5, weight: .semibold, design: .rounded))
          .foregroundStyle(.black).padding(.horizontal, 13).frame(height: 30)
          .background(
            LinearGradient(
              colors: [Color.white, ShellPalette.mint, ShellPalette.mint.opacity(0.85)],
              startPoint: .top, endPoint: .bottom), in: Capsule()
          )
          .overlay(Capsule().strokeBorder(.white.opacity(0.5), lineWidth: 1))
        }.buttonStyle(.plain)
        Circle().fill(
          model.voiceShortcutAvailable ? ShellPalette.mint.opacity(0.8) : ShellPalette.secondary
        )
        .frame(width: 5, height: 5).padding(9).background(Color(white: 0.055), in: Circle())
        .accessibilityLabel(
          model.voiceShortcutAvailable ? "Voice shortcut ready" : "Voice shortcut needs setup")
        Spacer()
        Button {
          open("Connections")
        } label: {
          Label("Apps +", systemImage: "square.grid.2x2").font(
            .system(size: 11.5, weight: .semibold, design: .rounded)
          )
          .padding(.horizontal, 12).frame(height: 30).background(Color(white: 0.07), in: Capsule())
        }.buttonStyle(.plain).foregroundStyle(ShellPalette.secondary)
      }.padding(.bottom, 17)
    }.padding(.horizontal, 20).foregroundStyle(ShellPalette.text)
  }

  private var homeFeedback: String {
    if let error = model.error { return error }
    if let notice = model.voiceNotice { return notice }
    if model.pushToTalkActive {
      return model.voiceTranscript.isEmpty
        ? "Release Control + Option to send." : model.voiceTranscript
    }
    if model.listening {
      return model.voiceTranscript.isEmpty
        ? "Finish listening in Chat, then review and send." : model.voiceTranscript
    }
    if model.state == "Speaking",
      let message = model.messages.last(where: { $0.role == "assistant" })
    {
      return message.text
    }
    return "You can keep working while I think."
  }

  private var chat: some View {
    VStack(spacing: 0) {
      CompanionTranscriptView(model: model).padding(.horizontal, 20)
      if let error = model.error {
        HStack(alignment: .top, spacing: 8) {
          Image(systemName: "exclamationmark.circle")
          Text(error).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
          Spacer(minLength: 0)
          Button {
            model.error = nil
          } label: {
            Image(systemName: "xmark")
          }.buttonStyle(.plain)
        }.font(.system(size: 11)).foregroundStyle(ShellPalette.secondary)
          .padding(12).background(Color(white: 0.08), in: RoundedRectangle(cornerRadius: 12))
          .padding(.horizontal, 18).padding(.bottom, 8)
      }
      composer.padding(.horizontal, 18).padding(.bottom, 16)
    }
  }

  private var composer: some View {
    VStack(alignment: .leading, spacing: 8) {
      if !model.contextTitle.isEmpty {
        HStack(spacing: 6) {
          Image(systemName: "doc.viewfinder")
          Text(model.contextTitle).lineLimit(1)
          Button {
            model.clearContext()
          } label: {
            Image(systemName: "xmark.circle.fill")
          }
          .buttonStyle(.plain).accessibilityLabel("Remove selected context")
          Spacer()
        }.font(.system(size: 10.5)).foregroundStyle(ShellPalette.secondary)
      }
      HStack(alignment: .bottom, spacing: 10) {
        Button {
          model.toggleVoice()
        } label: {
          Image(systemName: model.listening ? "stop.fill" : "mic.fill")
            .font(.system(size: 15, weight: .medium)).foregroundStyle(.black).frame(
              width: 44, height: 44
            )
            .background(
              LinearGradient(
                colors: [.white, ShellPalette.blue], startPoint: .top, endPoint: .bottom),
              in: RoundedRectangle(cornerRadius: 15))
        }.buttonStyle(.plain).accessibilityLabel(model.listening ? "Finish listening" : "Talk")
          .disabled(
            model.pushToTalkActive || model.voiceInputState == "Finishing speech"
              || (model.busy && !model.listening)
          )
          .help("Talk, then review your words before sending")
        HStack(alignment: .center, spacing: 8) {
          TextField(
            model.listening ? "Listening…" : "Ask OpenCompanion…", text: $model.input,
            axis: .vertical
          )
          .textFieldStyle(.plain).font(.system(size: 13)).lineLimit(1...4)
          .focused($inputFocused).onSubmit {
            if !model.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { send() }
          }
          .accessibilityLabel("Message companion").accessibilityIdentifier("companion.input")
          Button(action: active ? { model.stop() } : send) {
            Image(systemName: active ? "stop.fill" : "arrow.up").font(
              .system(size: 12, weight: .semibold)
            )
            .frame(width: 27, height: 27).background(
              ShellPalette.blue.opacity(active ? 0.25 : 1), in: Circle()
            )
            .foregroundStyle(active ? .white : .black)
          }.buttonStyle(.plain).accessibilityLabel(active ? "Stop response" : "Send message")
            .disabled(
              !active && model.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }.padding(12).frame(minHeight: 44).background(
          Color(white: 0.09), in: RoundedRectangle(cornerRadius: 15))
      }
      HStack(spacing: 16) {
        Menu {
          Button("Share display") { capture(.display) }
          Button("Choose a window…") { capture(.window) }
          Button("Select a region…") { capture(.region) }
          Button("Draw what you mean…") { capture(.scribble) }
        } label: {
          Label("Screen", systemImage: "viewfinder")
        }.menuStyle(.borderlessButton).fixedSize()
        Button {
          model.importFile()
        } label: {
          Label("Attach file", systemImage: "paperclip")
        }
        Spacer()
        if model.scene != nil { Button("Notebook") { open("Notebook") } }
        Toggle("Read aloud", isOn: $model.configuration.speechEnabled).toggleStyle(.checkbox)
      }.font(.system(size: 10.5)).buttonStyle(.plain).foregroundStyle(ShellPalette.secondary)
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

/// Real input-envelope feedback; quiet input stays quiet. No synthetic sine meter.
private struct ShellSignal: View {
  let level: Double
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  var body: some View {
    HStack(alignment: .center, spacing: 3) {
      ForEach(0..<5) { index in
        Capsule().fill(ShellPalette.mint).frame(
          width: 2.5,
          height: 3 + max(0, min(1, level)) * [9.0, 14, 19, 14, 9][index])
      }
    }.animation(reduceMotion ? nil : .easeOut(duration: 0.07), value: level).accessibilityHidden(
      true)
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
