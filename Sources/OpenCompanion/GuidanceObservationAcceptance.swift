import AppKit
import ApplicationServices
import Darwin
import Foundation

/// Explicit installed component check against one opaque public fixture only.
/// The external driver supplies changes; this helper never posts input, opens
/// a window, activates an app, reads user text, or calls a provider/audio API.
enum GuidanceObservationAcceptance {
  @MainActor static func run(output: URL) async throws {
    let began = ProcessInfo.processInfo.systemUptime
    let collector = Collector()
    var observer: ActiveGuidanceScreenObserver?
    var owner: GuidanceObservationScope?
    var phase = "preflight"
    var failure = "incomplete"
    var passed = false
    var started = false
    var stoppedCleanly = false
    var finalRunning: GuidanceObservationDiagnostics?
    var stopped: GuidanceObservationDiagnostics?
    var postStop: GuidanceObservationDiagnostics?
    let terminal = output.appendingPathComponent("guidance-observation-acceptance.json")
    var terminalWritten = false
    @MainActor func terminalReceipt() -> Receipt {
      let axCount = max(
        finalRunning?.accessibilityNotifications ?? 0, collector.maximumAXNotifications)
      let axEvents = collector.events.filter { Self.axReasons.contains($0.reason) }.count
      let axStatus =
        axCount == 0
        ? "unavailable-visual-fallback"
        : (axEvents > 0 ? "registered-native-events-observed" : "registered-events-not-observed")
      let receipt = Receipt(
        result: passed ? "passed" : "failed", phase: phase, failureCode: passed ? nil : failure,
        sourceRevision: Bundle.main.object(forInfoDictionaryKey: "OpenCompanionSourceRevision")
          as? String ?? "unknown",
        sourceBundleID: Bundle.main.bundleIdentifier ?? "unknown",
        elapsedMS: max(0, (ProcessInfo.processInfo.systemUptime - began) * 1_000),
        fixturePreflightPassed: owner != nil, streamStarted: started,
        scopeGeneration: owner?.generation, scopeDisplayID: owner?.displayID,
        scopeRect: owner?.sourceRect, frames: collector.frames, events: collector.events,
        windowGeometry: collector.windowGeometry,
        lastPreflightRefusalGeometry: collector.lastPreflightRefusalGeometry,
        preflightAttempts: collector.preflightAttempts,
        preflightRefusalCodes: collector.preflightRefusals,
        eventBudgetExceeded: collector.overflow,
        diagnosticsBeforeStop: finalRunning, diagnosticsStopped: stopped,
        diagnosticsAfterStopWait: postStop, stopQuiescentFor500MS: stoppedCleanly,
        axStatus: axStatus, axMetadataEventCount: axEvents,
        accessibilityTrusted: AXIsProcessTrusted(),
        actualNativeObservation: started, localSampledScreenPixels: started,
        modelEvidenceCapture: false, screenshotsSaved: false,
        automaticDesktopInput: false, appActivationRequested: false,
        providerUsed: false, microphoneUsed: false, audioUsed: false,
        fullHostWorkflowExercised: false, physicalInputVerified: false)
      return receipt
    }
    defer {
      observer?.stop()
      if !terminalWritten { try? Self.write(terminalReceipt(), to: terminal) }
    }
    do {
      try FileManager.default.createDirectory(
        at: output, withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
      guard !FileManager.default.fileExists(atPath: terminal.path) else {
        throw Refusal("terminal-output-already-exists")
      }
      phase = "waiting-public-fixture"
      try FileHandle.standardOutput.write(
        contentsOf: Data("GUIDANCE_OBSERVATION_WAITING_PUBLIC_FIXTURE\n".utf8))
      let foregroundDeadline = ProcessInfo.processInfo.systemUptime + 45
      while NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        != "org.opencompanion.fixture.guidance"
      {
        try Task.checkCancellation()
        guard ProcessInfo.processInfo.systemUptime < foregroundDeadline else {
          throw Refusal("public-fixture-foreground-timeout")
        }
        try await Task.sleep(for: .milliseconds(100))
      }
      try Task.checkCancellation()
      phase = "settling-public-fixture"
      let fixture = try await fixtureEnvironment(collector: collector)
      let scope = try GuidanceObservationScope(
        generation: 1,
        foregroundPID: fixture.pid, displayID: fixture.displayID, sourceRect: fixture.screenRect)
      owner = scope
      let active = ActiveGuidanceScreenObserver { delivered, event in
        guard delivered == scope else { return }
        collector.receive(event)
      }
      observer = active
      let startup = Startup()
      let task = Task { @MainActor in
        do {
          try await active.start(scope: scope)
          startup.result = .success(())
        } catch { startup.result = .failure(error) }
      }
      defer { task.cancel() }
      phase = "starting-native-stream"
      let startDeadline = ProcessInfo.processInfo.systemUptime + 5
      while startup.result == nil && ProcessInfo.processInfo.systemUptime < startDeadline {
        try verifyEnvironment(fixture) { collector.windowGeometry = $0 }
        try Task.checkCancellation()
        try await Task.sleep(for: .milliseconds(20))
      }
      guard let completion = startup.result else {
        task.cancel()
        active.stop()
        throw Refusal("native-stream-start-timeout")
      }
      do { try completion.get() } catch { throw Refusal("native-stream-start-failed") }
      guard active.scope == scope, active.diagnostics.streamStarted else {
        throw Refusal("native-stream-not-active")
      }
      started = true
      phase = "waiting-for-public-driver-changes"
      try write(
        Ready(
          phase: phase,
          sourceRevision: Bundle.main.object(forInfoDictionaryKey: "OpenCompanionSourceRevision")
            as? String ?? "unknown",
          observationWindowSeconds: 20, displayID: fixture.displayID,
          sourceRect: fixture.screenRect, nativeStreamStarted: true,
          automaticDesktopInput: false, providerUsed: false, audioUsed: false),
        to: output.appendingPathComponent("guidance-observation-ready.json"))
      try FileHandle.standardOutput.write(contentsOf: Data("GUIDANCE_OBSERVATION_READY\n".utf8))
      let deadline = ProcessInfo.processInfo.systemUptime + 20
      while ProcessInfo.processInfo.systemUptime < deadline {
        try Task.checkCancellation()
        try verifyEnvironment(fixture) { collector.windowGeometry = $0 }
        let diagnostics = active.diagnostics
        finalRunning = diagnostics
        collector.maximumAXNotifications = max(
          collector.maximumAXNotifications,
          diagnostics.accessibilityNotifications)
        if let frame = active.latestFrame { try collector.sample(frame) }
        guard active.scope == scope, diagnostics.streamStarted else {
          throw Refusal("native-observation-revoked")
        }
        guard !collector.overflow else { throw Refusal("native-event-budget-exceeded") }
        let axObserved = collector.events.contains { axReasons.contains($0.reason) }
        if diagnostics.acceptedFrames >= 2, collector.frames.count >= 2,
          diagnostics.changedFrames >= 1,
          collector.events.contains(where: { $0.reason == .visualChange }),
          diagnostics.accessibilityNotifications > 0, axObserved
        {
          // Pending/unsupported AX gets the entire bounded observation window;
          // a quick pixel change alone must not label registration unsupported.
          break
        }
        try await Task.sleep(for: .milliseconds(20))
      }
      finalRunning = active.diagnostics
      guard let running = finalRunning, running.acceptedFrames >= 2,
        collector.frames.count >= 2, running.changedFrames >= 1,
        collector.events.contains(where: { $0.reason == .visualChange })
      else { throw Refusal("fresh-frame-or-visual-change-not-observed") }
      if max(running.accessibilityNotifications, collector.maximumAXNotifications) > 0,
        !collector.events.contains(where: { axReasons.contains($0.reason) })
      {
        throw Refusal("registered-ax-metadata-event-not-observed")
      }
      phase = "checking-stop-quiescence"
      active.stop()
      stopped = active.diagnostics
      let count = collector.events.count
      try await Task.sleep(for: .milliseconds(500))
      postStop = active.diagnostics
      guard stopped == postStop, collector.events.count == count,
        active.scope == nil, active.latestFrame == nil, !active.diagnostics.active,
        !active.diagnostics.streamStarted
      else { throw Refusal("native-observation-continued-after-stop") }
      stoppedCleanly = true
      phase = "complete"
      failure = ""
      passed = true
      do {
        try write(terminalReceipt(), to: terminal)
        terminalWritten = true
      } catch {
        passed = false
        throw error
      }
      try? FileHandle.standardOutput.write(
        contentsOf: Data("GUIDANCE_OBSERVATION_ACCEPTANCE_PASSED\n".utf8))
    } catch let refusal as Refusal {
      failure = refusal.code
      throw ProviderError.message("Public native screen-observation check failed: \(refusal.code).")
    } catch is CancellationError {
      failure = "cancelled"
      throw CancellationError()
    } catch {
      failure = "component-or-output-error"
      throw ProviderError.message("Public native screen-observation check could not complete.")
    }
  }

  private static let axReasons: Set<GuidanceObservationEvent.Reason> = [
    .windowChanged, .focusChanged, .geometryChanged, .menuChanged, .layoutChanged,
  ]

  private struct Refusal: Error {
    let code: String
    init(_ code: String) { self.code = code }
  }
  @MainActor private final class Startup { var result: Result<Void, any Error>? }

  private struct Environment {
    let pid: pid_t
    let launchDate: Date
    let displayID: CGDirectDisplayID
    let screenRect: CGRect
  }

  @MainActor private static func fixtureEnvironment(collector: Collector) async throws
    -> Environment
  {
    guard let app = NSWorkspace.shared.frontmostApplication,
      app.bundleIdentifier == "org.opencompanion.fixture.guidance", !app.isTerminated,
      let date = app.launchDate
    else { throw Refusal("public-fixture-not-foreground") }
    guard let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }),
      let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
      number.uint32Value > 0, GuidanceObservationScope.valid(screen.frame)
    else { throw Refusal("public-fixture-display-unavailable") }
    let environment = Environment(
      pid: app.processIdentifier, launchDate: date,
      displayID: number.uint32Value, screenRect: screen.frame)
    let deadline = ProcessInfo.processInfo.systemUptime + 2
    while true {
      try Task.checkCancellation()
      collector.preflightAttempts += 1
      do {
        try verifyEnvironment(environment) { collector.windowGeometry = $0 }
        return environment
      } catch let error as Refusal {
        collector.lastPreflightRefusalGeometry = collector.windowGeometry
        if collector.preflightRefusals.count < 24 { collector.preflightRefusals.append(error.code) }
        guard
          [
            "public-fixture-front-window-does-not-cover-display",
            "public-fixture-does-not-cover-display",
            "public-fixture-window-metadata-unavailable",
          ].contains(error.code),
          ProcessInfo.processInfo.systemUptime < deadline
        else { throw error }
        let remaining = deadline - ProcessInfo.processInfo.systemUptime
        guard remaining > 0 else { throw error }
        try await Task.sleep(for: .seconds(min(0.1, remaining)))
        try Task.checkCancellation()
        guard ProcessInfo.processInfo.systemUptime < deadline else { throw error }
      }
    }
  }

  @MainActor private static func verifyEnvironment(
    _ expected: Environment, onGeometry: (GuidanceFixtureWindowDiagnostic) -> Void
  ) throws {
    guard let app = NSWorkspace.shared.frontmostApplication,
      app.bundleIdentifier == "org.opencompanion.fixture.guidance",
      app.processIdentifier == expected.pid, app.launchDate == expected.launchDate,
      !app.isTerminated
    else { throw Refusal("public-fixture-foreground-identity-changed") }
    guard let primary = NSScreen.screens.first,
      let screen = NSScreen.screens.first(where: {
        ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
          == expected.displayID
      }), screen.frame == expected.screenRect,
      screen.frame.contains(NSEvent.mouseLocation)
    else { throw Refusal("public-fixture-display-or-pointer-changed") }
    guard let list = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID),
      CFArrayGetCount(list) <= 4_096, let windows = list as? [[String: Any]]
    else { throw Refusal("public-fixture-window-metadata-unavailable") }
    onGeometry(
      .capture(
        expectedPID: expected.pid, displayID: expected.displayID,
        screenRect: expected.screenRect, guardWindows: windows))
    let quartzDisplay = CGRect(
      x: screen.frame.minX,
      y: primary.frame.maxY - screen.frame.maxY,
      width: screen.frame.size.width, height: screen.frame.size.height)
    // WindowServer order is front-to-back. Existence of a covering fixture
    // underneath another application's window is not a public-pixel guarantee.
    // This process is excluded from the stream, so its own windows are skipped.
    let ownPID = ProcessInfo.processInfo.processIdentifier
    for window in windows {
      guard let layer = (window[kCGWindowLayer as String] as? NSNumber)?.intValue else {
        throw Refusal("public-fixture-window-metadata-unavailable")
      }
      guard layer == 0 else { continue }
      guard let pid = (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
        pid > 0,
        let alpha = (window[kCGWindowAlpha as String] as? NSNumber)?.doubleValue,
        alpha.isFinite, (0...1).contains(alpha),
        let dictionary = window[kCGWindowBounds as String] as? [String: Any],
        let rect = CGRect(dictionaryRepresentation: dictionary as CFDictionary),
        GuidanceObservationScope.valid(rect)
      else { throw Refusal("public-fixture-window-metadata-unavailable") }
      guard pid != ownPID, alpha > 0, rect.intersects(quartzDisplay) else { continue }
      guard pid == expected.pid, alpha == 1, rect.contains(quartzDisplay) else {
        throw Refusal("public-fixture-front-window-does-not-cover-display")
      }
      return
    }
    throw Refusal("public-fixture-does-not-cover-display")
  }

  private struct Frame: Codable {
    let width: Int
    let height: Int
    let copiedBytes: Int
    let contentTime: Double
    let receivedAt: Double
    let contentToReceiveMS: Double
  }
  private struct Event: Codable {
    let reason: GuidanceObservationEvent.Reason
    let timestamp: Double
    let sequence: UInt64
  }
  @MainActor private final class Collector {
    var frames: [Frame] = []
    var events: [Event] = []
    var overflow = false
    var maximumAXNotifications = 0
    var windowGeometry: GuidanceFixtureWindowDiagnostic?
    var lastPreflightRefusalGeometry: GuidanceFixtureWindowDiagnostic?
    var preflightAttempts = 0
    var preflightRefusals: [String] = []
    private var lastContentTime: Double?

    func receive(_ event: GuidanceObservationEvent) {
      guard events.count < 256 else {
        overflow = true
        return
      }
      guard event.timestamp.isFinite, event.timestamp >= 0,
        events.last.map({ event.sequence > $0.sequence }) ?? true
      else {
        overflow = true
        return
      }
      events.append(
        .init(reason: event.reason, timestamp: event.timestamp, sequence: event.sequence))
    }

    func sample(_ frame: GuidanceObservationFrame) throws {
      guard frame.contentTime != lastContentTime else { return }
      guard frames.count < 256, frame.width > 0, frame.width <= 256,
        frame.height > 0, frame.height <= 160, frame.pixels.count == frame.width * frame.height * 4,
        frame.pixels.count <= GuidanceObservationFrame.maximumBytes,
        frame.contentTime.isFinite, frame.receivedAt.isFinite,
        frame.contentTime >= 0, frame.receivedAt >= frame.contentTime,
        frame.receivedAt <= ProcessInfo.processInfo.systemUptime,
        frame.receivedAt - frame.contentTime <= 2,
        lastContentTime.map({ frame.contentTime > $0 }) ?? true
      else { throw Refusal("native-frame-clock-dimensions-or-budget-invalid") }
      frames.append(
        .init(
          width: frame.width, height: frame.height, copiedBytes: frame.pixels.count,
          contentTime: frame.contentTime, receivedAt: frame.receivedAt,
          contentToReceiveMS: (frame.receivedAt - frame.contentTime) * 1_000))
      lastContentTime = frame.contentTime
    }
  }

  private struct Ready: Codable {
    let phase: String
    let sourceRevision: String
    let observationWindowSeconds: Int
    let displayID: UInt32
    let sourceRect: CGRect
    let nativeStreamStarted: Bool
    let automaticDesktopInput: Bool
    let providerUsed: Bool
    let audioUsed: Bool
  }
  private struct Receipt: Codable {
    let result: String
    let phase: String
    let failureCode: String?
    let sourceRevision: String
    let sourceBundleID: String
    let elapsedMS: Double
    let fixturePreflightPassed: Bool
    let streamStarted: Bool
    let scopeGeneration: UInt64?
    let scopeDisplayID: UInt32?
    let scopeRect: CGRect?
    let frames: [Frame]
    let events: [Event]
    let windowGeometry: GuidanceFixtureWindowDiagnostic?
    let lastPreflightRefusalGeometry: GuidanceFixtureWindowDiagnostic?
    let preflightAttempts: Int
    let preflightRefusalCodes: [String]
    let eventBudgetExceeded: Bool
    let diagnosticsBeforeStop: GuidanceObservationDiagnostics?
    let diagnosticsStopped: GuidanceObservationDiagnostics?
    let diagnosticsAfterStopWait: GuidanceObservationDiagnostics?
    let stopQuiescentFor500MS: Bool
    let axStatus: String
    let axMetadataEventCount: Int
    let accessibilityTrusted: Bool
    let actualNativeObservation: Bool
    let localSampledScreenPixels: Bool
    let modelEvidenceCapture: Bool
    let screenshotsSaved: Bool
    let automaticDesktopInput: Bool
    let appActivationRequested: Bool
    let providerUsed: Bool
    let microphoneUsed: Bool
    let audioUsed: Bool
    let fullHostWorkflowExercised: Bool
    let physicalInputVerified: Bool
  }

  private static func write<T: Encodable>(_ value: T, to url: URL) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(value)
    guard data.count <= 256 * 1_024 else { throw Refusal("receipt-byte-budget-exceeded") }
    let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode_t(0o600))
    guard descriptor >= 0 else { throw Refusal("exclusive-private-output-unavailable") }
    let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    defer { try? file.close() }
    try file.write(contentsOf: data)
  }
}

/// Acceptance-only geometry metadata. It never reads names, titles, AX values,
/// screenshots, or another application's PID into the saved diagnostic.
struct GuidanceFixtureWindowDiagnostic: Codable, Sendable {
  struct Window: Codable, Sendable {
    let orderIndex: Int
    let fixtureWindowID: UInt32?
    let ownerIsFixture: Bool
    let ownerIsCurrentProcess: Bool
    let alpha: Double?
    let bounds: [Double]?
    let intersectsExpectedDisplay: Bool?
    let coversExpectedDisplay: Bool?
  }

  let sampledAtUptime: Double?
  let sameGuardWindowList: Bool
  let expectedDisplayID: UInt32
  let expectedScreenRect: [Double]?
  let actualScreenRect: [Double]?
  let expectedQuartzDisplayRect: [Double]?
  let primaryScreenTop: Double?
  let pointerInsideExpectedDisplay: Bool
  let foregroundIsExpectedFixture: Bool
  let listedWindowCount: Int?
  let windowListOverBudget: Bool
  let malformedLayerZeroCount: Int
  let fixtureLayerZeroWindowCount: Int
  let opaqueCoveringFixtureWindowCount: Int
  let fixtureWindows: [Window]
  let firstIntersectingNonOwnLayerZero: Window?

  @MainActor static func capture(
    expectedPID: pid_t, displayID: CGDirectDisplayID, screenRect: CGRect,
    guardWindows: [[String: Any]]? = nil
  ) -> Self {
    let primaryTop = NSScreen.screens.first?.frame.maxY
    let quartz = primaryTop.map {
      CGRect(
        x: screenRect.minX, y: $0 - screenRect.maxY,
        width: screenRect.size.width, height: screenRect.size.height)
    }
    let actual = NSScreen.screens.first {
      ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
        == displayID
    }?.frame
    let windows: [[String: Any]]?
    let count: Int?
    let overBudget: Bool
    if let guardWindows {
      count = min(guardWindows.count, 4_097)
      overBudget = guardWindows.count > 4_096
      windows = overBudget ? nil : guardWindows
    } else if let raw = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) {
      let rawCount = CFArrayGetCount(raw)
      count = min(rawCount, 4_097)
      overBudget = rawCount > 4_096
      windows = overBudget ? nil : raw as? [[String: Any]]
    } else {
      count = nil
      overBudget = false
      windows = nil
    }
    let ownPID = ProcessInfo.processInfo.processIdentifier
    var fixtureWindows: [Window] = []
    var fixtureCount = 0
    var coveringCount = 0
    var malformed = 0
    var first: Window?
    for (index, raw) in (windows ?? []).enumerated() {
      guard (raw[kCGWindowLayer as String] as? NSNumber)?.intValue == 0 else { continue }
      let pid = (raw[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value
      let rawAlpha = (raw[kCGWindowAlpha as String] as? NSNumber)?.doubleValue
      let alpha = rawAlpha.flatMap { $0.isFinite && (0...1).contains($0) ? $0 : nil }
      let rect = (raw[kCGWindowBounds as String] as? [String: Any]).flatMap {
        CGRect(dictionaryRepresentation: $0 as CFDictionary)
      }
      let bounds = rect.flatMap(validRect)
      if (pid ?? 0) <= 0 || alpha == nil || bounds == nil { malformed += 1 }
      let intersection = rect.flatMap { rect -> Bool? in
        guard bounds != nil, let quartz, validRect(quartz) != nil else { return nil }
        return rect.intersects(quartz)
      }
      let covers = rect.flatMap { rect -> Bool? in
        guard bounds != nil, let quartz, validRect(quartz) != nil else { return nil }
        return rect.contains(quartz)
      }
      let item = Window(
        orderIndex: index,
        fixtureWindowID: pid == expectedPID
          ? (raw[kCGWindowNumber as String] as? NSNumber)?.uint32Value : nil,
        ownerIsFixture: pid == expectedPID, ownerIsCurrentProcess: pid == ownPID,
        alpha: alpha, bounds: bounds, intersectsExpectedDisplay: intersection,
        coversExpectedDisplay: covers)
      if pid == expectedPID {
        fixtureCount += 1
        if alpha == 1 && covers == true { coveringCount += 1 }
        if fixtureWindows.count < 8 { fixtureWindows.append(item) }
      }
      if first == nil, let pid, pid > 0, pid != ownPID,
        let alpha, alpha > 0, intersection == true
      {
        first = item
      }
    }
    let uptime = ProcessInfo.processInfo.systemUptime
    return .init(
      sampledAtUptime: uptime.isFinite && uptime >= 0 ? uptime : nil,
      sameGuardWindowList: guardWindows != nil, expectedDisplayID: displayID,
      expectedScreenRect: validRect(screenRect), actualScreenRect: actual.flatMap(validRect),
      expectedQuartzDisplayRect: quartz.flatMap(validRect),
      primaryScreenTop: primaryTop.flatMap { $0.isFinite ? Double($0) : nil },
      pointerInsideExpectedDisplay: screenRect.contains(NSEvent.mouseLocation),
      foregroundIsExpectedFixture:
        NSWorkspace.shared.frontmostApplication?.processIdentifier == expectedPID,
      listedWindowCount: count, windowListOverBudget: overBudget,
      malformedLayerZeroCount: malformed, fixtureLayerZeroWindowCount: fixtureCount,
      opaqueCoveringFixtureWindowCount: coveringCount, fixtureWindows: fixtureWindows,
      firstIntersectingNonOwnLayerZero: first)
  }

  private static func validRect(_ rect: CGRect) -> [Double]? {
    guard GuidanceObservationScope.valid(rect) else { return nil }
    return [
      Double(rect.origin.x), Double(rect.origin.y),
      Double(rect.size.width), Double(rect.size.height),
    ]
  }

  static func failureCode(_ error: GuidanceFixtureStateAcceptance.Failure) -> String {
    switch error {
    case .accessibilityDenied: "accessibilityDenied"
    case .fixtureAbsent: "fixtureAbsent"
    case .fixtureDisappeared: "fixtureDisappeared"
    case .staleIdentity: "staleIdentity"
    case .displayNotCovered: "displayNotCovered"
    case .focusedWindowAbsent: "focusedWindowAbsent"
    case .attributeUnavailable: "attributeUnavailable"
    case .traversalLimitExceeded: "traversalLimitExceeded"
    case .deadlineExceeded: "deadlineExceeded"
    case .missingControl(let control): "missingControl.\(control.rawValue)"
    case .duplicateControl(let control): "duplicateControl.\(control.rawValue)"
    case .invalidRole(let control): "invalidRole.\(control.rawValue)"
    case .hiddenControl(let control): "hiddenControl.\(control.rawValue)"
    case .invalidValue(let control): "invalidValue.\(control.rawValue)"
    case .axRequestFailed(let attribute, let code): "axRequestFailed.\(attribute.rawValue).\(code)"
    case .axCountFailed(let attribute, let code): "axCountFailed.\(attribute.rawValue).\(code)"
    case .axCopyFailed(let attribute, let code): "axCopyFailed.\(attribute.rawValue).\(code)"
    case .attributeMissing(let attribute): "attributeMissing.\(attribute.rawValue)"
    case .attributeTypeInvalid(let attribute): "attributeTypeInvalid.\(attribute.rawValue)"
    case .attributeSizeInvalid(let attribute): "attributeSizeInvalid.\(attribute.rawValue)"
    }
  }
}
