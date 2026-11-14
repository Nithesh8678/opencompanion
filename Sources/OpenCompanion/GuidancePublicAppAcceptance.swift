import AppKit
@preconcurrency import ApplicationServices
import CoreText
import Foundation

/// Public, externally driven native task checks. This helper never launches or
/// activates an app, posts input, changes a permission, or saves audio/screenshots.
enum GuidancePublicAppAcceptance {
  private enum Scenario: String, Sendable {
    case browser, textedit, calculator
    var bundleID: String {
      switch self {
      case .browser: "com.apple.Safari"
      case .textedit: "com.apple.TextEdit"
      case .calculator: "com.apple.calculator"
      }
    }
    var prompt: String {
      switch self {
      case .browser:
        "Help me name this public project Release QA, turn off Protect data, and save it. Guide the next visible control, and verify the actual page before claiming it is saved."
      case .textedit:
        "Help me select the public sentence in this document, make it bold, and center its paragraph. Guide one visible next step and verify the actual formatting before claiming completion."
      case .calculator:
        "Help me enter 16, find its square root, then clear the result. Guide each visible next control and verify the displayed result after each step."
      }
    }
  }

  private struct Environment: Sendable {
    let pid: pid_t
    let windowID: CGWindowID
    let windowRect: CGRect
    let displayID: CGDirectDisplayID
    let screenRect: CGRect
    let primaryTop: CGFloat
  }

  private struct State: Codable, Sendable, Equatable {
    let observedAt: TimeInterval
    var publicIdentity = false
    var nameEmpty = false
    var nameMatches = false
    var protectionOn: Bool?
    var savedMessage = false
    var publicPhrase = false
    var selectedPhrase = false
    var bold: Bool?
    var centered: Bool?
    var display: String?
    var factKey: String {
      "\(publicIdentity)|\(nameEmpty)|\(nameMatches)|\(String(describing: protectionOn))|\(savedMessage)|\(publicPhrase)|\(selectedPhrase)|\(String(describing: bold))|\(String(describing: centered))|\(display ?? "unknown")"
    }
  }

  private struct Stage: Codable {
    let ordinal: Int
    let generation: UInt64
    let requestStep: Int
    let frameID: UUID
    let evidenceRevision: UInt64
    let capturedAt: TimeInterval
    let observedAt: TimeInterval
    let x: Double
    let y: Double
    let width: Double
    let height: Double
    let advanceOn: String?
    let shape: String?
  }

  private struct Preparation: Codable {
    let generation: UInt64
    let state: State
    let postconditionSatisfied: Bool
  }

  private struct Refusal: Error {
    let code: String
    init(_ code: String) { self.code = code }
  }

  @MainActor static func run(
    model: AppModel, cursor: CursorCompanionCoordinator, output: URL, scenario name: String
  ) async throws {
    let began = ProcessInfo.processInfo.systemUptime
    var failure = "incomplete"
    var passed = false
    var nativePathStarted = false
    var stages: [Stage] = []
    var preparations: [Preparation] = []
    var observedFrames = Set<UUID>()
    var initial: State?
    var latest: State?
    var finalPreparation: Preparation?
    var sawSixteen = false
    var sawFourAfterSixteen = false
    var sawZeroAfterFour = false
    var targetRefusal: String?
    var stateChanges = 0
    var ownedRuntimeID: UUID?
    var ownedWorkflowID: UUID?
    let priorPrepare = model.onPrepareScreenGuidance
    let priorTarget = model.onScreenGuidanceTargetAccepted
    let priorRefreshScope = model.validateGuidanceRefreshScope
    var selectedSeed: ScreenEvidenceIdentity?
    var selectedWindowRect: CGRect?
    var selectedWindowID: CGWindowID?
    var selectedPID: pid_t?
    var captureAttempted = false
    let initialScene = model.scene
    let traceStart = model.diagnosticEvents.count
    let terminalURL = output.appendingPathComponent("guidance-public-app-acceptance.json")
    var restored = false
    var ownsModel = false
    var mayWrite = false
    @MainActor func restore() {
      guard !restored else { return }
      restored = true
      guard ownsModel else { return }
      model.onPrepareScreenGuidance = priorPrepare
      model.onScreenGuidanceTargetAccepted = priorTarget
      model.validateGuidanceRefreshScope = priorRefreshScope
      model.setGuidanceModeArmed(false)
      cursor.shutdown()
    }
    defer {
      let providerIdleBeforeCleanup = !model.busy
      let foregroundPreserved =
        selectedPID.map {
          NSWorkspace.shared.frontmostApplication?.processIdentifier == $0
        } ?? false
      restore()
      let events = Array(model.diagnosticEvents.dropFirst(traceStart))
      let counts = Dictionary(grouping: events.compactMap { $0["event"] }, by: { $0 })
        .mapValues(\.count)
      let data: [String: Any] = [
        "result": passed ? "passed" : "failed", "failureCode": passed ? "" : failure,
        "productionError": String((model.error ?? "").prefix(1_000)),
        "accessibilityTrusted": AXIsProcessTrusted(),
        "screenRecordingGranted": CGPreflightScreenCaptureAccess(),
        "scenario": String(name.prefix(32)),
        "sourceRevision": String(
          (Bundle.main.object(forInfoDictionaryKey: "OpenCompanionSourceRevision") as? String
            ?? "unknown").prefix(128)),
        "elapsedMS": (ProcessInfo.processInfo.systemUptime - began) * 1_000,
        "actualArmedAppModelPath": nativePathStarted,
        "captureAttempted": captureAttempted,
        "captureScope": "exact-selected-public-window",
        "fullDisplayCapture": false, "backdropRequired": false,
        "selectedWindowID": selectedWindowID as Any? ?? NSNull(),
        "foregroundPreservedBeforeCleanup": foregroundPreserved,
        "selectedWindowRect": selectedWindowRect.map(json) ?? NSNull(),
        "initialSelectedFrameID": selectedSeed?.frameID.uuidString as Any? ?? NSNull(),
        "providerApplicationAXEnrichmentOmitted": selectedSeed != nil,
        "providerEvidence":
          "Selected-window image and window-scoped OCR; application-wide AX enrichment is omitted. Independent public AX reads verify postconditions only.",
        "groundedStages": json(stages), "preCaptureStates": json(preparations),
        "initialState": initial.map(json) ?? NSNull(), "finalState": latest.map(json) ?? NSNull(),
        "finalCapturePreparation": finalPreparation.map(json) ?? NSNull(),
        "distinctObservedCaptureFrameCount": observedFrames.count,
        "productionEventCounts": counts, "productionEventCountsAreBoundedRecentTrace": true,
        "workflowCheckCount": model.guidanceSession.workflow?.checks.count ?? 0,
        "providerIdleBeforeCleanup": providerIdleBeforeCleanup,
        "independentPostconditionVerified": passed,
        "calculatorObserved16Then4Then0": sawSixteen && sawFourAfterSixteen && sawZeroAfterFour,
        "notebookUnchanged": model.scene == initialScene,
        "helperPostedInput": false, "helperActivatedApp": false,
        "microphoneUsed": false, "audioUsed": false, "screenshotsSaved": false,
        "physicalInputVerified": false,
        "inputSource":
          "External driver; this helper never generates or authenticates physical input",
        "scope":
          "Actual public-window capture, armed host reasoning, native grounded-target submission and independent public AX state. No latency distribution, arbitrary-app reliability or reference parity claim.",
      ]
      if mayWrite { try? write(data, to: terminalURL) }
      try? marker("GUIDANCE_PUBLIC_APP_TERMINAL_\(passed ? "PASSED" : "FAILED")")
    }
    do {
      try Task.checkCancellation()
      guard let scenario = Scenario(rawValue: name.lowercased()) else {
        throw Refusal("unknown-scenario")
      }
      guard output.isFileURL else { throw Refusal("output-not-local") }
      try FileManager.default.createDirectory(
        at: output, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
      guard !FileManager.default.fileExists(atPath: terminalURL.path) else {
        throw Refusal("output-already-exists")
      }
      mayWrite = true
      guard !model.busy, !model.listening, !model.voice.hasPendingSpeech,
        model.input.isEmpty, model.messages.isEmpty, model.selectedContext.isEmpty,
        !model.guidanceHasSelectedScope, model.scene == nil
      else { throw Refusal("model-not-fresh") }
      guard CGPreflightScreenCaptureAccess(), AXIsProcessTrusted() else {
        throw Refusal("existing-permission-unavailable")
      }
      let foregroundDeadline = min(began + 150, ProcessInfo.processInfo.systemUptime + 45)
      try write(
        [
          "phase": "waiting-for-public-app", "scenario": scenario.rawValue,
          "captureAttempted": false, "providerUsed": false,
        ],
        to: output.appendingPathComponent("public-app-progress.json"))
      while NSWorkspace.shared.frontmostApplication?.bundleIdentifier != scenario.bundleID {
        try Task.checkCancellation()
        guard ProcessInfo.processInfo.systemUptime < foregroundDeadline else {
          throw Refusal("public-app-foreground-timeout")
        }
        try await Task.sleep(for: .milliseconds(100))
      }
      let environment = try environment(scenario: scenario)
      let first = try await readState(environment, scenario: scenario)
      try Task.checkCancellation()
      try verify(environment, scenario: scenario)
      guard first.publicIdentity else { throw Refusal("public-app-identity-unverified") }
      switch scenario {
      case .browser:
        guard first.nameEmpty, first.protectionOn == true, !first.savedMessage else {
          throw Refusal("browser-initial-state-invalid")
        }
      case .textedit:
        guard first.publicPhrase,
          !(first.selectedPhrase && first.bold == true && first.centered == true)
        else {
          throw Refusal("textedit-initial-state-invalid")
        }
      case .calculator:
        guard first.display == "zero" else {
          throw Refusal("calculator-initial-display-unverified")
        }
      }
      initial = first
      latest = first
      @MainActor func consume(_ state: State) {
        if scenario == .calculator {
          if state.display == "sixteen" { sawSixteen = true }
          if sawSixteen && state.display == "four" { sawFourAfterSixteen = true }
          if sawFourAfterSixteen && state.display == "zero" { sawZeroAfterFour = true }
        }
      }
      @MainActor func complete(_ state: State) -> Bool {
        guard state.publicIdentity else { return false }
        switch scenario {
        case .browser: return state.nameMatches && state.protectionOn == false && state.savedMessage
        case .textedit:
          return state.publicPhrase && state.selectedPhrase && state.bold == true
            && state.centered == true
        case .calculator:
          return sawSixteen && sawFourAfterSixteen && sawZeroAfterFour && state.display == "zero"
        }
      }
      @MainActor func ownsRuntime() -> Bool {
        guard let ownedRuntimeID, let ownedWorkflowID,
          model.guidanceSession.workflow?.id == ownedWorkflowID
        else { return false }
        return model.guidanceRuntime.id == ownedRuntimeID
          || (model.guidanceRuntime.id == nil
            && model.guidanceSession.workflow?.phase == .modelReportedComplete)
      }
      ownsModel = true
      selectedWindowRect = environment.windowRect
      selectedWindowID = environment.windowID
      selectedPID = environment.pid
      try verify(environment, scenario: scenario)
      let selectionToken = model.capturePublicationRevision
      let selectionGeneration = model.taskGeneration
      let screens = Dictionary(
        uniqueKeysWithValues: NSScreen.screens.compactMap {
          screen -> (CGDirectDisplayID, CGRect)? in
          guard
            let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
              as? NSNumber
          else { return nil }
          return (number.uint32Value, screen.frame)
        })
      captureAttempted = true
      let seed = try await model.capture.capture(
        displayID: environment.displayID, foregroundPID: environment.pid,
        foregroundName: "Public " + scenario.rawValue,
        windowID: environment.windowID, screens: screens)
      try Task.checkCancellation()
      try verify(environment, scenario: scenario)
      guard model.taskGeneration == selectionGeneration,
        model.capturePublicationRevision == selectionToken,
        matchesSelectedWindow(seed, environment: environment)
      else {
        throw Refusal("initial-selected-window-capture-changed")
      }
      let confirmedInitial = try await readState(environment, scenario: scenario)
      try Task.checkCancellation()
      try verify(environment, scenario: scenario)
      guard confirmedInitial.publicIdentity, confirmedInitial.factKey == first.factKey,
        model.taskGeneration == selectionGeneration,
        model.capturePublicationRevision == selectionToken,
        model.publishSelectedCapture(seed, token: selectionToken)
      else {
        throw Refusal("initial-selected-window-publication-refused")
      }
      selectedSeed = ScreenEvidenceIdentity(seed)
      model.validateGuidanceRefreshScope = { frame in
        do {
          try verify(environment, scenario: scenario)
          guard ownsRuntime(), matchesSelectedWindow(frame, environment: environment),
            priorRefreshScope?(frame) ?? true
          else { return false }
          return true
        } catch { return false }
      }
      model.onPrepareScreenGuidance = { generation, expectedPID in
        guard ownsRuntime(), expectedPID == environment.pid, preparations.count < 46 else {
          throw Refusal("capture-source-or-budget-changed")
        }
        try verify(environment, scenario: scenario)
        if let priorPrepare { try await priorPrepare(generation, expectedPID) }
        let state = try await readState(environment, scenario: scenario)
        try Task.checkCancellation()
        try verify(environment, scenario: scenario)
        guard state.publicIdentity, model.taskGeneration == generation else {
          throw Refusal("capture-public-identity-changed")
        }
        consume(state)
        preparations.append(
          .init(
            generation: generation, state: state, postconditionSatisfied: complete(state)))
      }
      model.onScreenGuidanceTargetAccepted = { target, evidence, generation, request in
        do {
          try verify(environment, scenario: scenario)
          guard ownsRuntime(), stages.count < 64, generation == model.taskGeneration,
            matchesSelectedWindow(evidence, environment: environment),
            evidence.frameID != selectedSeed?.frameID,
            ScreenEvidenceIdentity(evidence).matches(model.evidence),
            ScreenGuidancePolicy.targetRect(target, in: evidence.screenRect) != nil
          else {
            throw Refusal("target-source-or-geometry-invalid")
          }
          let size = try ScreenImageGeometry.trustedEncodedPixelSize(evidence.image)
          guard evidence.imageWidth == Int(size.width), evidence.imageHeight == Int(size.height)
          else { throw Refusal("capture-header-invalid") }
          observedFrames.insert(evidence.frameID)
          let stage = Stage(
            ordinal: stages.count, generation: generation, requestStep: request.step,
            frameID: evidence.frameID, evidenceRevision: evidence.revision,
            capturedAt: evidence.capturedAt, observedAt: ProcessInfo.processInfo.systemUptime,
            x: target.x, y: target.y, width: target.width, height: target.height,
            advanceOn: target.advanceOn, shape: target.shape)
          stages.append(stage)
          priorTarget?(target, evidence, generation, request)
          try write(
            [
              "scenario": scenario.rawValue, "stage": json(stage), "helperPostedInput": false,
            ], to: output.appendingPathComponent("target-ready.json"))
          try marker("GUIDANCE_PUBLIC_TARGET_\(stage.ordinal)_READY")
        } catch {
          targetRefusal = (error as? Refusal)?.code ?? "target-validation-failed"
          model.stop()
        }
      }
      try write(
        [
          "scenario": scenario.rawValue, "initialState": json(first),
          "publicForegroundPID": environment.pid, "publicWindowID": environment.windowID,
          "captureScope": "exact-selected-public-window", "backdropRequired": false,
          "selectedWindowRect": json(environment.windowRect),
          "displayID": environment.displayID, "deadlineSeconds": 150,
          "helperPostedInput": false, "helperActivatedApp": false,
        ], to: output.appendingPathComponent("public-app-ready.json"))
      model.providerMode = "ChatGPT via Codex"
      model.configuration.speechEnabled = false
      model.setGuidanceModeArmed(true)
      model.input = scenario.prompt
      model.send()
      ownedRuntimeID = model.guidanceRuntime.id
      ownedWorkflowID = model.guidanceSession.workflow?.id
      guard ownedRuntimeID != nil, ownedWorkflowID != nil else {
        throw Refusal("active-host-session-not-created")
      }
      nativePathStarted = true
      try marker("GUIDANCE_PUBLIC_APP_READY")
      let deadline = began + 150
      while ProcessInfo.processInfo.systemUptime < deadline {
        try Task.checkCancellation()
        if let targetRefusal { throw Refusal(targetRefusal) }
        guard ownsRuntime() else { throw Refusal("active-host-session-changed") }
        guard model.error == nil else { throw Refusal("model-or-host-failed") }
        try verify(environment, scenario: scenario)
        let state = try await readState(environment, scenario: scenario)
        try Task.checkCancellation()
        try verify(environment, scenario: scenario)
        guard ownsRuntime(), state.publicIdentity else {
          throw Refusal("public-app-identity-changed")
        }
        consume(state)
        if latest?.factKey != state.factKey {
          stateChanges += 1
          guard stateChanges <= 64 else { throw Refusal("public-state-budget-exceeded") }
          try write(
            [
              "state": json(state), "calculatorSaw16": sawSixteen,
              "calculatorSaw4After16": sawFourAfterSixteen,
              "calculatorSaw0After4": sawZeroAfterFour,
            ], to: output.appendingPathComponent("public-app-progress.json"))
        }
        latest = state
        if let frame = model.evidence, matchesSelectedWindow(frame, environment: environment),
          frame.frameID != selectedSeed?.frameID
        {
          observedFrames.insert(frame.frameID)
        }
        if complete(state), let preparation = preparations.last,
          preparation.postconditionSatisfied, let frame = model.evidence,
          preparation.generation == model.taskGeneration,
          frame.capturedAt >= preparation.state.observedAt,
          matchesSelectedWindow(frame, environment: environment),
          frame.frameID != selectedSeed?.frameID,
          stages.count >= 3, observedFrames.count >= 3,
          model.scene == initialScene
        {
          finalPreparation = preparation
          // A second independent read brackets the same already-accepted final
          // evidence. Model-complete prose alone can never satisfy this gate.
          let confirmation = try await readState(environment, scenario: scenario)
          try Task.checkCancellation()
          try verify(environment, scenario: scenario)
          guard ownsRuntime(), model.taskGeneration == preparation.generation,
            ScreenEvidenceIdentity(frame).matches(model.evidence), model.scene == initialScene,
            complete(confirmation), model.error == nil
          else {
            throw Refusal("postcondition-did-not-persist")
          }
          latest = confirmation
          passed = true
          failure = ""
          return
        }
        try await Task.sleep(for: .milliseconds(250))
      }
      if scenario == .textedit, latest?.bold == nil || latest?.centered == nil {
        throw Refusal("textedit-style-unverified")
      }
      throw Refusal("public-task-deadline-exceeded")
    } catch {
      failure =
        (error as? Refusal)?.code
        ?? (error is CancellationError ? "cancelled" : "public-check-failed")
      throw ProviderError.message("Public guidance acceptance: \(failure).")
    }
  }

  @MainActor private static func environment(scenario: Scenario) throws -> Environment {
    guard let app = NSWorkspace.shared.frontmostApplication,
      app.bundleIdentifier == scenario.bundleID,
      let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }),
      let display =
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?
        .uint32Value,
      let primaryTop = NSScreen.screens.first?.frame.maxY
    else {
      throw Refusal("public-app-not-front")
    }
    let windows = try windowStack(screen: screen.frame, primaryTop: primaryTop)
    guard let front = windows.first, front.pid == app.processIdentifier, front.alpha == 1,
      screen.frame.contains(front.rect)
    else {
      throw Refusal("focused-public-window-unverified")
    }
    return .init(
      pid: app.processIdentifier, windowID: front.id, windowRect: front.rect,
      displayID: display, screenRect: screen.frame, primaryTop: primaryTop)
  }

  @MainActor private static func verify(_ expected: Environment, scenario: Scenario) throws {
    let current = try environment(scenario: scenario)
    guard current.pid == expected.pid, current.windowID == expected.windowID,
      current.windowRect == expected.windowRect, current.displayID == expected.displayID,
      current.screenRect == expected.screenRect
    else { throw Refusal("public-window-scope-changed") }
  }

  private static func matchesSelectedWindow(_ frame: ScreenEvidence, environment: Environment)
    -> Bool
  {
    frame.foregroundPID == environment.pid && frame.displayID == environment.displayID
      && frame.windowID == environment.windowID && frame.screenRect == environment.windowRect
      && frame.capturedWindowBounds == environment.windowRect
      && frame.groundingCandidates.allSatisfy { $0.source != .accessibility }
  }

  private struct PublicWindow {
    let id: CGWindowID
    let pid: pid_t
    let rect: CGRect
    let alpha: Double
  }
  @MainActor private static func windowStack(screen: CGRect, primaryTop: CGFloat) throws
    -> [PublicWindow]
  {
    guard
      let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID)
        as? [[String: Any]],
      windows.count <= 4_096
    else { throw Refusal("window-stack-unavailable") }
    return try windows.compactMap { info in
      guard let layer = (info[kCGWindowLayer as String] as? NSNumber)?.intValue else {
        throw Refusal("window-stack-entry-unverified")
      }
      guard layer == 0 else { return nil }
      guard let pid = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value else {
        throw Refusal("window-stack-owner-unverified")
      }
      guard pid != ProcessInfo.processInfo.processIdentifier else { return nil }
      guard let id = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
        let alpha = (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue,
        alpha.isFinite, (0...1).contains(alpha),
        let raw = info[kCGWindowBounds as String] as? [String: Any],
        let quartz = CGRect(dictionaryRepresentation: raw as CFDictionary)
      else {
        throw Refusal("window-stack-geometry-unverified")
      }
      guard alpha > 0 else { return nil }
      let rect = CGRect(
        x: quartz.minX, y: primaryTop - quartz.maxY,
        width: quartz.size.width, height: quartz.size.height)
      guard GuidanceObservationScope.valid(rect) else {
        throw Refusal("window-stack-geometry-unverified")
      }
      guard rect.intersects(screen) else { return nil }
      return PublicWindow(id: id, pid: pid, rect: rect, alpha: alpha)
    }
  }

  private static func readState(_ environment: Environment, scenario: Scenario) async throws
    -> State
  {
    try await Task.detached(priority: .userInitiated) {
      try PublicAX.read(environment, scenario: scenario)
    }.value
  }

  private enum PublicAX {
    static let phrase = "Guidance can be clear and calm."
    static func read(_ environment: Environment, scenario: Scenario) throws -> State {
      let deadline = ProcessInfo.processInfo.systemUptime + 1.5
      var reads = 0
      func value(_ element: AXUIElement, _ attribute: CFString) -> CFTypeRef? {
        guard reads < 8_192, ProcessInfo.processInfo.systemUptime < deadline else { return nil }
        reads += 1
        AXUIElementSetMessagingTimeout(element, 0.03)
        var result: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, attribute, &result) == .success ? result : nil
      }
      func string(_ element: AXUIElement, _ attribute: CFString, limit: Int = 2_048) -> String? {
        guard let text = value(element, attribute) as? String, text.utf8.count <= limit else {
          return nil
        }
        return text
      }
      let app = AXUIElementCreateApplication(environment.pid)
      guard let raw = value(app, kAXFocusedWindowAttribute as CFString),
        CFGetTypeID(raw) == AXUIElementGetTypeID()
      else {
        throw Refusal("focused-public-window-unavailable")
      }
      let window = raw as! AXUIElement
      guard let rawPosition = value(window, kAXPositionAttribute as CFString),
        let rawSize = value(window, kAXSizeAttribute as CFString),
        CFGetTypeID(rawPosition) == AXValueGetTypeID(), CFGetTypeID(rawSize) == AXValueGetTypeID()
      else { throw Refusal("public-ax-window-geometry-unavailable") }
      let positionValue = rawPosition as! AXValue
      let sizeValue = rawSize as! AXValue
      var point = CGPoint.zero
      var size = CGSize.zero
      guard AXValueGetType(positionValue) == .cgPoint, AXValueGetType(sizeValue) == .cgSize,
        AXValueGetValue(positionValue, .cgPoint, &point), AXValueGetValue(sizeValue, .cgSize, &size)
      else { throw Refusal("public-ax-window-geometry-unavailable") }
      let actualRect = CGRect(
        x: point.x, y: environment.primaryTop - point.y - size.height,
        width: size.width, height: size.height)
      guard GuidanceObservationScope.valid(actualRect),
        abs(actualRect.minX - environment.windowRect.minX) <= 1,
        abs(actualRect.minY - environment.windowRect.minY) <= 1,
        abs(actualRect.size.width - environment.windowRect.size.width) <= 1,
        abs(actualRect.size.height - environment.windowRect.size.height) <= 1
      else { throw Refusal("public-ax-window-identity-mismatch") }
      var state = State(observedAt: ProcessInfo.processInfo.systemUptime)
      let title = string(window, kAXTitleAttribute as CFString)
      if scenario == .browser, title != "OpenCompanion Public Guide" {
        throw Refusal("browser-public-title-mismatch")
      }
      if scenario == .textedit {
        let document = string(window, kAXDocumentAttribute as CFString, limit: 8_192)
        guard let document, let url = URL(string: document), url.isFileURL,
          url.lastPathComponent == "OpenCompanion Public Guide.rtf"
        else { throw Refusal("textedit-public-document-mismatch") }
      }
      var queue: [(AXUIElement, Bool, Bool)] = [(window, false, false)]
      var visited = Set<CFHashCode>()
      var webAreas = 0
      var names = 0
      var protections = 0
      var documents = 0
      var calculatorDisplays: [String] = []
      var calculatorInputContainers = 0
      var calculatorInputResults: [String] = []
      var boldControl: Bool?
      var centerControl: Bool?
      var index = 0
      while index < queue.count, index < 1_024, ProcessInfo.processInfo.systemUptime < deadline {
        let (element, insideWeb, insideCalculatorInput) = queue[index]
        index += 1
        guard visited.insert(CFHash(element)).inserted else { continue }
        guard (value(element, kAXHiddenAttribute as CFString) as? NSNumber)?.boolValue != true
        else { continue }
        let role = string(element, kAXRoleAttribute as CFString, limit: 128) ?? ""
        let subrole = string(element, kAXSubroleAttribute as CFString, limit: 128) ?? ""
        if role == "AXSecureTextField" || subrole == "AXSecureTextField" { continue }
        let isWeb = role == "AXWebArea"
        let inWeb = insideWeb || isWeb
        if isWeb {
          webAreas += 1
          let rawURL = value(element, kAXURLAttribute as CFString)
          let url = (rawURL as? URL) ?? (rawURL as? String).flatMap(URL.init(string:))
          guard let url, ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
            ["localhost", "127.0.0.1", "::1", "[::1]"].contains(url.host?.lowercased() ?? "")
          else {
            throw Refusal("browser-nonlocal-web-content")
          }
        }
        let label = ScreenGrounding.firstNonemptyLabel([
          string(element, kAXTitleAttribute as CFString),
          string(element, kAXDescriptionAttribute as CFString),
        ])
        let identifier = string(element, kAXIdentifierAttribute as CFString, limit: 256) ?? ""
        let isCalculatorInput =
          scenario == .calculator && role == "AXScrollArea"
          && ["StandardInputView", "ScientificInputView"].contains(identifier)
        if isCalculatorInput { calculatorInputContainers += 1 }
        let inCalculatorInput = insideCalculatorInput || isCalculatorInput
        if scenario == .browser, inWeb {
          if role == "AXTextField", label == "Project name" {
            names += 1
            let text = string(element, kAXValueAttribute as CFString)
            state.nameEmpty = text == ""
            state.nameMatches = text == "Release QA"
          }
          if role == "AXCheckBox", label == "Protect data" {
            protections += 1
            if let number = value(element, kAXValueAttribute as CFString) as? NSNumber,
              [0, 1].contains(number.intValue)
            {
              state.protectionOn = number.intValue == 1
            }
          }
          if role == "AXStaticText",
            label == "Saved public project"
              || string(element, kAXValueAttribute as CFString) == "Saved public project"
          {
            state.savedMessage = true
          }
        }
        if scenario == .textedit {
          let controlLabel = label.lowercased()
          let rawSelected =
            (value(element, kAXValueAttribute as CFString) as? NSNumber)
            ?? (value(element, kAXSelectedAttribute as CFString) as? NSNumber)
          let selected: Bool? = rawSelected.flatMap {
            [0, 1].contains($0.intValue) ? $0.intValue == 1 : nil
          }
          if ["AXButton", "AXCheckBox", "AXRadioButton"].contains(role) {
            if ["bold", "bold text"].contains(controlLabel) { boldControl = selected }
            if ["center", "align center", "center text"].contains(controlLabel) {
              centerControl = selected
            }
          }
          if role == "AXTextArea",
            let text = string(element, kAXValueAttribute as CFString, limit: 512),
            text.trimmingCharacters(in: .whitespacesAndNewlines) == phrase
          {
            documents += 1
            state.publicPhrase = true
            state.selectedPhrase =
              string(element, kAXSelectedTextAttribute as CFString, limit: 512) == phrase
            if state.selectedPhrase,
              let rawRange = value(element, kAXSelectedTextRangeAttribute as CFString),
              CFGetTypeID(rawRange) == AXValueGetTypeID()
            {
              let rangeValue = rawRange as! AXValue
              var range = CFRange(location: 0, length: 0)
              if AXValueGetType(rangeValue) == .cfRange,
                AXValueGetValue(rangeValue, .cfRange, &range),
                range.location >= 0, range.length == phrase.utf16.count,
                range.location <= 512 - range.length
              {
                var attributed: CFTypeRef?
                if AXUIElementCopyParameterizedAttributeValue(
                  element, kAXAttributedStringForRangeParameterizedAttribute as CFString, rawRange,
                  &attributed)
                  == .success,
                  let text = attributed as? NSAttributedString, text.string == phrase
                {
                  var allBold = true
                  var fonts = 0
                  var allCenter = true
                  var alignments = 0
                  text.enumerateAttributes(in: NSRange(location: 0, length: text.length)) {
                    attributes, _, _ in
                    if let font = attributes[
                      NSAttributedString.Key(kAXFontTextAttribute.takeUnretainedValue() as String)]
                      as? [String: Any],
                      let name = font[kAXFontNameKey.takeUnretainedValue() as String] as? String,
                      name.utf8.count <= 256
                    {
                      fonts += 1
                      let native = CTFontCreateWithName(name as CFString, 12, nil)
                      allBold = allBold && CTFontGetSymbolicTraits(native).contains(.traitBold)
                    } else {
                      allBold = false
                    }
                    if let alignment = attributes[.accessibilityAlignment]
                      as? NSNumber
                    {
                      alignments += 1
                      allCenter = allCenter && alignment.intValue == NSTextAlignment.center.rawValue
                    } else {
                      allCenter = false
                    }
                  }
                  if fonts > 0 { state.bold = allBold }
                  if alignments > 0 { state.centered = allCenter }
                }
              }
            }
          }
        }
        if scenario == .calculator {
          if inCalculatorInput, role == "AXStaticText" {
            // Exact shipped native input-container IDs identify this result;
            // keypad digits and historical rows outside it are never results.
            if let raw = string(element, kAXValueAttribute as CFString, limit: 128)
              ?? string(element, kAXTitleAttribute as CFString, limit: 128)
            {
              calculatorInputResults.append(calculatorDisplay(raw))
            }
          } else if !inCalculatorInput,
            ["AXTextField", "AXTextArea", "AXStaticText"].contains(role)
          {
            let known = [
              "display", "result", "calculator display", "calculator result", "resultdisplay",
            ]
            if known.contains(label.lowercased()) || known.contains(identifier.lowercased()) {
              let raw = string(element, kAXValueAttribute as CFString, limit: 128) ?? label
              calculatorDisplays.append(calculatorDisplay(raw))
            }
          }
        }
        var count: CFIndex = 0
        if AXUIElementGetAttributeValueCount(element, kAXChildrenAttribute as CFString, &count)
          == .success,
          count > 0
        {
          guard count <= 512, queue.count + count <= 1_024 else {
            throw Refusal("public-ax-tree-budget-exceeded")
          }
          var children: CFArray?
          if AXUIElementCopyAttributeValues(
            element, kAXChildrenAttribute as CFString, 0, count, &children)
            == .success,
            let children = children as? [AXUIElement]
          {
            queue.append(contentsOf: children.map { ($0, inWeb, inCalculatorInput) })
          }
        }
      }
      guard index == queue.count else { throw Refusal("public-ax-read-deadline") }
      switch scenario {
      case .browser: state.publicIdentity = webAreas == 1 && names == 1 && protections == 1
      case .textedit:
        state.publicIdentity = documents == 1
        if state.bold == nil { state.bold = boldControl }
        if state.centered == nil { state.centered = centerControl }
      case .calculator:
        if calculatorInputContainers == 1 {
          state.publicIdentity = calculatorInputResults.count == 1 && calculatorDisplays.isEmpty
          if state.publicIdentity { state.display = calculatorInputResults[0] }
        } else if calculatorInputContainers == 0 {
          state.publicIdentity = calculatorDisplays.count == 1
          if state.publicIdentity { state.display = calculatorDisplays[0] }
        }
      }
      return state
    }

    private static func calculatorDisplay(_ raw: String) -> String {
      let text = raw.unicodeScalars.reduce(into: "") { result, scalar in
        if !scalar.properties.isWhitespace && scalar.properties.generalCategory != .format {
          result.unicodeScalars.append(scalar)
        }
      }
      switch text {
      case "0": return "zero"
      case "16": return "sixteen"
      case "4": return "four"
      default: return "other"
      }
    }
  }

  private static func json<T: Encodable>(_ value: T) -> Any {
    guard let data = try? JSONEncoder().encode(value),
      let result = try? JSONSerialization.jsonObject(with: data)
    else { return NSNull() }
    return result
  }
  private static func write(_ value: [String: Any], to url: URL) throws {
    try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
      .write(to: url, options: .atomic)
  }
  private static func marker(_ value: String) throws {
    try FileHandle.standardOutput.write(contentsOf: Data((value + "\n").utf8))
  }
}
