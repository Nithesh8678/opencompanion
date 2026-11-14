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

  private enum BrowserControl: String, Codable, Sendable {
    case projectName, protection, save
  }

  private struct State: Codable, Sendable, Equatable {
    let observedAt: TimeInterval
    var publicIdentity = false
    var nameEmpty = false
    var nameMatches = false
    var protectionOn: Bool?
    var savedMessage = false
    var projectNameRect: CGRect?
    var protectionRect: CGRect?
    var saveRect: CGRect?
    var nextBrowserControl: BrowserControl? {
      guard publicIdentity else { return nil }
      if !nameMatches { return .projectName }
      if protectionOn == true { return .protection }
      if protectionOn == false && !savedMessage { return .save }
      return nil
    }
    func rect(for control: BrowserControl) -> CGRect? {
      switch control {
      case .projectName: projectNameRect
      case .protection: protectionRect
      case .save: saveRect
      }
    }
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
    let awaitUser: Bool?
    let shape: String?
    let primary: Bool
    let actionID: UUID?
    let checkID: UUID?
    let targetRect: CGRect
    let expectedControl: BrowserControl?
    var targetAccuracy: String
    var nativeControlRect: CGRect?
    var verifiedAt: TimeInterval?
    let publicFactKeyBefore: String?
    var independentEffect: String?
    var effectObservedAt: TimeInterval?
    let publicInstruction: String
    let publicLabel: String?
  }

  private struct Preparation: Codable {
    let generation: UInt64
    let state: State
    let postconditionSatisfied: Bool
  }

  private struct WindowGeometryDiagnostic: Codable, Sendable {
    let expectedWindowID: CGWindowID
    let expectedRect: CGRect
    let actualAXRect: CGRect?
    let actualAXRectValid: Bool
    let publicTitleMatches: Bool
    let deltaX: Double?
    let deltaY: Double?
    let deltaWidth: Double?
    let deltaHeight: Double?
  }

  private struct Refusal: Error {
    let code: String
    let windowGeometry: WindowGeometryDiagnostic?
    init(_ code: String, windowGeometry: WindowGeometryDiagnostic? = nil) {
      self.code = code
      self.windowGeometry = windowGeometry
    }
  }

  @MainActor static func run(
    model: AppModel, cursor: CursorCompanionCoordinator, output: URL, scenario name: String
  ) async throws {
    let began = ProcessInfo.processInfo.systemUptime
    var failure = "incomplete"
    var passed = false
    var postconditionVerified = false
    var modelCompletionVerified = false
    var resultClassification: String?
    var windowGeometryFailure: WindowGeometryDiagnostic?
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
        "result": resultClassification ?? (passed ? "passed" : "failed"),
        "fullPass": passed, "failureCode": postconditionVerified ? "" : failure,
        "publicWindowGeometryFailure": windowGeometryFailure.map(json) ?? NSNull(),
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
        "primaryTargetCount": stages.filter(\.primary).count,
        "independentlyGeometryVerifiedPrimaryCount":
          stages.filter { $0.primary && $0.targetAccuracy == "verified-native-control" }.count,
        "independentlyEffectObservedPrimaryCount":
          stages.filter { $0.primary && $0.effectObservedAt != nil }.count,
        "stepEvidence":
          "Distinct primary action/check/generation/frame identities joined to later independently read public state effects. A physical mouse-up is not required or authenticated.",
        "productionEventCounts": counts, "productionEventCountsAreBoundedRecentTrace": true,
        "workflowCheckCount": model.guidanceSession.workflow?.checks.count ?? 0,
        "providerIdleBeforeCleanup": providerIdleBeforeCleanup,
        "independentPostconditionVerified": postconditionVerified,
        "modelReportedCompletionVerified": modelCompletionVerified,
        "targetAccuracyVerified": passed,
        "targetAccuracyBoundary":
          "Browser primaries require independent exact public AX control geometry. Native-app primaries require separate external target review.",
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
      let terminal =
        passed
        ? "PASSED"
        : (postconditionVerified ? "POSTCONDITION_PASSED_TARGET_ACCURACY_UNVERIFIED" : "FAILED")
      try? marker("GUIDANCE_PUBLIC_APP_TERMINAL_\(terminal)")
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
      selectedWindowRect = environment.windowRect
      selectedWindowID = environment.windowID
      selectedPID = environment.pid
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
        // Metadata/visual refresh may advance without a global mouse-up. Join
        // the retained primary to its independently observed public effect;
        // this never authenticates physical input or equates a click to success.
        for index in stages.indices
        where stages[index].primary
          && stages[index].effectObservedAt == nil
        {
          let stage = stages[index]
          guard let verifiedAt = stage.verifiedAt, state.observedAt > verifiedAt,
            stage.targetAccuracy == "verified-native-control"
              || stage.targetAccuracy == "unverified-native-scenario"
          else { continue }
          let effect: String?
          if scenario == .browser {
            switch stage.expectedControl {
            case .projectName: effect = state.nameMatches ? "name-matches" : nil
            case .protection:
              effect = state.nameMatches && state.protectionOn == false ? "protection-off" : nil
            case .save:
              effect =
                state.nameMatches && state.protectionOn == false && state.savedMessage
                ? "saved-public-project" : nil
            case nil: effect = nil
            }
          } else {
            effect =
              stage.publicFactKeyBefore.map { $0 != state.factKey } == true
              ? "public-state-changed" : nil
          }
          if let effect {
            stages[index].independentEffect = effect
            stages[index].effectObservedAt = state.observedAt
          }
        }
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
      @MainActor func distinctObservedPrimaries() -> [Stage] {
        guard let workflow = model.guidanceSession.workflow else { return [] }
        var actions = Set<UUID>()
        var generations = Set<UInt64>()
        var frames = Set<UUID>()
        var checks = Set<UUID>()
        var joined: [Stage] = []
        for stage in stages where stage.primary {
          guard let actionID = stage.actionID, let checkID = stage.checkID,
            let action = workflow.actions.first(where: { $0.id == actionID }),
            action.checkID == checkID,
            action.observation == nil || action.observation?.actionID == actionID,
            stage.independentEffect != nil, stage.effectObservedAt != nil,
            actions.insert(actionID).inserted, checks.insert(checkID).inserted,
            generations.insert(stage.generation).inserted, frames.insert(stage.frameID).inserted,
            stage.targetAccuracy == "verified-native-control"
              || stage.targetAccuracy == "unverified-native-scenario"
          else { continue }
          joined.append(stage)
        }
        return joined
      }
      @MainActor func finalModelCompleted(generation: UInt64) -> Bool {
        !model.busy && model.taskGeneration == generation
          && model.guidanceSession.workflow?.phase == .modelReportedComplete
          && model.guidanceSession.workflow?.checks.last?.outcome == .goalComplete
          && model.diagnosticEvents.dropFirst(traceStart).contains {
            $0["event"] == "generation.completed" && $0["generation"] == String(generation)
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
            let targetRect = ScreenGuidancePolicy.targetRect(target, in: evidence.screenRect)
          else {
            throw Refusal("target-source-or-geometry-invalid")
          }
          let size = try ScreenImageGeometry.trustedEncodedPixelSize(evidence.image)
          guard evidence.imageWidth == Int(size.width), evidence.imageHeight == Int(size.height)
          else { throw Refusal("capture-header-invalid") }
          observedFrames.insert(evidence.frameID)
          let primary =
            target.advanceOn == "click"
            || (target.advanceOn == "manual" && target.awaitUser == true)
          let action = primary ? model.guidanceSession.workflow?.currentAction : nil
          guard
            !primary
              || (action != nil
                && action?.checkID == model.guidanceSession.currentToken?.checkID)
          else { throw Refusal("primary-action-ownership-unverified") }
          let preparation = preparations.last(where: { $0.generation == generation })
          let stage = Stage(
            ordinal: stages.count, generation: generation, requestStep: request.step,
            frameID: evidence.frameID, evidenceRevision: evidence.revision,
            capturedAt: evidence.capturedAt, observedAt: ProcessInfo.processInfo.systemUptime,
            x: target.x, y: target.y, width: target.width, height: target.height,
            advanceOn: target.advanceOn, awaitUser: target.awaitUser, shape: target.shape,
            primary: primary, actionID: action?.id, checkID: action?.checkID,
            targetRect: targetRect,
            expectedControl: scenario == .browser ? preparation?.state.nextBrowserControl : nil,
            targetAccuracy: primary ? "pending-independent-read" : "secondary-not-an-action",
            nativeControlRect: nil, verifiedAt: nil,
            publicFactKeyBefore: preparation?.state.factKey,
            independentEffect: nil, effectObservedAt: nil,
            publicInstruction: String(target.instruction.prefix(480)),
            publicLabel: target.label.map { String($0.prefix(80)) })
          stages.append(stage)
          priorTarget?(target, evidence, generation, request)
          // Only a primary joined to a fresh independent AX read is published
          // as driver-ready. Secondary annotations cannot inflate step counts.
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
        // This read occurs after native target submission, before target-ready.
        // A source change cannot be papered over with an old native rectangle.
        for index in stages.indices
        where stages[index].primary
          && stages[index].targetAccuracy == "pending-independent-read"
        {
          let stage = stages[index]
          guard stage.generation == model.taskGeneration,
            let frame = model.evidence, frame.frameID == stage.frameID,
            frame.revision == stage.evidenceRevision,
            matchesSelectedWindow(frame, environment: environment),
            let preparation = preparations.last(where: { $0.generation == stage.generation }),
            frame.capturedAt >= preparation.state.observedAt,
            model.guidanceSession.workflow?.currentAction?.id == stage.actionID
          else { throw Refusal("primary-verification-source-changed") }
          if scenario == .browser {
            stages[index].nativeControlRect = stage.expectedControl.flatMap { state.rect(for: $0) }
            guard let control = stage.expectedControl,
              preparation.state.nextBrowserControl == control, state.nextBrowserControl == control,
              let rect = stages[index].nativeControlRect,
              controlGeometryMatches(target: stage.targetRect, control: rect)
            else {
              stages[index].targetAccuracy = "native-control-mismatch"
              throw Refusal("browser-primary-control-geometry-unverified")
            }
            stages[index].targetAccuracy = "verified-native-control"
          } else {
            stages[index].targetAccuracy = "unverified-native-scenario"
          }
          stages[index].verifiedAt = state.observedAt
          try write(
            [
              "scenario": scenario.rawValue, "stage": json(stages[index]),
              "helperPostedInput": false,
            ], to: output.appendingPathComponent("target-ready.json"))
          try marker("GUIDANCE_PUBLIC_TARGET_\(stage.ordinal)_READY")
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
          distinctObservedPrimaries().count >= 3,
          finalModelCompleted(generation: preparation.generation),
          model.scene == initialScene
        {
          let primaries = distinctObservedPrimaries()
          if scenario == .browser {
            var next = 0
            let required: [BrowserControl] = [.projectName, .protection, .save]
            for stage in primaries where next < required.count {
              if stage.expectedControl == required[next] { next += 1 }
            }
            guard next == required.count,
              stages.filter(\.primary).allSatisfy({ $0.targetAccuracy == "verified-native-control" }
              )
            else { throw Refusal("browser-ordered-primary-controls-unverified") }
          }
          finalPreparation = preparation
          // A second independent read brackets the same already-accepted final
          // evidence. Model-complete prose alone can never satisfy this gate.
          let confirmation = try await readState(environment, scenario: scenario)
          try Task.checkCancellation()
          try verify(environment, scenario: scenario)
          guard ownsRuntime(), model.taskGeneration == preparation.generation,
            ScreenEvidenceIdentity(frame).matches(model.evidence), model.scene == initialScene,
            complete(confirmation), model.error == nil,
            finalModelCompleted(generation: preparation.generation)
          else {
            throw Refusal("postcondition-did-not-persist")
          }
          latest = confirmation
          postconditionVerified = true
          modelCompletionVerified = true
          passed = scenario == .browser
          resultClassification =
            passed ? "passed" : "postcondition-passed-target-accuracy-unverified"
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
      windowGeometryFailure = (error as? Refusal)?.windowGeometry
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
    let focus = try focusedAXWindow(
      pid: app.processIdentifier, primaryTop: primaryTop, scenario: scenario)
    var windows = try windowStack(screen: screen.frame, primaryTop: primaryTop)
    // Safari can place a small separate native chrome window above its focused
    // page. A same-process window is never sufficient proof on its own.
    if let matching = windows.firstIndex(where: {
      $0.pid == app.processIdentifier && sameGeometry($0.rect, focus.rect)
    }) {
      guard matching <= 8 else { throw Refusal("public-window-front-stack-budget") }
      let chromeDeadline = ProcessInfo.processInfo.systemUptime + 0.25
      for index in 0..<matching where windows[index].pid == app.processIdentifier {
        windows[index].verifiedFocusedChrome = verifiesFocusedChrome(
          windows[index].rect, focused: focus, primaryTop: primaryTop, deadline: chromeDeadline)
      }
    }
    let front = try selectPublicWindow(
      windows, focusedRect: focus.rect, pid: app.processIdentifier, screen: screen.frame)
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

  struct WindowCandidate: Sendable, Equatable {
    let id: CGWindowID
    let pid: pid_t
    let rect: CGRect
    let alpha: Double
    var verifiedFocusedChrome = false
  }

  /// Authored metadata seam: selection requires one exact focused-window match.
  /// Higher foreign windows or unverified same-process popups never disappear
  /// merely because the requested page is present farther down the stack.
  static func selectPublicWindow(
    _ windows: [WindowCandidate], focusedRect: CGRect, pid: pid_t, screen: CGRect
  ) throws -> WindowCandidate {
    guard windows.count <= 4_096, pid > 0,
      GuidanceObservationScope.valid(focusedRect), screen.contains(focusedRect)
    else { throw Refusal("focused-public-window-unverified") }
    let matches = windows.indices.filter {
      windows[$0].pid == pid && sameGeometry(windows[$0].rect, focusedRect)
    }
    guard matches.count == 1, let index = matches.first, index <= 8,
      windows[index].id > 0, windows[index].alpha == 1, screen.contains(windows[index].rect)
    else { throw Refusal("focused-public-window-unverified") }
    for candidate in windows[..<index] {
      guard candidate.id > 0, candidate.alpha.isFinite, candidate.alpha > 0,
        candidate.alpha <= 1, candidate.pid == pid, candidate.verifiedFocusedChrome,
        boundedTopChrome(candidate.rect, focusedRect: focusedRect)
      else { throw Refusal("public-window-occlusion-unverified") }
    }
    return windows[index]
  }

  private static func sameGeometry(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
    GuidanceObservationScope.valid(lhs) && GuidanceObservationScope.valid(rhs)
      && abs(lhs.minX - rhs.minX) <= 1 && abs(lhs.minY - rhs.minY) <= 1
      && abs(lhs.width - rhs.width) <= 1 && abs(lhs.height - rhs.height) <= 1
  }

  private static func boundedTopChrome(_ rect: CGRect, focusedRect: CGRect) -> Bool {
    GuidanceObservationScope.valid(rect) && focusedRect.contains(rect)
      && rect.width <= 320 && rect.height <= 48 && rect.width * rect.height <= 15_360
      && rect.minY >= focusedRect.maxY - 64
  }

  private struct FocusedAXWindow {
    let app: AXUIElement
    let window: AXUIElement
    let rect: CGRect
  }

  private static func focusedAXWindow(
    pid: pid_t, primaryTop: CGFloat, scenario: Scenario
  ) throws -> FocusedAXWindow {
    let app = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(app, 0.03)
    guard let rawWindow = axValue(app, kAXFocusedWindowAttribute as CFString),
      CFGetTypeID(rawWindow) == AXUIElementGetTypeID()
    else { throw Refusal("focused-public-window-unavailable") }
    let window = rawWindow as! AXUIElement
    AXUIElementSetMessagingTimeout(window, 0.03)
    guard let rect = axRect(window, primaryTop: primaryTop) else {
      throw Refusal("public-ax-window-geometry-unavailable")
    }
    if scenario == .browser {
      guard
        axValue(window, kAXTitleAttribute as CFString) as? String
          == "OpenCompanion Public Guide"
      else { throw Refusal("browser-public-title-mismatch") }
    } else if scenario == .textedit {
      guard let raw = axValue(window, kAXDocumentAttribute as CFString) as? String,
        raw.utf8.count <= 8_192, let url = URL(string: raw), url.isFileURL,
        url.lastPathComponent == "OpenCompanion Public Guide.rtf"
      else { throw Refusal("textedit-public-document-mismatch") }
    }
    return .init(app: app, window: window, rect: rect)
  }

  private static func verifiesFocusedChrome(
    _ rect: CGRect, focused: FocusedAXWindow, primaryTop: CGFloat, deadline: TimeInterval
  ) -> Bool {
    guard boundedTopChrome(rect, focusedRect: focused.rect),
      ProcessInfo.processInfo.systemUptime < deadline
    else { return false }
    var element: AXUIElement?
    guard
      AXUIElementCopyElementAtPosition(
        focused.app, Float(rect.midX), Float(primaryTop - rect.midY), &element) == .success,
      var current = element
    else { return false }
    let controls: Set<String> = [
      "AXButton", "AXMenuButton", "AXPopUpButton", "AXTextField", "AXSearchField",
      "AXCheckBox", "AXRadioButton",
    ]
    var ownedControl = false
    for _ in 0..<8 {
      guard ProcessInfo.processInfo.systemUptime < deadline else { return false }
      AXUIElementSetMessagingTimeout(current, 0.03)
      guard let role = axValue(current, kAXRoleAttribute as CFString) as? String,
        role.utf8.count <= 128, role != "AXWebArea"
      else { return false }
      if role == "AXWindow" {
        return ownedControl && CFEqual(current, focused.window)
      }
      if controls.contains(role),
        let owner = axValue(current, kAXWindowAttribute as CFString),
        CFGetTypeID(owner) == AXUIElementGetTypeID(), CFEqual(owner, focused.window)
      {
        ownedControl = true
      }
      guard let parent = axValue(current, kAXParentAttribute as CFString),
        CFGetTypeID(parent) == AXUIElementGetTypeID()
      else { return false }
      current = parent as! AXUIElement
    }
    return false
  }

  private static func axValue(_ element: AXUIElement, _ attribute: CFString) -> CFTypeRef? {
    var value: CFTypeRef?
    return AXUIElementCopyAttributeValue(element, attribute, &value) == .success ? value : nil
  }

  private static func axRect(_ element: AXUIElement, primaryTop: CGFloat) -> CGRect? {
    guard let rawPosition = axValue(element, kAXPositionAttribute as CFString),
      let rawSize = axValue(element, kAXSizeAttribute as CFString),
      CFGetTypeID(rawPosition) == AXValueGetTypeID(), CFGetTypeID(rawSize) == AXValueGetTypeID()
    else { return nil }
    let positionValue = rawPosition as! AXValue
    let sizeValue = rawSize as! AXValue
    var point = CGPoint.zero
    var size = CGSize.zero
    guard AXValueGetType(positionValue) == .cgPoint, AXValueGetType(sizeValue) == .cgSize,
      AXValueGetValue(positionValue, .cgPoint, &point),
      AXValueGetValue(sizeValue, .cgSize, &size)
    else { return nil }
    let rect = CGRect(
      x: point.x, y: primaryTop - point.y - size.height, width: size.width, height: size.height)
    return GuidanceObservationScope.valid(rect) ? rect : nil
  }
  @MainActor private static func windowStack(screen: CGRect, primaryTop: CGFloat) throws
    -> [WindowCandidate]
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
      return WindowCandidate(id: id, pid: pid, rect: rect, alpha: alpha)
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
      let title = string(window, kAXTitleAttribute as CFString)
      func finite(_ value: CGFloat) -> Double? { value.isFinite ? Double(value) : nil }
      guard GuidanceObservationScope.valid(actualRect),
        abs(actualRect.minX - environment.windowRect.minX) <= 1,
        abs(actualRect.minY - environment.windowRect.minY) <= 1,
        abs(actualRect.size.width - environment.windowRect.size.width) <= 1,
        abs(actualRect.size.height - environment.windowRect.size.height) <= 1
      else {
        throw Refusal(
          "public-ax-window-identity-mismatch",
          windowGeometry: .init(
            expectedWindowID: environment.windowID, expectedRect: environment.windowRect,
            actualAXRect: GuidanceObservationScope.valid(actualRect) ? actualRect : nil,
            actualAXRectValid: GuidanceObservationScope.valid(actualRect),
            publicTitleMatches: title == "OpenCompanion Public Guide",
            deltaX: finite(actualRect.minX - environment.windowRect.minX),
            deltaY: finite(actualRect.minY - environment.windowRect.minY),
            deltaWidth: finite(actualRect.size.width - environment.windowRect.size.width),
            deltaHeight: finite(actualRect.size.height - environment.windowRect.size.height)))
      }
      var state = State(observedAt: ProcessInfo.processInfo.systemUptime)
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
      var saves = 0
      func controlRect(_ element: AXUIElement) -> CGRect? {
        guard (value(element, kAXEnabledAttribute as CFString) as? NSNumber)?.boolValue == true,
          let rawPoint = value(element, kAXPositionAttribute as CFString),
          let rawExtent = value(element, kAXSizeAttribute as CFString),
          CFGetTypeID(rawPoint) == AXValueGetTypeID(),
          CFGetTypeID(rawExtent) == AXValueGetTypeID()
        else { return nil }
        let pointValue = rawPoint as! AXValue
        let extentValue = rawExtent as! AXValue
        var point = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetType(pointValue) == .cgPoint, AXValueGetType(extentValue) == .cgSize,
          AXValueGetValue(pointValue, .cgPoint, &point),
          AXValueGetValue(extentValue, .cgSize, &size)
        else { return nil }
        let rect = CGRect(
          x: point.x, y: environment.primaryTop - point.y - size.height,
          width: size.width, height: size.height)
        guard GuidanceObservationScope.valid(rect), environment.windowRect.contains(rect) else {
          return nil
        }
        return rect
      }
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
            state.projectNameRect = controlRect(element)
          }
          if role == "AXCheckBox", label == "Protect data" {
            protections += 1
            state.protectionRect = controlRect(element)
            if let number = value(element, kAXValueAttribute as CFString) as? NSNumber,
              [0, 1].contains(number.intValue)
            {
              state.protectionOn = number.intValue == 1
            }
          }
          if role == "AXButton", label == "Save project" {
            saves += 1
            state.saveRect = controlRect(element)
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
      case .browser:
        state.publicIdentity =
          webAreas == 1 && names == 1 && protections == 1 && saves == 1
          && state.projectNameRect != nil && state.protectionRect != nil && state.saveRect != nil
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

  /// Sampled model geometry is checked against the exact current public AX
  /// control; this is neither a general semantic classifier nor click success.
  private static func controlGeometryMatches(target: CGRect, control: CGRect) -> Bool {
    guard GuidanceObservationScope.valid(target), GuidanceObservationScope.valid(control),
      target.contains(CGPoint(x: control.midX, y: control.midY))
    else { return false }
    let overlap = target.intersection(control)
    let controlArea = control.width * control.height
    return !overlap.isNull && overlap.width * overlap.height >= controlArea * 0.5
      && target.width <= max(control.width * 2, control.width + 48)
      && target.height <= max(control.height * 2, control.height + 48)
      && target.width * target.height <= controlArea * 4
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
