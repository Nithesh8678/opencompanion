import AppKit
import CompanionCore
import ImageIO

/// Explicit public-fixture integration check. It observes the real capture,
/// provider, active-screen observer and native marks; it never drives input.
@MainActor enum ActiveGuidanceWorkflowAcceptance {
  static func run(
    model: AppModel, cursor: CursorCompanionCoordinator, output: URL
  ) async throws {
    try await Session(model: model, cursor: cursor, output: output).run()
  }

  @MainActor private final class Session {
    private let model: AppModel
    private let cursor: CursorCompanionCoordinator
    private let output: URL
    private let started = ProcessInfo.processInfo.systemUptime
    private var phase = "preflight"
    private var failure = "incomplete"
    private var passed = false
    private var fixture: NSRunningApplication?
    private var launchedAt: Date?
    private var screen: NSScreen?
    private var displayID: CGDirectDisplayID = 0
    private var traceStart = 0
    private var workflowID: UUID?
    private var sessionID: UUID?
    private var preparations:
      [(
        generation: UInt64, time: TimeInterval,
        state: GuidanceFixtureStateAcceptance.Snapshot?
      )] = []
    private var targets: [[String: Any]] = []
    private var targetFrames: [ScreenEvidence] = []
    private var frames: [[String: Any]] = []
    private var initialForm: GuidanceFixtureStateAcceptance.Snapshot?
    private var finalBefore: GuidanceFixtureStateAcceptance.Snapshot?
    private var finalAfter: GuidanceFixtureStateAcceptance.Snapshot?
    private var callbackFailure: String?

    init(model: AppModel, cursor: CursorCompanionCoordinator, output: URL) {
      self.model = model
      self.cursor = cursor
      self.output = output
    }

    func run() async throws {
      let originalScene = model.scene
      let oldPreparation = model.onPrepareScreenGuidance
      let oldTarget = model.onScreenGuidanceTargetAccepted
      let oldRefreshValidation = model.validateGuidanceRefreshScope
      let oldProvider = model.providerMode
      let oldSpeech = model.configuration.speechEnabled
      let oldPreference = model.guidanceModelPreference
      let oldDisplay = model.selectedDisplay
      defer {
        let terminalPhase = phase
        if !passed && failure == "incomplete" { failure = "native-or-callback-verification-failed" }
        phase = passed ? "passed" : (Task.isCancelled ? "cancelled" : "failed")
        try? write(receipt(lastPhase: terminalPhase), name: "active-guidance-workflow.json")
        try? progress()
        try? marker("ACTIVE_GUIDANCE_WORKFLOW_\(passed ? "PASSED" : "FAILED")")
        model.onPrepareScreenGuidance = oldPreparation
        model.onScreenGuidanceTargetAccepted = oldTarget
        model.validateGuidanceRefreshScope = oldRefreshValidation
        model.setGuidanceModeArmed(false)
        cursor.shutdown()
        model.providerMode = oldProvider
        model.configuration.speechEnabled = oldSpeech
        model.guidanceModelPreference = oldPreference
        model.selectedDisplay = oldDisplay
      }
      try FileManager.default.createDirectory(
        at: output, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
      try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: output.path)
      try progress()
      guard !model.busy, !model.listening, !model.voice.hasPendingSpeech,
        !model.guidanceModeArmed, model.evidence == nil, model.selectedContext.isEmpty,
        oldTarget != nil, CursorCompanionPreferences.load().screenGuidanceEnabled
      else { throw refuse("startup-not-isolated-or-guidance-unavailable") }
      traceStart = model.diagnosticEvents.count
      phase = "waitingForPublicFixture"
      try progress()
      let foregroundDeadline = min(started + 150, ProcessInfo.processInfo.systemUptime + 45)
      while NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        != "org.opencompanion.fixture.guidance"
      {
        try checkDeadline(foregroundDeadline)
        try await Task.sleep(for: .milliseconds(100))
      }
      guard let fixture = NSWorkspace.shared.frontmostApplication,
        fixture.bundleIdentifier == "org.opencompanion.fixture.guidance",
        let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }),
        let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
      else { throw refuse("public-fixture-display-unavailable") }
      self.fixture = fixture
      launchedAt = fixture.launchDate
      self.screen = screen
      displayID = number.uint32Value
      try verifyFixture()
      model.providerMode = "ChatGPT via Codex"
      model.guidanceModelPreference = .terra
      model.configuration.speechEnabled = false
      model.selectedDisplay = displayID
      model.validateGuidanceRefreshScope = { [self] source in
        do {
          guard oldRefreshValidation?(source) != false else {
            throw refuse("existing-refresh-scope-validation-refused")
          }
          try verifyFixture()
          guard source.foregroundPID == fixture.processIdentifier,
            source.displayID == displayID, source.screenRect == screen.frame,
            source.windowID == nil
          else { throw refuse("refresh-public-source-mismatch") }
          return true
        } catch {
          callbackFailure = failure == "incomplete" ? "refresh-public-coverage-lost" : failure
          return false
        }
      }
      model.onPrepareScreenGuidance = { [self] generation, pid in
        try verifyFixture()
        guard pid == fixture.processIdentifier, generation == model.taskGeneration else {
          throw refuse("capture-source-or-generation-changed")
        }
        if let oldPreparation { try await oldPreparation(generation, pid) }
        try await prepare(generation: generation)
      }
      model.onScreenGuidanceTargetAccepted = { [self] target, evidence, generation, request in
        guard callbackFailure == nil else { return }
        do {
          try acceptTarget(target, evidence: evidence, generation: generation, request: request)
          oldTarget?(target, evidence, generation, request)
        } catch {
          callbackFailure = failure == "incomplete" ? "target-validation-failed" : failure
        }
      }
      phase = "checkingInitialScreen"
      try progress()
      model.setGuidanceModeArmed(true)
      model.beginScreenGuidance(
        "Open Table settings, enter Release QA in Table name, then turn Protect data off.",
        speakAloud: false)
      workflowID = model.guidanceSession.workflow?.id
      sessionID = model.guidanceRuntime.id
      guard workflowID != nil, sessionID != nil else { throw refuse("active-runtime-not-started") }
      while true {
        try checkDeadline(started + 150)
        try verifyFixture()
        if let callbackFailure { throw refuse(callbackFailure) }
        guard model.error == nil else { throw refuse("production-turn-error") }
        guard model.scene == originalScene, count("visual.accepted") == 0 else {
          throw refuse("unexpected-notebook-mutation")
        }
        guard model.guidanceSession.workflow?.id == workflowID,
          model.guidanceRuntime.id == nil || model.guidanceRuntime.id == sessionID
        else { throw refuse("workflow-or-runtime-replaced") }
        guard count("guidance.manualContinue.requested") == 0,
          count("guidance.userClick.observed") == 0
        else {
          throw refuse("unexpected-mouseup-or-continue-advance")
        }
        if let frame = model.evidence { try recordFrame(frame) }
        if targetFrames.count == 3, !model.busy,
          model.guidanceSession.workflow?.phase == .modelReportedComplete,
          let frame = model.evidence, let previous = targetFrames.last,
          frame.frameID != previous.frameID, frame.revision > previous.revision,
          frame.capturedAt > previous.capturedAt,
          let before = preparations.last(where: {
            $0.generation == model.taskGeneration && $0.time <= frame.capturedAt
          })?.state, before.tableNameMatchesReleaseQA, !before.protectDataChecked
        {
          guard hasEvent("semantic.text.accepted", generation: model.taskGeneration),
            hasEvent("generation.completed", generation: model.taskGeneration),
            count("guidance.live.freshCheck") >= 3,
            count("guidance.capture.accepted") >= 4,
            !events().filter({ $0["event"]?.hasPrefix("guidance.live.changed.") == true }).isEmpty,
            model.guidanceProviderStatus.lowercased().contains("terra"),
            model.guidanceProviderStatus.lowercased().contains("low effort"),
            frame.groundingCandidates.contains(where: {
              $0.source == .ocr && normalized($0.label).contains("releaseqa")
            })
          else { throw refuse("final-production-evidence-incomplete") }
          finalBefore = before
          phase = "verifyingFinalNativeState"
          try progress()
          let after = try await GuidanceFixtureStateAcceptance.snapshot(
            expectedFixturePID: fixture.processIdentifier, displayID: displayID,
            screenRect: screen.frame)
          try verifyFixture()
          guard after.capturedAtUptime >= frame.capturedAt,
            after.tableNameMatchesReleaseQA, !after.protectDataChecked,
            ScreenEvidenceIdentity(frame).matches(model.evidence), !model.busy
          else { throw refuse("native-postcondition-not-stable") }
          finalAfter = after
          passed = true
          return
        }
        try await Task.sleep(for: .milliseconds(100))
      }
    }

    private func prepare(generation: UInt64) async throws {
      try verifyFixture()
      guard preparations.count < 48 else { throw refuse("capture-budget-exceeded") }
      var state: GuidanceFixtureStateAcceptance.Snapshot?
      do {
        state = try await GuidanceFixtureStateAcceptance.snapshot(
          expectedFixturePID: fixture!.processIdentifier, displayID: displayID,
          screenRect: screen!.frame)
      } catch let error as GuidanceFixtureStateAcceptance.Failure {
        // The known initial page deliberately has no exposed settings controls.
        // Denied, malformed or stale AX can never establish an initial state.
        guard preparations.isEmpty else {
          failure = "fixture-state-\(String(describing: error))"
          throw error
        }
        switch error {
        case .missingControl, .hiddenControl: break
        default:
          failure = "fixture-state-\(String(describing: error))"
          throw error
        }
      }
      try verifyFixture()
      guard generation == model.taskGeneration else { throw refuse("capture-generation-changed") }
      if let state, initialForm == nil {
        guard !state.tableNameMatchesReleaseQA, state.protectDataChecked else {
          throw refuse("initial-public-form-not-pristine")
        }
        initialForm = state
      }
      preparations.append((generation, ProcessInfo.processInfo.systemUptime, state))
    }

    private func acceptTarget(
      _ target: ProviderTarget, evidence: ScreenEvidence, generation: UInt64,
      request: ScreenGuidanceRequest
    ) throws {
      try verifyFixture()
      try recordFrame(evidence)
      guard targets.count < 24, targetFrames.count < 3,
        generation == model.taskGeneration,
        ScreenEvidenceIdentity(evidence).matches(model.evidence),
        request == model.activeGuidanceRequest, request.selectedScope == nil,
        let mark = model.overlay.presentationDiagnostics.last(where: {
          $0.ownerGeneration == generation && $0.frameID == evidence.frameID
        }), mark.panelVisible, mark.panelAlpha >= 0.99, mark.viewMounted,
        mark.panelIgnoresMouseEvents, !mark.panelCanBecomeKey, !mark.panelIsKey
      else { throw refuse("target-or-native-mark-ownership-invalid") }
      let ordinal = targetFrames.count
      if ordinal == 0 {
        let labels = evidence.groundingCandidates.filter { $0.source == .ocr }.map {
          normalized($0.label)
        }
        guard labels.contains(where: { $0.contains("practiceproject") }),
          labels.contains(where: { $0.contains("opentablesettings") })
        else {
          throw refuse("initial-public-page-not-visible-in-capture")
        }
      }
      let size = screen!.frame.size
      let expected = expectedControl(ordinal: ordinal, size: size)
      let rect = CGRect(
        x: target.x * size.width, y: target.y * size.height,
        width: target.width * size.width, height: target.height * size.height)
      guard [rect.minX, rect.minY, rect.width, rect.height].allSatisfy(\.isFinite),
        rect.width >= 8, rect.height >= 8,
        expected.insetBy(dx: -20, dy: -12).contains(rect),
        ordinal == 2
          ? (rect.contains(CGPoint(x: expected.minX + 9, y: expected.midY))
            || rect.contains(CGPoint(x: expected.minX + 78, y: expected.midY)))
          : (rect.contains(CGPoint(x: expected.midX, y: expected.midY))
            && rect.width >= expected.width * 0.4 && rect.height >= expected.height * 0.4),
        ordinal == 1
          ? (target.advanceOn == "manual" && target.awaitUser == true && initialForm != nil)
          : target.advanceOn == "click"
      else { throw refuse("target-not-grounded-in-next-public-control") }
      if let previous = targetFrames.last {
        guard evidence.frameID != previous.frameID, evidence.revision > previous.revision,
          evidence.capturedAt > previous.capturedAt
        else { throw refuse("target-frame-not-fresh") }
      }
      if ordinal == 2 {
        guard let state = preparations.last(where: { $0.generation == generation })?.state,
          state.tableNameMatchesReleaseQA, state.protectDataChecked
        else {
          throw refuse("edited-form-state-not-verified")
        }
      }
      targetFrames.append(evidence)
      let summary: [String: Any] = [
        "stage": ordinal, "control": ["openSettings", "tableName", "protectData"][ordinal],
        "generation": generation, "requestStep": request.step,
        "frameID": evidence.frameID.uuidString, "revision": evidence.revision,
        "advanceOn": target.advanceOn ?? "", "awaitUser": target.awaitUser ?? false,
        "shape": target.shape ?? "",
        "normalizedBounds": [target.x, target.y, target.width, target.height],
        "nativeMarkID": mark.id.uuidString, "nativeMarkMounted": true,
        "instructionCharacterCount": target.instruction.count, "elapsedMS": elapsedMS,
      ]
      targets.append(summary)
      phase = ["waitingForOpenSettings", "waitingForTableName", "waitingForProtectionOff"][ordinal]
      try write(summary, name: "stage\(ordinal)-ready.json")
      try progress()
      try marker("ACTIVE_GUIDANCE_STAGE\(ordinal)_READY")
    }

    private func recordFrame(_ frame: ScreenEvidence) throws {
      try verifyFixture()
      guard frame.foregroundPID == fixture?.processIdentifier, frame.displayID == displayID,
        frame.windowID == nil, frame.screenRect == screen?.frame,
        frame.image.count <= 12 * 1_024 * 1_024,
        let source = CGImageSourceCreateWithData(frame.image as CFData, nil),
        CGImageSourceGetCount(source) == 1,
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
        let width = properties[kCGImagePropertyPixelWidth] as? Int,
        let height = properties[kCGImagePropertyPixelHeight] as? Int,
        (1...8_192).contains(width), (1...8_192).contains(height),
        width == frame.imageWidth, height == frame.imageHeight,
        (properties[kCGImagePropertyOrientation] as? Int ?? 1) == 1,
        frame.capturedAt.isFinite,
        preparations.contains(where: { $0.time <= frame.capturedAt })
      else { throw refuse("actual-capture-source-or-header-invalid") }
      guard !frames.contains(where: { $0["frameID"] as? String == frame.frameID.uuidString }) else {
        return
      }
      guard frames.count < 48 else { throw refuse("frame-budget-exceeded") }
      frames.append([
        "frameID": frame.frameID.uuidString, "revision": frame.revision,
        "capturedAtUptime": frame.capturedAt, "width": width, "height": height,
        "fullPublicDisplay": true, "actualImageHeaderVerified": true,
        "containsReleaseQA": frame.groundingCandidates.contains {
          $0.source == .ocr && normalized($0.label).contains("releaseqa")
        },
      ])
    }

    private func expectedControl(ordinal: Int, size: CGSize) -> CGRect {
      let width = min(620, max(240, size.width - 96))
      let left = max(32, size.width * 0.4 - width / 2)
      switch ordinal {
      case 0:
        return CGRect(x: size.width * 0.4 - 132, y: size.height * 0.45 - 25, width: 264, height: 50)
      case 1:
        return CGRect(x: left, y: size.height * 0.45 + 20, width: min(width, 420), height: 34)
      default:
        return CGRect(x: left, y: size.height * 0.45 + 75, width: 240, height: 30)
      }
    }

    private func verifyFixture() throws {
      try checkDeadline(started + 150)
      guard let fixture, let screen, !fixture.isTerminated, fixture.launchDate == launchedAt else {
        throw refuse("public-fixture-identity-lost")
      }
      try GuidanceFixtureStateAcceptance.verifyEnvironment(
        expectedFixturePID: fixture.processIdentifier, displayID: displayID,
        screenRect: screen.frame)
      guard let primary = NSScreen.screens.first,
        let list = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID),
        CFArrayGetCount(list) <= 4_096, let windows = list as? [[String: Any]]
      else { throw refuse("public-fixture-window-order-unavailable") }
      let display = CGRect(
        x: screen.frame.minX, y: primary.frame.maxY - screen.frame.maxY,
        width: screen.frame.size.width, height: screen.frame.size.height)
      guard GuidanceObservationScope.valid(display) else {
        throw refuse("public-fixture-display-geometry-unavailable")
      }
      // Captures exclude this process. The first other visible layer-0 window
      // touching the display must itself be the opaque full public fixture.
      let ownPID = ProcessInfo.processInfo.processIdentifier
      for window in windows {
        guard let layer = (window[kCGWindowLayer as String] as? NSNumber)?.intValue else {
          throw refuse("public-fixture-window-order-unavailable")
        }
        guard layer == 0 else { continue }
        guard let pid = (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
          pid > 0,
          let alpha = (window[kCGWindowAlpha as String] as? NSNumber)?.doubleValue,
          alpha.isFinite, (0...1).contains(alpha),
          let dictionary = window[kCGWindowBounds as String] as? [String: Any],
          let rect = CGRect(dictionaryRepresentation: dictionary as CFDictionary),
          GuidanceObservationScope.valid(rect)
        else { throw refuse("public-fixture-window-order-unavailable") }
        guard pid != ownPID, alpha > 0, rect.intersects(display) else { continue }
        guard pid == fixture.processIdentifier, alpha == 1, rect.contains(display) else {
          throw refuse("public-fixture-front-window-does-not-cover-display")
        }
        return
      }
      throw refuse("public-fixture-does-not-cover-display")
    }

    private func checkDeadline(_ deadline: TimeInterval) throws {
      try Task.checkCancellation()
      guard ProcessInfo.processInfo.systemUptime < deadline else {
        throw refuse("deadline-expired")
      }
    }

    private func events() -> [[String: String]] {
      Array(model.diagnosticEvents.dropFirst(traceStart).suffix(2_000))
    }
    private func count(_ event: String) -> Int { events().filter { $0["event"] == event }.count }
    private func hasEvent(_ event: String, generation: UInt64) -> Bool {
      events().contains { $0["event"] == event && $0["generation"] == String(generation) }
    }
    private func normalized(_ text: String) -> String {
      text.lowercased().filter { $0.isLetter || $0.isNumber }
    }
    private var elapsedMS: Double {
      let value = (ProcessInfo.processInfo.systemUptime - started) * 1_000
      return value.isFinite ? max(0, value) : 0
    }
    private func refuse(_ code: String) -> ProviderError {
      failure = code
      return .message("Active public guidance verification: \(code).")
    }
    private func encoded<T: Encodable>(_ value: T?) -> Any {
      guard let value, let data = try? JSONEncoder().encode(value),
        let result = try? JSONSerialization.jsonObject(with: data)
      else { return NSNull() }
      return result
    }
    private func receipt(lastPhase: String) -> [String: Any] {
      let names = [
        "guidance.capture.accepted", "guidance.live.freshCheck",
        "guidance.manualContinue.requested", "guidance.userClick.observed", "generation.completed",
      ]
      return [
        "result": passed ? "passed" : "failed", "failureCode": passed ? "" : failure,
        "lastPhase": lastPhase, "elapsedMS": elapsedMS, "publicFixtureOnly": true,
        "declaredInputDriver": "external-AX-driver", "physicalInputVerified": false,
        "automaticDesktopActions": false, "audioUsed": false, "microphoneUsed": false,
        "taskComplete": passed, "fixturePostconditionVerified": finalAfter != nil && passed,
        "initialPage": "Practice Project", "initialFormState": encoded(initialForm),
        "beforeFinalCapture": encoded(finalBefore), "afterFinalCapture": encoded(finalAfter),
        "preparationCount": preparations.count, "frames": frames, "targets": targets,
        "preparationCheckpoints": preparations.map {
          [
            "generation": $0.generation, "observedAtUptime": $0.time,
            "formState": encoded($0.state),
          ] as [String: Any]
        },
        "workflowID": workflowID?.uuidString as Any? ?? NSNull(),
        "activeSessionID": sessionID?.uuidString as Any? ?? NSNull(),
        "workflowCheckCount": model.guidanceSession.workflow?.checks.count ?? 0,
        "workflowActionCount": model.guidanceSession.workflow?.actions.count ?? 0,
        "providerStatus": String(model.guidanceProviderStatus.prefix(160)),
        "eventCounts": Dictionary(uniqueKeysWithValues: names.map { ($0, count($0)) }),
        "events": events(), "windowServerMarkPixelsVerified": false,
        "threeApplicationWorkflowVerified": false,
      ]
    }
    private func progress() throws {
      try write(
        [
          "phase": phase, "elapsedMS": elapsedMS, "targetCount": targets.count,
          "frameCount": frames.count, "preparationCount": preparations.count,
          "terminal": ["passed", "failed", "cancelled"].contains(phase), "taskComplete": passed,
        ], name: "active-guidance-phase.json")
    }
    private func write(_ value: [String: Any], name: String) throws {
      let data = try JSONSerialization.data(
        withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
      guard data.count <= 512 * 1_024 else { throw refuse("receipt-budget-exceeded") }
      let url = output.appendingPathComponent(name)
      try data.write(to: url, options: .atomic)
      try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    private func marker(_ text: String) throws {
      try FileHandle.standardOutput.write(contentsOf: Data((text + "\n").utf8))
    }
  }
}
