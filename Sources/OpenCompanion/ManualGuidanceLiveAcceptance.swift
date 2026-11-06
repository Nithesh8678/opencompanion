import AppKit
import ApplicationServices
import ImageIO

struct GuidanceMarkRasterMetrics: Codable, Sendable {
  let opaqueOutlinePixels: Int
  let offContourPixels: Int
  let sidePixels: [Int]
  let minimumOutlinePixels: Int
  var verified: Bool {
    opaqueOutlinePixels >= minimumOutlinePixels && sidePixels.allSatisfy { $0 > 0 }
      && offContourPixels <= max(4, opaqueOutlinePixels / 5)
  }
}

/// Opt-in production capture/model/Continue check against the opaque public
/// Guidance Fixture only. This helper never types, clicks or records audio.
enum ManualGuidanceLiveAcceptance {
  private enum Phase: String {
    case preflight, waitingForPublicFixture, checkingDisplay, checkingObserver
    case preparingInitialCapture, capturingInitialFrame, awaitingInitialModelTarget
    case waitingForManualInput, continuationRequested, capturingContinuation
    case awaitingNextModelTarget, observingNextTarget, waitingForCheckboxClick
    case capturingFinalFrame, awaitingFinalReply, checkingTaskPostcondition, passed, failed,
      cancelled
  }

  @MainActor static func run(
    model: AppModel, cursor: CursorCompanionCoordinator, coordinator: ScreenGuidanceCoordinator,
    output: URL, verifyTaskCompletion: Bool = false
  ) async throws {
    let preflightStarted = ProcessInfo.processInfo.systemUptime
    let entryScene = model.scene
    var phase = Phase.preflight
    var failureCode = "startup-output-unavailable"
    var passed = false
    var activePathEntered = false
    var displayPoints: [Double] = []
    var checks: [String: Bool] = [:]
    var observedCounts: [String: Int] = [:]

    func reportPhase(_ next: Phase) {
      guard next != phase || next == .preflight else { return }
      phase = next
      try? writeJSON(
        [
          "phase": next.rawValue, "terminal": [.passed, .failed, .cancelled].contains(next),
          "failureCode": [.failed, .cancelled].contains(next) ? failureCode : "",
          "elapsedMS": elapsedMS(since: preflightStarted), "preflight": checks,
          "observedEventCounts": observedCounts, "fixtureDisplayPoints": displayPoints,
          "publicFixtureOnly": true, "automaticDesktopActions": false,
        ], to: output.appendingPathComponent("manual-guidance-phase.json"))
      // FileHandle writes directly to the descriptor: unlike print/stdio, these
      // newline markers need no buffered-stdout flush to reach the UI driver.
      try? marker("GUIDANCE_MANUAL_PHASE_\(next.rawValue.uppercased())")
    }

    // This exists before foreground waiting or any capture/model work. Startup
    // refusals must leave a terminal receipt too, without inventing progress.
    defer {
      let lastPhase = phase
      if !activePathEntered {
        if Task.isCancelled { failureCode = "startup-cancelled" }
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try? writeJSON(
          [
            "result": "failed", "failureCode": failureCode, "lastPhase": lastPhase.rawValue,
            "preflight": checks, "publicFixtureOnly": true,
            "actualCapturePath": NSNull(), "actualCaptureVerified": false,
            "captureAttempted": false, "providerPhaseObserved": false, "stages": [],
            "captureAcceptedEventCount": 0, "manualContinuationArmedCount": 0,
            "manualContinueRequestedCount": 0, "clickObservedCount": 0,
            "nativeContinueRequestedFreshCheck": false, "providerReportedError": false,
            "notebookUnchanged": model.scene == entryScene,
            "automaticDesktopActions": false, "microphoneUsed": false, "audioUsed": false,
            "checkboxActionPerformedByHelper": false, "checkboxCompletionVerified": false,
            "taskComplete": false, "endState": "startup-refused",
            "taskPostconditionRequired": verifyTaskCompletion,
            "elapsedMS": elapsedMS(since: preflightStarted),
            "fixtureDisplayPoints": displayPoints,
          ], to: output.appendingPathComponent("manual-guidance-live-acceptance.json"))
      }
      let interrupted = Task.isCancelled || failureCode == "generation-cancelled-or-replaced"
      reportPhase(passed ? .passed : (interrupted ? .cancelled : .failed))
      try? marker(
        "GUIDANCE_MANUAL_TERMINAL_\(passed ? "PASSED" : "FAILED")_\(passed ? "complete" : failureCode)"
      )
    }
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    failureCode = "startup-incomplete"
    reportPhase(.preflight)
    try Task.checkCancellation()
    checks["screenGuidanceEnabled"] = CursorCompanionPreferences.load().screenGuidanceEnabled
    guard checks["screenGuidanceEnabled"] == true else {
      failureCode = "startup-screen-guidance-disabled"
      throw ProviderError.message(
        "Manual guidance startup: screen guidance is disabled. Enable it before this explicit check."
      )
    }
    // The UI driver can invoke a background app's AX controls without making
    // that app foreground. Wait for a real user focus change; never activate an
    // app or capture unrelated content to make this acceptance pass.
    reportPhase(.waitingForPublicFixture)
    try marker("GUIDANCE_MANUAL_WAITING_FOR_PUBLIC_FIXTURE")
    let foregroundDeadline = ProcessInfo.processInfo.systemUptime + 90
    while NSWorkspace.shared.frontmostApplication?.bundleIdentifier
      != "org.opencompanion.fixture.guidance"
    {
      try Task.checkCancellation()
      guard ProcessInfo.processInfo.systemUptime < foregroundDeadline else {
        failureCode = "startup-public-fixture-foreground-timeout"
        throw ProviderError.message(
          "Manual guidance startup: the public Guidance Fixture did not become foreground within 90 seconds."
        )
      }
      try await Task.sleep(for: .milliseconds(100))
    }
    guard let fixture = NSWorkspace.shared.frontmostApplication,
      fixture.bundleIdentifier == "org.opencompanion.fixture.guidance"
    else {
      failureCode = "startup-public-fixture-not-foreground"
      throw ProviderError.message(
        "Manual guidance startup: the public Guidance Fixture must be foreground.")
    }
    checks["foregroundIsPublicFixture"] = true
    reportPhase(.checkingDisplay)
    guard let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }),
      let displayNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
        as? NSNumber
    else {
      failureCode = "startup-pointer-display-unavailable"
      throw ProviderError.message(
        "Manual guidance startup: the pointer must be on a display with valid native display geometry."
      )
    }
    checks["pointerDisplayAvailable"] = true
    if screen.frame.width.isFinite, screen.frame.height.isFinite {
      displayPoints = [Double(screen.frame.width), Double(screen.frame.height)]
    }
    guard fixtureCoversDisplay(pid: fixture.processIdentifier, screen: screen) else {
      failureCode = "startup-public-fixture-display-not-covered"
      throw ProviderError.message(
        "Manual guidance startup: the public Guidance Fixture must cover the pointer display.")
    }
    checks["fullDisplayFixtureCoverage"] = true
    reportPhase(.checkingObserver)
    guard let productionTargetObserver = model.onScreenGuidanceTargetAccepted
    else {
      failureCode = "startup-target-observer-missing"
      throw ProviderError.message(
        "Manual guidance startup: the production guidance target observer is not installed."
      )
    }
    checks["productionTargetObserverInstalled"] = true
    if verifyTaskCompletion {
      checks["fixtureStateAccessibilityTrusted"] = AXIsProcessTrusted()
      guard checks["fixtureStateAccessibilityTrusted"] == true else {
        failureCode = "startup-fixture-state-accessibility-denied"
        throw ProviderError.message(
          "The public task check needs OpenCompanion's existing Accessibility grant to read the fixture state. No capture was attempted."
        )
      }
    }
    activePathEntered = true
    let displayID = displayNumber.uint32Value
    let pid = fixture.processIdentifier
    let started = ProcessInfo.processInfo.systemUptime
    let traceStart = model.diagnosticEvents.count
    let oldPreparation = model.onPrepareScreenGuidance
    let oldBeforeContinue = coordinator.onManualContinueWillBegin
    let oldProvider = model.providerMode
    let oldSpeech = model.configuration.speechEnabled
    let oldGuidancePreference = model.guidanceModelPreference
    let oldDisplay = model.selectedDisplay
    let originalScene = model.scene
    let taskVerifier =
      verifyTaskCompletion
      ? GuidanceFixtureTaskAcceptance(
        model: model, expectedFixturePID: pid, displayID: displayID,
        screenRect: screen.frame, traceStart: traceStart)
      : nil
    var taskReceipt: GuidanceFixtureTaskAcceptance.Receipt?
    var taskVerificationStarted = false
    var frames: [Int: ScreenEvidence] = [:]
    var stages: [Int: [String: Any]] = [:]
    var acceptedTargets: [Int: ProviderTarget] = [:]
    var acceptedGenerations: [Int: UInt64] = [:]
    var markIDs: [Int: UUID] = [:]
    var markSamples: [[String: Any]] = []
    var sampledCheckpoints = Set<String>()
    var requestID: UUID?
    var rejection: String?
    var fixtureStateFailure: String?
    failureCode = "incomplete"

    func recentEvents() -> [[String: String]] {
      Array(model.diagnosticEvents.dropFirst(traceStart).suffix(2_000))
    }
    func eventCount(_ name: String) -> Int {
      recentEvents().filter { $0["event"] == name }.count
    }
    func reportObservedPhase() {
      let names = [
        "guidance.capture.started", "guidance.capture.accepted", "guidance.stage.provider",
        "guidance.manualContinuation.armed", "guidance.manualContinue.requested",
        "guidance.userClick.observed",
      ]
      observedCounts = Dictionary(uniqueKeysWithValues: names.map { ($0, 0) })
      for event in recentEvents() {
        if let name = event["event"], observedCounts[name] != nil {
          observedCounts[name, default: 0] += 1
        }
      }
      if taskVerificationStarted {
        if observedCounts["guidance.capture.accepted", default: 0] == 3 {
          reportPhase(.awaitingFinalReply)
        } else if observedCounts["guidance.userClick.observed", default: 0] == 1 {
          reportPhase(.capturingFinalFrame)
        } else {
          reportPhase(.waitingForCheckboxClick)
        }
      } else if stages[1] != nil {
        reportPhase(.observingNextTarget)
      } else if observedCounts["guidance.manualContinue.requested", default: 0] > 0 {
        if observedCounts["guidance.capture.accepted", default: 0] >= 2 {
          reportPhase(.awaitingNextModelTarget)
        } else if observedCounts["guidance.capture.started", default: 0] >= 2 {
          reportPhase(.capturingContinuation)
        } else {
          reportPhase(.continuationRequested)
        }
      } else if stages[0] != nil {
        reportPhase(.waitingForManualInput)
      } else if observedCounts["guidance.capture.accepted", default: 0] > 0 {
        reportPhase(.awaitingInitialModelTarget)
      } else if observedCounts["guidance.capture.started", default: 0] > 0 {
        reportPhase(.capturingInitialFrame)
      } else {
        reportPhase(.preparingInitialCapture)
      }
    }
    func checkFixture() throws {
      try Task.checkCancellation()
      guard !fixture.isTerminated,
        NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
        screen.frame.contains(NSEvent.mouseLocation),
        NSScreen.screens.contains(where: { $0.frame == screen.frame }),
        fixtureCoversDisplay(pid: pid, screen: screen)
      else {
        throw ProviderError.message("The public fixture lost foreground or full-display coverage.")
      }
    }
    func sampleMark(step: Int, checkpoint: String, requireSettled: Bool) throws {
      let key = "step\(step)-\(checkpoint)"
      guard !sampledCheckpoints.contains(key), markSamples.count < 5,
        let evidence = frames[step], let target = acceptedTargets[step],
        let generation = acceptedGenerations[step], generation == model.taskGeneration,
        ScreenEvidenceIdentity(evidence).matches(model.evidence)
      else {
        throw ProviderError.message("The native mark checkpoint lost its exact turn ownership.")
      }
      try checkFixture()
      let targetRect = CGRect(
        x: target.x * screen.frame.width, y: target.y * screen.frame.height,
        width: target.width * screen.frame.width, height: target.height * screen.frame.height)
      let observations = model.overlay.presentationDiagnostics
      let observationMetadata = try JSONSerialization.jsonObject(
        with: JSONEncoder().encode(observations))
      try writeJSON(
        [
          "checkpoint": key, "elapsedMS": elapsedMS(since: started),
          "retainedMarks": observationMetadata, "localOwnViewOnly": true,
          "expectedTargetRect": [targetRect.minX, targetRect.minY, targetRect.width, targetRect.height],
          "expectedOwnerGeneration": generation, "expectedFrameID": evidence.frameID.uuidString,
          "expectedEvidenceRevision": evidence.revision, "expectedDisplayID": displayID,
          "expectedForegroundPID": pid, "expectedShape": target.shape ?? "roundedRectangle",
          "windowServerDesktopVisibilityVerified": false,
        ],
        to: output.appendingPathComponent("mark-\(key)-observation.json"))
      let candidates = observations.filter {
        $0.ownerGeneration == generation && $0.frameID == evidence.frameID
          && $0.evidenceRevision == evidence.revision && $0.displayID == displayID
          && $0.foregroundPID == pid && $0.windowID == nil && $0.sourceRect == screen.frame
          && retainedTargetMatches($0.targetRect, expected: targetRect, displaySize: screen.frame.size)
          && $0.shape == (target.shape ?? "roundedRectangle")
          && (markIDs[step] == nil || markIDs[step] == $0.id)
      }
      guard candidates.count == 1, let mark = candidates.first else {
        throw ProviderError.message("The exact native target mark was missing or ambiguous.")
      }
      let now = ProcessInfo.processInfo.systemUptime
      let expectedPath = mark.shape == "ellipse" ? targetRect.insetBy(dx: 2, dy: 2) : targetRect
      let tolerance: CGFloat = mark.shape == "ellipse" ? 1.5 : 0.25
      let pathMatches = zip(
        [
          mark.outlinePathBounds.minX, mark.outlinePathBounds.minY,
          mark.outlinePathBounds.width, mark.outlinePathBounds.height,
        ],
        [expectedPath.minX, expectedPath.minY, expectedPath.width, expectedPath.height]
      ).allSatisfy { abs($0 - $1) <= tolerance }
      guard mark.createdAt.isFinite, mark.expiresAt.isFinite, now >= mark.createdAt,
        now < mark.expiresAt, mark.expiresAt - mark.createdAt <= 45,
        mark.panelVisible, mark.panelFrame == screen.frame, mark.panelAlpha >= 0.99,
        mark.panelIgnoresMouseEvents, !mark.panelCanBecomeKey, !mark.panelIsKey,
        mark.viewMounted, !mark.viewHidden, !mark.rootHidden, mark.rootOpacity >= 0.99,
        !mark.outlineHidden, mark.outlineOpacity >= 0.99, mark.outlineStrokeEnd >= 0.99,
        mark.outlineLineWidth > 0, mark.outlineLineWidth <= 6, pathMatches,
        mark.outlineDashed == (mark.shape == "roundedRectangle"), !mark.labelHidden
      else {
        throw ProviderError.message("The retained native mark was hidden, expired or malformed.")
      }
      if requireSettled {
        guard mark.presentationOutlineHidden != true,
          (mark.presentationOutlineOpacity ?? mark.outlineOpacity) >= 0.99,
          (mark.presentationOutlineStrokeEnd ?? mark.outlineStrokeEnd) >= 0.99,
          (mark.presentationLabelOpacity ?? 1) >= 0.99
        else {
          throw ProviderError.message("The native mark entrance had not settled at its checkpoint.")
        }
      }
      let raster = try model.overlay.renderMark(id: mark.id)
      let pixels = try annotationRasterMetrics(
        raster, expectedTarget: targetRect, shape: mark.shape)
      let file = "mark-\(key).png"
      let metadata = try JSONSerialization.jsonObject(with: JSONEncoder().encode(mark))
      let metrics = try JSONSerialization.jsonObject(with: JSONEncoder().encode(pixels))
      let sample: [String: Any] = [
        "checkpoint": key, "step": step, "elapsedMS": elapsedMS(since: started),
        "mark": metadata, "rasterMetrics": metrics, "rasterVerified": pixels.verified,
        "rasterFile": file, "rasterScale": raster.scale,
        "rasterLocalBounds": [
          raster.localBounds.minX, raster.localBounds.minY,
          raster.localBounds.width, raster.localBounds.height,
        ],
        "rasterPixels": [raster.image.width, raster.image.height],
        "rasterSource": "retained-own-view-model-layers",
        "presentationLayerSampleAvailable": mark.presentationOutlineAvailable,
        "entranceSettledRequired": requireSettled,
        "cursorFollowingPhysicalPointer": cursor.snapshot.following,
        "manualContinueEventCount": eventCount("guidance.manualContinue.requested"),
        "localOwnViewOnly": true, "windowServerDesktopVisibilityVerified": false,
        "underlyingScreenPixelsSaved": false,
      ]
      guard
        let png = NSBitmapImageRep(cgImage: raster.image).representation(
          using: .png, properties: [:]),
        png.count <= 12 * 1_024 * 1_024
      else { throw ProviderError.message("The bounded own-mark PNG could not be encoded.") }
      try png.write(to: output.appendingPathComponent(file), options: .atomic)
      try writeJSON(sample, to: output.appendingPathComponent("mark-\(key).json"))
      markSamples.append(sample)
      guard pixels.verified else {
        throw ProviderError.message(
          "The own-view annotation raster did not contain its grounded outline.")
      }
      // Synchronous local rendering cannot yield to another generation. Check
      // both capture scope and the retained owner again before accepting proof.
      try checkFixture()
      guard generation == model.taskGeneration,
        model.overlay.presentationDiagnostics.contains(where: {
          $0.id == mark.id && $0.ownerGeneration == generation && $0.panelVisible
        })
      else {
        throw ProviderError.message("The native mark changed during its own-view observation.")
      }
      markIDs[step] = mark.id
      sampledCheckpoints.insert(key)
      try marker(
        "GUIDANCE_MANUAL_MARK_STEP\(step)_\(checkpoint.uppercased().replacingOccurrences(of: "-", with: "_"))"
      )
    }
    func sampleReturnedCursors() throws {
      for step in [0, 1] {
        let key = "step\(step)-after-cursor-return"
        guard !sampledCheckpoints.contains(key), stages[step] != nil,
          let generation = acceptedGenerations[step], generation == model.taskGeneration,
          cursor.snapshot.following,
          recentEvents().contains(where: {
            $0["event"] == "cursor.guidance.invalidated"
              && $0["generation"] == String(generation)
          })
        else { continue }
        try sampleMark(step: step, checkpoint: "after-cursor-return", requireSettled: true)
      }
    }
    defer {
      // JSON contains identifiers, geometry and counts, not prompt/transcript,
      // OCR or capture pixels. The opt-in PNGs render only these public own-mark
      // layers; the fixture/desktop screenshot and user library are never saved.
      let taskMetadata: Any
      if let taskReceipt,
        let data = try? JSONEncoder().encode(taskReceipt),
        let object = try? JSONSerialization.jsonObject(with: data)
      {
        taskMetadata = object
      } else {
        taskMetadata = NSNull()
      }
      let result: [String: Any] = [
        "result": passed ? "passed" : "failed", "failureCode": passed ? "" : failureCode,
        "lastPhase": phase.rawValue, "preflight": checks,
        "publicFixtureOnly": true, "actualCapturePath": "AppModel/CaptureService",
        "actualCaptureVerified": frames.count == 2
          && (!verifyTaskCompletion || taskReceipt?.fixturePostconditionVerified == true),
        "verifiedCaptureCount": frames.count + (taskReceipt == nil ? 0 : 1),
        "stages": stages.keys.sorted().compactMap { stages[$0] },
        "nativeMarkSamples": markSamples,
        "nativeMarkCheckpointCount": sampledCheckpoints.count,
        "persistentNativeMarkVerified": sampledCheckpoints.contains("step0-after-cursor-return")
          && sampledCheckpoints.contains("step0-before-continue"),
        "nativeAnnotationRasterScope": "retained-own-view-model-layers-only",
        "windowServerDesktopVisibilityVerified": false,
        "captureAcceptedEventCount": eventCount("guidance.capture.accepted"),
        "manualContinuationArmedCount": eventCount("guidance.manualContinuation.armed"),
        "manualContinueRequestedCount": eventCount("guidance.manualContinue.requested"),
        "clickObservedCount": eventCount("guidance.userClick.observed"),
        "nativeContinueRequestedFreshCheck": eventCount("guidance.manualContinue.requested") > 0,
        "providerReportedError": model.error != nil,
        "guidanceProviderStatus": String(model.guidanceProviderStatus.prefix(200)),
        "notebookUnchanged": model.scene == originalScene,
        "automaticDesktopActions": false, "microphoneUsed": false, "audioUsed": false,
        "checkboxActionPerformedByHelper": false,
        "checkboxCompletionVerified": taskReceipt?.fixturePostconditionVerified ?? false,
        "taskPostconditionRequired": verifyTaskCompletion, "taskCompletion": taskMetadata,
        "fixtureStateFailureCode": fixtureStateFailure ?? "",
        "taskComplete": passed && taskReceipt?.taskComplete == true,
        "endState": passed
          ? (verifyTaskCompletion ? "fixture-task-verified" : "ready-for-checkbox-click")
          : "failed-check",
        "elapsedMS": elapsedMS(since: started),
        "fixtureDisplayPoints": displayPoints,
      ]
      try? writeJSON(
        result, to: output.appendingPathComponent("manual-guidance-live-acceptance.json"))
      try? writeJSON(
        [
          "events": recentEvents(), "state": model.state, "busy": model.busy,
          "generation": model.taskGeneration, "providerReportedError": model.error != nil,
        ],
        to: output.appendingPathComponent("manual-guidance-diagnostics.json"))
      model.onScreenGuidanceTargetAccepted = productionTargetObserver
      model.onPrepareScreenGuidance = oldPreparation
      coordinator.onManualContinueWillBegin = oldBeforeContinue
      model.stop()
      cursor.shutdown()
      model.providerMode = oldProvider
      model.configuration.speechEnabled = oldSpeech
      model.guidanceModelPreference = oldGuidancePreference
      model.selectedDisplay = oldDisplay
    }
    model.providerMode = "ChatGPT via Codex"
    model.configuration.speechEnabled = false
    model.guidanceModelPreference = .terra
    model.selectedDisplay = displayID
    model.onPrepareScreenGuidance = { generation, expectedPID in
      try checkFixture()
      guard expectedPID == pid else {
        throw ProviderError.message("The acceptance turn requested an unrelated foreground app.")
      }
      try await oldPreparation?(generation, expectedPID)
      try checkFixture()
      do {
        try await taskVerifier?.prepareCapture(generation: generation)
      } catch let error as GuidanceFixtureStateAcceptance.Failure {
        // This closed enum contains only cases and the two authored control IDs;
        // no Accessibility attribute contents or system error strings escape.
        fixtureStateFailure = String(describing: error)
        throw error
      } catch let error as GuidanceFixtureTaskAcceptance.Failure {
        fixtureStateFailure = error.rawValue
        throw error
      }
      try checkFixture()
    }
    coordinator.onManualContinueWillBegin = { step in
      oldBeforeContinue?(step)
      guard rejection == nil else { return }
      do {
        try checkFixture()
        guard step.request.step == 0, step.request.id == requestID,
          coordinator.manualStep?.id == step.id, step.generation == model.taskGeneration,
          step.evidence.matches(frames[0]), eventCount("guidance.manualContinue.requested") == 0,
          ProcessInfo.processInfo.systemUptime < step.expiresAt
        else { throw ProviderError.message("The pre-Continue observation lost its manual lease.") }
        try sampleReturnedCursors()
        guard sampledCheckpoints.contains("step0-after-cursor-return") else {
          throw ProviderError.message(
            "Continue preceded the requested post-cursor mark observation.")
        }
        try sampleMark(step: 0, checkpoint: "before-continue", requireSettled: true)
      } catch { rejection = error.localizedDescription }
    }
    model.onScreenGuidanceTargetAccepted = { target, evidence, generation, request in
      guard rejection == nil else { return }
      do {
        try checkFixture()
        guard evidence.foregroundPID == pid, evidence.displayID == displayID,
          evidence.windowID == nil, evidence.screenRect == screen.frame,
          ScreenEvidenceIdentity(evidence).matches(model.evidence),
          generation == model.taskGeneration,
          eventCount("guidance.capture.accepted") > 0
        else {
          throw ProviderError.message("The accepted target did not own the public display capture.")
        }
        let pixels = try verifiedImageDimensions(evidence)
        let visibleLabels = evidence.groundingCandidates.filter { $0.source == .ocr }.map {
          normalizedText($0.label)
        }
        guard visibleLabels.contains(where: { $0.contains("tablename") }),
          visibleLabels.contains(where: { $0.contains("protectdata") })
        else {
          throw ProviderError.message(
            "The public table-settings form was not visible in the captured frame.")
        }
        let containsInput = evidence.groundingCandidates.contains {
          $0.source == .ocr && normalizedText($0.label).contains("releaseqa")
        }
        switch request.step {
        case 0:
          if let requestID, requestID != request.id {
            throw ProviderError.message("The guidance request changed before manual continuation.")
          }
          if stages[0] != nil {
            // Production permits supporting, non-awaiting annotations after
            // its one primary manual step. They cannot establish that primary
            // or replace it with a second advancing instruction.
            guard target.advanceOn != "click", target.awaitUser != true else {
              throw ProviderError.message("The first stage emitted a second advancing target.")
            }
            productionTargetObserver(target, evidence, generation, request)
            return
          }
          guard target.advanceOn == "manual", target.awaitUser == true,
            !containsInput,
            grounded(
              target, in: fieldRect(displaySize: screen.frame.size), displaySize: screen.frame.size)
          else {
            throw ProviderError.message(
              "The first step was not a grounded, waiting manual field step.")
          }
          requestID = request.id
        case 1:
          // Secondary explanatory marks do not substitute for the next click.
          guard target.advanceOn == "click" else {
            productionTargetObserver(target, evidence, generation, request)
            return
          }
          guard requestID == request.id, let source = frames[0],
            source.frameID != evidence.frameID, source.revision < evidence.revision,
            source.capturedAt < evidence.capturedAt, containsInput,
            eventCount("guidance.manualContinue.requested") == 1,
            eventCount("guidance.capture.accepted") >= 2,
            eventCount("guidance.userClick.observed") == 0,
            groundedProtection(target, displaySize: screen.frame.size)
          else {
            throw ProviderError.message(
              "Continue did not produce a fresh, grounded checkbox step after visible typing.")
          }
        default:
          throw ProviderError.message("The acceptance advanced beyond the requested two stages.")
        }
        productionTargetObserver(target, evidence, generation, request)
        guard stages[request.step] == nil else { return }
        if request.step == 0 {
          guard eventCount("guidance.manualContinuation.armed") > 0,
            NSApp.windows.contains(where: {
              $0.identifier?.rawValue == "org.opencompanion.guidance.manual" && $0.isVisible
            })
          else {
            throw ProviderError.message("The native manual Continue controls were not presented.")
          }
        }
        let stage: [String: Any] = [
          "step": request.step, "generation": generation, "requestID": request.id.uuidString,
          "frameID": evidence.frameID.uuidString, "revision": evidence.revision,
          "foregroundIsFixture": true, "fullDisplayFixtureGatePassed": true,
          "actualCaptureHeaderVerified": true, "imagePixels": [pixels.width, pixels.height],
          "advanceOn": target.advanceOn ?? "manual", "awaitUser": target.awaitUser ?? false,
          "x": target.x, "y": target.y, "width": target.width, "height": target.height,
          "shape": target.shape ?? "roundedRectangle",
          "labelCharacterCount": target.label?.count ?? 0,
          "instructionCharacterCount": target.instruction.count,
          "manualInputVisibleInCapture": containsInput,
          "nativeContinueControlsVisible": request.step == 0,
          "readyAtMS": elapsedMS(since: started),
        ]
        frames[request.step] = evidence
        acceptedTargets[request.step] = target
        acceptedGenerations[request.step] = generation
        try sampleMark(step: request.step, checkpoint: "initial", requireSettled: false)
        stages[request.step] = stage
        try writeJSON(stage, to: output.appendingPathComponent("step\(request.step)-ready.json"))
        reportObservedPhase()
        try marker("GUIDANCE_MANUAL_STEP\(request.step)_READY")
      } catch {
        rejection = error.localizedDescription
      }
    }
    reportPhase(.preparingInitialCapture)
    cursor.pointerMoved(to: CGPoint(x: screen.frame.midX - 160, y: screen.frame.midY))
    model.beginScreenGuidance(
      "Guide me through typing Release QA into the visible Table name field, then turning off Protect data.",
      speakAloud: false)
    let initialGeneration = model.taskGeneration
    let deadline = started + 120
    while stages[1] == nil {
      try Task.checkCancellation()
      reportObservedPhase()
      if let fixtureStateFailure {
        failureCode = "fixture-state-\(fixtureStateFailure)"
        throw ProviderError.message(
          "Public fixture state verification refused: \(fixtureStateFailure).")
      }
      do { try sampleReturnedCursors() } catch {
        failureCode = "native-mark-after-cursor-return"
        throw error
      }
      if let rejection {
        failureCode = "target-or-continuation-validation"
        throw ProviderError.message(rejection)
      }
      guard model.error == nil else {
        failureCode = "production-turn-error"
        throw ProviderError.message("The production guidance turn reported an error.")
      }
      guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
        screen.frame.contains(NSEvent.mouseLocation), !fixture.isTerminated
      else {
        failureCode = "fixture-foreground-lost"
        throw ProviderError.message(
          "The public fixture must remain foreground for this acceptance.")
      }
      guard
        model.taskGeneration == initialGeneration
          || eventCount("guidance.manualContinue.requested") == 1
            && model.taskGeneration == initialGeneration + 2
      else {
        failureCode = "generation-cancelled-or-replaced"
        throw CancellationError()
      }
      guard ProcessInfo.processInfo.systemUptime < deadline else {
        failureCode = stages[0] == nil ? "manual-step-timeout" : "continue-or-next-target-timeout"
        throw ProviderError.message(
          "The manual guidance acceptance exceeded its 120-second deadline.")
      }
      try await Task.sleep(for: .milliseconds(100))
    }
    reportObservedPhase()
    if let rejection {
      failureCode = "target-or-continuation-validation"
      throw ProviderError.message(rejection)
    }
    try checkFixture()
    guard model.scene == originalScene, eventCount("visual.accepted") == 0 else {
      failureCode = "unexpected-notebook-mutation"
      throw ProviderError.message("Screen guidance unexpectedly changed a notebook.")
    }
    // Observe the next mark before the two-step check ends or the separate task
    // check invites the real checkbox action. This never performs that action.
    let observationEnds = ProcessInfo.processInfo.systemUptime + 2
    while ProcessInfo.processInfo.systemUptime < observationEnds {
      try await Task.sleep(for: .milliseconds(100))
      try sampleReturnedCursors()
    }
    try checkFixture()
    guard rejection == nil, model.error == nil,
      model.taskGeneration == initialGeneration + 2, model.scene == originalScene,
      eventCount("visual.accepted") == 0, eventCount("guidance.userClick.observed") == 0
    else {
      failureCode = "next-target-invalidated-before-completion"
      throw ProviderError.message(
        "The next checkbox target changed before the acceptance could finish.")
    }
    guard
      sampledCheckpoints
        == Set([
          "step0-initial", "step0-after-cursor-return", "step0-before-continue",
          "step1-initial", "step1-after-cursor-return",
        ])
    else {
      failureCode = "native-mark-checkpoints-incomplete"
      throw ProviderError.message("A required native annotation checkpoint was not observed.")
    }
    if verifyTaskCompletion {
      guard let taskVerifier, let previous = frames[1] else {
        failureCode = "task-verifier-or-source-missing"
        throw ProviderError.message("The required task verifier or second capture was missing.")
      }
      taskVerificationStarted = true
      reportObservedPhase()
      try marker("GUIDANCE_MANUAL_CHECKBOX_READY")
      failureCode = "task-postcondition-or-provider-validation"
      do {
        taskReceipt = try await taskVerifier.waitForCompletion(
          initialGeneration: initialGeneration, deadline: deadline,
          expectedPreviousEvidence: ScreenEvidenceIdentity(previous),
          onProgress: { reportObservedPhase() })
      } catch let error as GuidanceFixtureStateAcceptance.Failure {
        fixtureStateFailure = String(describing: error)
        failureCode = "fixture-state-\(fixtureStateFailure ?? "unknown")"
        throw error
      } catch let error as GuidanceFixtureTaskAcceptance.Failure {
        failureCode = "task-postcondition-\(error.rawValue)"
        throw error
      }
      reportPhase(.checkingTaskPostcondition)
      try checkFixture()
      guard rejection == nil, let taskReceipt, let first = frames[0],
        taskReceipt.finalFrameID != first.frameID,
        taskReceipt.finalEvidenceRevision > first.revision
      else {
        throw ProviderError.message("The final task check lost its accepted evidence.")
      }
      let data = try JSONEncoder().encode(taskReceipt)
      try data.write(to: output.appendingPathComponent("task-postcondition.json"), options: .atomic)
      try marker("GUIDANCE_MANUAL_TASK_POSTCONDITION_VERIFIED")
    }
    passed = true
  }

  /// CGRect intersection can recompute width/height by subtracting endpoints.
  /// Permit only arithmetic roundoff at display scale, far below one pixel;
  /// ownership, path bounds and independent raster checks remain separate.
  static func retainedTargetMatches(
    _ actual: CGRect, expected: CGRect, displaySize: CGSize
  ) -> Bool {
    let actualValues = [actual.origin.x, actual.origin.y, actual.size.width, actual.size.height]
    let expectedValues = [expected.origin.x, expected.origin.y, expected.size.width, expected.size.height]
    let values = actualValues + expectedValues + [displaySize.width, displaySize.height]
    guard values.allSatisfy({ $0.isFinite && abs($0) <= 100_000 }),
      actual.size.width > 0, actual.size.height > 0,
      expected.size.width > 0, expected.size.height > 0,
      displaySize.width > 0, displaySize.height > 0,
      displaySize.width <= 100_000, displaySize.height <= 100_000
    else { return false }
    let scale = max(displaySize.width, displaySize.height)
    let tolerance = max(1, scale).ulp * 8
    return zip(actualValues, expectedValues).allSatisfy { abs($0 - $1) <= tolerance }
  }

  /// Independent contour/alpha evidence for a local annotation bitmap. The
  /// expected target is supplied by the existing public-fixture oracle; this
  /// never samples the captured screenshot or reconstructs a replacement mark.
  static func annotationRasterMetrics(
    _ raster: GuidanceMarkRaster, expectedTarget target: CGRect, shape: String
  ) throws -> GuidanceMarkRasterMetrics {
    let image = raster.image
    guard
      [
        target.minX, target.minY, target.width, target.height,
        raster.localBounds.minX, raster.localBounds.minY,
        raster.localBounds.width, raster.localBounds.height,
      ].allSatisfy({ $0.isFinite }),
      target.width > 0, target.height > 0, raster.localBounds.contains(target),
      raster.scale.isFinite, raster.scale >= 1, raster.scale <= 2,
      image.width > 0, image.height > 0, image.width <= 8_192, image.height <= 8_192,
      image.width * image.height <= 2_000_000,
      image.bitsPerComponent == 8, image.bitsPerPixel == 32,
      image.alphaInfo == .premultipliedLast,
      image.bitmapInfo.contains(.byteOrder32Big),
      image.bytesPerRow >= image.width * 4, image.bytesPerRow <= image.width * 4 + 4_096,
      abs(Double(image.width) - raster.localBounds.width * raster.scale) <= 1,
      abs(Double(image.height) - raster.localBounds.height * raster.scale) <= 1,
      let provider = image.dataProvider, let raw = provider.data,
      CFDataGetLength(raw) >= image.bytesPerRow * image.height,
      let bytes = CFDataGetBytePtr(raw), ["roundedRectangle", "ellipse"].contains(shape)
    else {
      throw ProviderError.message("The own-mark raster format or target geometry was invalid.")
    }
    let scope = target.insetBy(dx: -7, dy: -7)
    var onContour = 0
    var offContour = 0
    var sides = [0, 0, 0, 0]
    for row in 0..<image.height {
      for column in 0..<image.width {
        let offset = row * image.bytesPerRow + column * 4
        let r = Int(bytes[offset])
        let g = Int(bytes[offset + 1])
        let b = Int(bytes[offset + 2])
        guard bytes[offset + 3] >= 140, r >= 140, r - g >= 70, r - b >= 60 else { continue }
        // CGImage's first bitmap row is the top row of the already-flipped
        // own-view render. Applying the CGContext flip again here would mirror
        // the mark around its asymmetric label-inclusive crop.
        let p = CGPoint(
          x: raster.localBounds.minX + (Double(column) + 0.5) / raster.scale,
          y: raster.localBounds.minY + (Double(row) + 0.5) / raster.scale)
        guard scope.contains(p) else { continue }
        let dx = abs(p.x - target.midX)
        let dy = abs(p.y - target.midY)
        let distance: Double
        if shape == "ellipse" {
          let rx = max(0.25, target.width / 2 - 2)
          let ry = max(0.25, target.height / 2 - 2)
          distance = abs(hypot(dx / rx, dy / ry) - 1) * min(rx, ry)
        } else {
          let radius = min(8, target.width / 2, target.height / 2)
          let qx = dx - (target.width / 2 - radius)
          let qy = dy - (target.height / 2 - radius)
          distance = abs(hypot(max(qx, 0), max(qy, 0)) + min(max(qx, qy), 0) - radius)
        }
        guard distance <= 3.5 + 1 / raster.scale else {
          offContour += 1
          continue
        }
        onContour += 1
        let side: Int
        if dx / target.width >= dy / target.height {
          side = p.x < target.midX ? 0 : 1
        } else {
          side = p.y < target.midY ? 2 : 3
        }
        sides[side] += 1
      }
    }
    return GuidanceMarkRasterMetrics(
      opaqueOutlinePixels: onContour, offContourPixels: offContour, sidePixels: sides,
      minimumOutlinePixels: Int(min(48, max(12, (target.width + target.height) * 0.1))))
  }

  private static func elapsedMS(since started: TimeInterval) -> Double {
    let value = (ProcessInfo.processInfo.systemUptime - started) * 1_000
    return value.isFinite ? max(0, value) : 0
  }

  private static func marker(_ value: String) throws {
    try FileHandle.standardOutput.write(contentsOf: Data((value + "\n").utf8))
  }

  private static func normalizedText(_ text: String) -> String {
    text.lowercased().filter { $0.isLetter || $0.isNumber }
  }

  private static func fieldRect(displaySize size: CGSize) -> CGRect {
    let width = min(620, max(240, size.width - 96))
    return CGRect(
      x: max(32, size.width * 0.4 - width / 2), y: size.height * 0.45 + 20,
      width: min(width, 420), height: 34)
  }

  private static func grounded(
    _ target: ProviderTarget, in expected: CGRect, displaySize size: CGSize
  ) -> Bool {
    guard target.x.isFinite, target.y.isFinite, target.width.isFinite, target.height.isFinite,
      target.x >= 0, target.y >= 0, target.width > 0, target.height > 0,
      target.x + target.width <= 1, target.y + target.height <= 1
    else { return false }
    let rect = CGRect(
      x: target.x * size.width, y: target.y * size.height,
      width: target.width * size.width, height: target.height * size.height)
    return expected.insetBy(dx: -20, dy: -12).contains(rect)
      && rect.contains(CGPoint(x: expected.midX, y: expected.midY))
      && rect.width >= expected.width * 0.4 && rect.height >= expected.height * 0.4
  }

  private static func groundedProtection(_ target: ProviderTarget, displaySize size: CGSize) -> Bool
  {
    let field = fieldRect(displaySize: size)
    let control = CGRect(x: field.minX, y: size.height * 0.45 + 75, width: 240, height: 30)
    let rect = CGRect(
      x: target.x * size.width, y: target.y * size.height,
      width: target.width * size.width, height: target.height * size.height)
    guard rect.origin.x.isFinite, rect.origin.y.isFinite, rect.size.width.isFinite,
      rect.size.height.isFinite,
      rect.size.width >= 8, rect.size.height >= 8,
      control.insetBy(dx: -12, dy: -12).contains(rect)
    else { return false }
    // The leading checkbox and its text are both actionable parts of this one
    // known public NSButton. Do not require the center of its blank trailing area.
    return rect.contains(CGPoint(x: control.minX + 9, y: control.midY))
      || rect.contains(CGPoint(x: control.minX + 78, y: control.midY))
  }

  private static func verifiedImageDimensions(_ evidence: ScreenEvidence) throws -> (
    width: Int, height: Int
  ) {
    guard evidence.image.count <= 12 * 1_024 * 1_024,
      let source = CGImageSourceCreateWithData(evidence.image as CFData, nil),
      CGImageSourceGetCount(source) == 1,
      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
      let width = properties[kCGImagePropertyPixelWidth] as? Int,
      let height = properties[kCGImagePropertyPixelHeight] as? Int,
      width > 0, height > 0, width <= 8_192, height <= 8_192,
      width == evidence.imageWidth, height == evidence.imageHeight,
      (properties[kCGImagePropertyOrientation] as? Int ?? 1) == 1
    else {
      throw ProviderError.message(
        "The production capture header did not match its evidence dimensions.")
    }
    return (width, height)
  }

  private static func writeJSON(_ value: [String: Any], to url: URL) throws {
    try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
      .write(to: url, options: .atomic)
  }

  @MainActor private static func fixtureCoversDisplay(pid: pid_t, screen: NSScreen) -> Bool {
    guard
      let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID)
        as? [[String: Any]],
      let primary = NSScreen.screens.first
    else { return false }
    let display = CGRect(
      x: screen.frame.minX, y: primary.frame.maxY - screen.frame.maxY,
      width: screen.frame.width, height: screen.frame.height)
    return windows.contains { window in
      guard (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
        (window[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
        (window[kCGWindowAlpha as String] as? NSNumber)?.doubleValue == 1,
        let bounds = window[kCGWindowBounds as String] as? [String: Any],
        let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary)
      else { return false }
      return rect.contains(display)
    }
  }
}
