import AppKit
@preconcurrency import ApplicationServices
import CoreMedia
import CoreVideo
import Foundation
@preconcurrency import ScreenCaptureKit

struct GuidanceObservationDiagnostics: Codable, Equatable, Sendable {
  let active: Bool
  let streamStarted: Bool
  let accessibilityNotifications: Int
  let acceptedFrames: UInt64
  let changedFrames: UInt64
  let emittedEvents: UInt64
  let latestContentTime: TimeInterval?
}

/// Active, deliberate local observation only. The host owns scheduling and
/// final screenshot evidence. Initialization never installs a monitor, reads
/// Accessibility, starts capture, prompts for permission, or calls a provider.
@MainActor final class ActiveGuidanceScreenObserver {
  private let observesSystemEvents: Bool
  private let now: @MainActor () -> TimeInterval
  private let onChange: @MainActor (GuidanceObservationScope, GuidanceObservationEvent) -> Void
  private(set) var scope: GuidanceObservationScope?
  private var runID: UUID?
  private var began: TimeInterval = 0
  private var sequence: UInt64 = 0
  private var acceptedFrames: UInt64 = 0
  private var changedFrames: UInt64 = 0
  private var frames = GuidanceLatestFrameState()
  private var stream: SCStream?
  private var output: GuidanceObservationOutput?
  private var streamLifetime: GuidanceObservationStreamLifetime?
  private var streamStarted = false
  private let metadata = GuidanceObservationMetadataLifetime()
  private var ax: GuidanceAXRegistration?
  private var focusedBounds: CGRect?

  init(
    observeSystemEvents: Bool = true,
    now: @escaping @MainActor () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
    onChange: @escaping @MainActor (GuidanceObservationScope, GuidanceObservationEvent) -> Void
  ) {
    observesSystemEvents = observeSystemEvents
    self.now = now
    self.onChange = onChange
  }

  var latestFrame: GuidanceObservationFrame? { frames.latestFrame }
  var diagnostics: GuidanceObservationDiagnostics {
    .init(
      active: scope != nil, streamStarted: streamStarted,
      accessibilityNotifications: ax?.notificationCount ?? 0,
      acceptedFrames: acceptedFrames, changedFrames: changedFrames,
      emittedEvents: sequence, latestContentTime: frames.latestFrame?.contentTime)
  }

  func start(scope owner: GuidanceObservationScope) async throws {
    stop()
    try Task.checkCancellation()
    guard owner.foregroundPID != ProcessInfo.processInfo.processIdentifier else {
      throw GuidanceObservationFailure.invalidScope
    }
    let time = now()
    guard time.isFinite, time >= 0 else { throw GuidanceObservationFailure.invalidScope }
    let run = UUID()
    scope = owner
    runID = run
    began = time
    acceptedFrames = 0
    changedFrames = 0
    guard observesSystemEvents else { return }
    guard CGPreflightScreenCaptureAccess() else {
      stop()
      throw GuidanceObservationFailure.permissionUnavailable
    }
    installMetadata(for: owner, run: run)
    do {
      let source = try await nativeSource(owner)
      try Task.checkCancellation()
      guard owns(owner, run: run) else { throw CancellationError() }
      let sink = GuidanceObservationOutput(
        windowScoped: owner.windowID != nil,
        onFrames: { [weak self] mailbox in self?.drain(mailbox, owner: owner, run: run) },
        onStop: { [weak self] reason in
          self?.receive(reason: reason, scope: owner, timestamp: self?.now() ?? 0, run: run)
        })
      let native = SCStream(
        filter: source.filter, configuration: source.configuration, delegate: sink)
      try native.addStreamOutput(sink, type: .screen, sampleHandlerQueue: sink.queue)
      output = sink
      stream = native
      streamLifetime = GuidanceObservationStreamLifetime(stream: native, output: sink)
      ax = GuidanceAXRegistration(
        scope: owner, sourceWindowBounds: source.windowBounds, primaryTop: source.primaryTop
      ) { [weak self] result in
        guard let self, self.owns(owner, run: run) else { return }
        if result.reason == nil || result.reason == .focusChanged || result.reason == .windowChanged
          || result.reason == .geometryChanged
        {
          self.focusedBounds = result.focusedBounds
        }
        if let reason = result.reason {
          self.receive(reason: reason, scope: owner, timestamp: self.now(), run: run)
        }
      }
      try await native.startCapture()
      try Task.checkCancellation()
      guard owns(owner, run: run) else {
        native.stopCapture(completionHandler: { _ in })
        throw CancellationError()
      }
      streamStarted = true
    } catch {
      if owns(owner, run: run) { stop() }
      if error is CancellationError { throw error }
      throw GuidanceObservationFailure.streamUnavailable
    }
  }

  /// Revocation is synchronous. Native shutdown may complete later, but its
  /// retained output/AX callbacks cannot publish into a replacement lease.
  func stop() {
    scope = nil
    runID = nil
    focusedBounds = nil
    frames.reset()
    streamStarted = false
    output?.invalidate()
    streamLifetime?.stop()
    streamLifetime = nil
    stream = nil
    output = nil
    ax?.invalidate()
    ax = nil
    metadata.remove()
  }

  // Deterministic ingestion uses the exact same lease/scope/time reducer as OS
  // callbacks. It installs no monitors when observeSystemEvents is false.
  func receive(
    reason: GuidanceObservationEvent.Reason, scope owner: GuidanceObservationScope,
    timestamp: TimeInterval
  ) {
    guard let run = runID else { return }
    receive(reason: reason, scope: owner, timestamp: timestamp, run: run)
  }

  func receiveFrame(_ frame: GuidanceObservationFrame, scope owner: GuidanceObservationScope) {
    guard let run = runID else { return }
    accept(frame, owner: owner, run: run)
  }

  func receiveActivation(pid: pid_t?, scope owner: GuidanceObservationScope) {
    guard pid != owner.foregroundPID else { return }
    receive(reason: .foregroundChanged, scope: owner, timestamp: now())
  }

  func receiveScroll(
    point: CGPoint?, deltaX: Double, deltaY: Double, foregroundPID: pid_t?, ownWindow: Bool,
    scope owner: GuidanceObservationScope, timestamp: TimeInterval
  ) {
    guard !ownWindow, foregroundPID == owner.foregroundPID,
      let point, point.x.isFinite, point.y.isFinite, owner.sourceRect.contains(point),
      deltaX.isFinite, deltaY.isFinite, deltaX != 0 || deltaY != 0
    else { return }
    receive(reason: .scroll, scope: owner, timestamp: timestamp)
  }

  private func owns(_ owner: GuidanceObservationScope, run: UUID) -> Bool {
    scope == owner && runID == run
  }

  private func receive(
    reason: GuidanceObservationEvent.Reason, scope owner: GuidanceObservationScope,
    timestamp: TimeInterval, run: UUID
  ) {
    guard owns(owner, run: run), timestamp.isFinite, timestamp >= began,
      timestamp <= now(), sequence < UInt64.max
    else { return }
    sequence += 1
    let event = GuidanceObservationEvent(reason: reason, timestamp: timestamp, sequence: sequence)
    let terminal =
      reason == .foregroundChanged || reason == .suspended || reason == .unavailable
      || (owner.windowID != nil && (reason == .windowChanged || reason == .geometryChanged))
    if terminal { stop() }
    onChange(owner, event)
  }

  private func accept(_ frame: GuidanceObservationFrame, owner: GuidanceObservationScope, run: UUID)
  {
    guard owns(owner, run: run), frame.receivedAt >= began, frame.receivedAt <= now() else {
      return
    }
    let update = frames.accept(frame)
    guard update != .rejected else { return }
    acceptedFrames &+= 1
    if update == .changed {
      changedFrames &+= 1
      receive(reason: .visualChange, scope: owner, timestamp: frame.receivedAt, run: run)
    }
  }

  private func drain(
    _ mailbox: GuidanceLatestFrameMailbox, owner: GuidanceObservationScope, run: UUID
  ) {
    if let frame = mailbox.take() { accept(frame, owner: owner, run: run) }
    if mailbox.finishDrain() {
      Task { @MainActor [weak self] in self?.drain(mailbox, owner: owner, run: run) }
    }
  }

  private func installMetadata(for owner: GuidanceObservationScope, run: UUID) {
    let workspace = NSWorkspace.shared.notificationCenter
    func watch(
      _ center: NotificationCenter, _ name: Notification.Name,
      action: @escaping @MainActor @Sendable (pid_t?) -> Void
    ) {
      let token = center.addObserver(forName: name, object: nil, queue: .main) { notification in
        let pid =
          (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?
          .processIdentifier
        MainActor.assumeIsolated { action(pid) }
      }
      metadata.notifications.append((center, token))
    }
    watch(workspace, NSWorkspace.didActivateApplicationNotification) { [weak self] pid in
      guard let self, self.owns(owner, run: run) else { return }
      if pid != owner.foregroundPID {
        self.receive(reason: .foregroundChanged, scope: owner, timestamp: self.now(), run: run)
      }
    }
    for name in [
      NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification,
      NSWorkspace.sessionDidResignActiveNotification,
    ] {
      watch(workspace, name) { [weak self] _ in
        self?.receive(reason: .suspended, scope: owner, timestamp: self?.now() ?? 0, run: run)
      }
    }
    watch(NotificationCenter.default, NSApplication.didChangeScreenParametersNotification) {
      [weak self] _ in
      self?.receive(reason: .unavailable, scope: owner, timestamp: self?.now() ?? 0, run: run)
    }
    let globalScroll = NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel) {
      [weak self] event in
      MainActor.assumeIsolated { self?.scroll(event, owner: owner, run: run, ownWindow: false) }
    }
    let localScroll = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) {
      [weak self] event in
      MainActor.assumeIsolated {
        self?.scroll(event, owner: owner, run: run, ownWindow: event.window != nil)
      }
      return event
    }
    // Only the existence of ordinary text entry is observed. No key codes,
    // characters, field values, transcripts or event objects are retained.
    let globalKeys = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
      MainActor.assumeIsolated { self?.typing(event, owner: owner, run: run, ownWindow: false) }
    }
    let localKeys = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
      MainActor.assumeIsolated {
        self?.typing(event, owner: owner, run: run, ownWindow: event.window != nil)
      }
      return event
    }
    metadata.monitors = [globalScroll, localScroll, globalKeys, localKeys].compactMap { $0 }
  }

  private func scroll(_ event: NSEvent, owner: GuidanceObservationScope, run: UUID, ownWindow: Bool)
  {
    guard owns(owner, run: run) else { return }
    let point = ScreenGuidancePolicy.appKitPoint(
      quartz: event.cgEvent?.location, mainTop: NSScreen.screens.first?.frame.maxY)
    receiveScroll(
      point: point, deltaX: Double(event.scrollingDeltaX), deltaY: Double(event.scrollingDeltaY),
      foregroundPID: NSWorkspace.shared.frontmostApplication?.processIdentifier,
      ownWindow: ownWindow, scope: owner, timestamp: event.timestamp)
  }

  private func typing(_ event: NSEvent, owner: GuidanceObservationScope, run: UUID, ownWindow: Bool)
  {
    guard owns(owner, run: run), !ownWindow,
      event.modifierFlags.intersection([.command, .control, .option, .function]).isEmpty,
      NSWorkspace.shared.frontmostApplication?.processIdentifier == owner.foregroundPID,
      let focusedBounds, owner.sourceRect.intersects(focusedBounds)
    else { return }
    receive(reason: .typing, scope: owner, timestamp: event.timestamp, run: run)
  }

  private struct NativeSource {
    let filter: SCContentFilter
    let configuration: SCStreamConfiguration
    let windowBounds: CGRect?
    let primaryTop: Double
  }

  private func nativeSource(_ owner: GuidanceObservationScope) async throws -> NativeSource {
    let content = try await SCShareableContent.excludingDesktopWindows(
      false, onScreenWindowsOnly: true)
    try Task.checkCancellation()
    guard let display = content.displays.first(where: { $0.displayID == owner.displayID }),
      let screen = NSScreen.screens.first(where: {
        ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
          == owner.displayID
      }), let primaryTop = NSScreen.screens.first?.frame.maxY, primaryTop.isFinite
    else { throw GuidanceObservationFailure.sourceUnavailable }
    let ownPID = ProcessInfo.processInfo.processIdentifier
    let ownBundle = Bundle.main.bundleIdentifier ?? "org.opencompanion.mac"
    let filter: SCContentFilter
    let base: CGRect
    let windowBounds: CGRect?
    if let id = owner.windowID {
      guard let window = content.windows.first(where: { $0.windowID == id }), window.isOnScreen,
        window.owningApplication?.processID == owner.foregroundPID,
        window.owningApplication?.processID != ownPID,
        window.owningApplication?.bundleIdentifier != ownBundle
      else { throw GuidanceObservationFailure.sourceUnavailable }
      base = CGRect(
        x: window.frame.minX, y: primaryTop - window.frame.maxY,
        width: window.frame.size.width, height: window.frame.size.height)
      windowBounds = base
      filter = SCContentFilter(desktopIndependentWindow: window)
    } else {
      base = screen.frame
      windowBounds = nil
      let own = content.applications.filter {
        $0.processID == ownPID || $0.bundleIdentifier == ownBundle
      }
      filter = SCContentFilter(display: display, excludingApplications: own, exceptingWindows: [])
    }
    guard let sampling = GuidanceObservationSamplingPlan(source: owner.sourceRect, containing: base)
    else {
      throw GuidanceObservationFailure.sourceUnavailable
    }
    let config = SCStreamConfiguration()
    config.width = sampling.width
    config.height = sampling.height
    config.sourceRect = sampling.sourceRect
    config.minimumFrameInterval = CMTime(value: 1, timescale: 10)
    config.queueDepth = 3
    config.pixelFormat = kCVPixelFormatType_32BGRA
    config.showsCursor = false
    config.capturesAudio = false
    config.excludesCurrentProcessAudio = true
    config.scalesToFit = true
    config.ignoreShadowsSingleWindow = true
    config.ignoreShadowsDisplay = true
    return .init(
      filter: filter, configuration: config, windowBounds: windowBounds,
      primaryTop: Double(primaryTop))
  }
}

private final class GuidanceObservationMetadataLifetime: @unchecked Sendable {
  // Mutated only by the MainActor owner. Destruction transfers the final
  // immutable collection to MainActor without retaining a dead observer.
  var notifications: [(NotificationCenter, NSObjectProtocol)] = []
  var monitors: [Any] = []

  @MainActor func remove() {
    for (center, observer) in notifications { center.removeObserver(observer) }
    for monitor in monitors { NSEvent.removeMonitor(monitor) }
    notifications.removeAll()
    monitors.removeAll()
  }

  deinit {
    guard !notifications.isEmpty || !monitors.isEmpty else { return }
    let cleanup = GuidanceObservationMetadataCleanup(
      notifications: notifications, monitors: monitors)
    Task { @MainActor in cleanup.remove() }
  }
}

private struct GuidanceObservationMetadataCleanup: @unchecked Sendable {
  let notifications: [(NotificationCenter, NSObjectProtocol)]
  let monitors: [Any]
  @MainActor func remove() {
    for (center, observer) in notifications { center.removeObserver(observer) }
    for monitor in monitors { NSEvent.removeMonitor(monitor) }
  }
}

private final class GuidanceObservationStreamLifetime: @unchecked Sendable {
  private let lock = NSLock()
  private var stopped = false
  private let stream: SCStream
  private let output: GuidanceObservationOutput

  init(stream: SCStream, output: GuidanceObservationOutput) {
    self.stream = stream
    self.output = output
  }

  func stop() {
    let first = lock.withLock {
      guard !stopped else { return false }
      stopped = true
      return true
    }
    guard first else { return }
    output.invalidate()
    try? stream.removeStreamOutput(output, type: .screen)
    stream.stopCapture(completionHandler: { _ in })
  }

  deinit { stop() }
}

/// Serial native sample reader. It copies at most 256×160 BGRA pixels before
/// returning; mutable CMSampleBuffer/CVPixelBuffer never cross actor boundaries.
private final class GuidanceObservationOutput: NSObject, SCStreamOutput, SCStreamDelegate,
  @unchecked Sendable
{
  let queue = DispatchQueue(label: "org.opencompanion.guidance.observation", qos: .userInitiated)
  private let mailbox = GuidanceLatestFrameMailbox()
  private let terminalLock = NSLock()
  private var terminal = false
  private var windowGeometry = GuidanceObservationWindowState()
  private let windowScoped: Bool
  private let onFrames: @MainActor @Sendable (GuidanceLatestFrameMailbox) -> Void
  private let onStop: @MainActor @Sendable (GuidanceObservationEvent.Reason) -> Void

  init(
    windowScoped: Bool,
    onFrames: @escaping @MainActor @Sendable (GuidanceLatestFrameMailbox) -> Void,
    onStop: @escaping @MainActor @Sendable (GuidanceObservationEvent.Reason) -> Void
  ) {
    self.windowScoped = windowScoped
    self.onFrames = onFrames
    self.onStop = onStop
  }

  func invalidate() {
    terminalLock.withLock { terminal = true }
    mailbox.invalidate()
  }

  private func ended(_ reason: GuidanceObservationEvent.Reason) {
    let first = terminalLock.withLock {
      guard !terminal else { return false }
      terminal = true
      return true
    }
    guard first else { return }
    mailbox.invalidate()
    Task { @MainActor [onStop] in onStop(reason) }
  }

  func stream(_ stream: SCStream, didStopWithError error: any Error) {
    ended(.unavailable)
  }

  func stream(
    _ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
    of type: SCStreamOutputType
  ) {
    guard !terminalLock.withLock({ terminal }), type == .screen,
      CMSampleBufferIsValid(sampleBuffer),
      let attachments = CMSampleBufferGetSampleAttachmentsArray(
        sampleBuffer, createIfNecessary: false)
        as? [[SCStreamFrameInfo: Any]], let info = attachments.first,
      let statusValue = info[.status] as? NSNumber,
      let status = SCFrameStatus(rawValue: statusValue.intValue)
    else { return }
    if status == .blank || status == .suspended || status == .stopped {
      ended(.suspended)
      return
    }
    if windowScoped, let bounds = info[.screenRect] as? CGRect,
      windowGeometry.accept(bounds)
    {
      // A window may move without changing its independent-window pixels.
      // Consume metadata even on idle; never relabel its pixels as new content.
      ended(.geometryChanged)
      return
    }
    // Idle frames carry no new content. Their delivery time cannot refresh the
    // stored content timestamp or manufacture a new visual-change signal.
    guard status == .complete || status == .started,
      let ticks = info[.displayTime] as? NSNumber,
      let buffer = CMSampleBufferGetImageBuffer(sampleBuffer),
      CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA
    else { return }
    let contentTime = CMTimeGetSeconds(CMClockMakeHostTimeFromSystemUnits(ticks.uint64Value))
    let receivedAt = ProcessInfo.processInfo.systemUptime
    let width = CVPixelBufferGetWidth(buffer)
    let height = CVPixelBufferGetHeight(buffer)
    guard (1...256).contains(width), (1...160).contains(height),
      CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess
    else { return }
    defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
    guard let base = CVPixelBufferGetBaseAddress(buffer) else { return }
    let stride = CVPixelBufferGetBytesPerRow(buffer)
    guard stride >= width * 4, stride <= 1_048_576 else { return }
    var pixels = Data(count: width * height * 4)
    pixels.withUnsafeMutableBytes { destination in
      for row in 0..<height {
        destination.baseAddress!.advanced(by: row * width * 4)
          .copyMemory(from: base.advanced(by: row * stride), byteCount: width * 4)
      }
    }
    guard
      let frame = GuidanceObservationFrame(
        width: width, height: height,
        contentTime: contentTime, receivedAt: receivedAt, pixels: pixels), mailbox.offer(frame)
    else { return }
    Task { @MainActor [onFrames, mailbox] in onFrames(mailbox) }
  }
}
