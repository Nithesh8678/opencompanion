import AppKit
import ImageIO

/// Opt-in production capture/model/Continue check against the opaque public
/// Guidance Fixture only. This helper never types, clicks or records audio.
enum ManualGuidanceLiveAcceptance {
  @MainActor static func run(
    model: AppModel, cursor: CursorCompanionCoordinator, output: URL
  ) async throws {
    try Task.checkCancellation()
    // The UI driver can invoke a background app's AX controls without making
    // that app foreground. Wait for a real user focus change; never activate an
    // app or capture unrelated content to make this acceptance pass.
    try FileHandle.standardOutput.write(
      contentsOf: Data("GUIDANCE_MANUAL_WAITING_FOR_PUBLIC_FIXTURE\n".utf8))
    let foregroundDeadline = ProcessInfo.processInfo.systemUptime + 90
    while NSWorkspace.shared.frontmostApplication?.bundleIdentifier
      != "org.opencompanion.fixture.guidance"
    {
      try Task.checkCancellation()
      guard ProcessInfo.processInfo.systemUptime < foregroundDeadline else {
        throw ProviderError.message(
          "Manual guidance startup: the public Guidance Fixture did not become foreground within 90 seconds."
        )
      }
      try await Task.sleep(for: .milliseconds(100))
    }
    guard let fixture = NSWorkspace.shared.frontmostApplication,
      fixture.bundleIdentifier == "org.opencompanion.fixture.guidance"
    else {
      throw ProviderError.message(
        "Manual guidance startup: the public Guidance Fixture must be foreground.")
    }
    guard let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }),
      let displayNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
        as? NSNumber
    else {
      throw ProviderError.message(
        "Manual guidance startup: the pointer must be on a display with valid native display geometry."
      )
    }
    guard fixtureCoversDisplay(pid: fixture.processIdentifier, screen: screen) else {
      throw ProviderError.message(
        "Manual guidance startup: the public Guidance Fixture must cover the pointer display.")
    }
    guard let productionTargetObserver = model.onScreenGuidanceTargetAccepted
    else {
      throw ProviderError.message(
        "Manual guidance startup: the production guidance target observer is not installed."
      )
    }
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    let displayID = displayNumber.uint32Value
    let pid = fixture.processIdentifier
    let started = ProcessInfo.processInfo.systemUptime
    let traceStart = model.diagnosticEvents.count
    let oldPreparation = model.onPrepareScreenGuidance
    let oldProvider = model.providerMode
    let oldSpeech = model.configuration.speechEnabled
    let oldGuidancePreference = model.guidanceModelPreference
    let oldDisplay = model.selectedDisplay
    let originalScene = model.scene
    var frames: [Int: ScreenEvidence] = [:]
    var stages: [Int: [String: Any]] = [:]
    var requestID: UUID?
    var rejection: String?
    var failureCode = "incomplete"
    var passed = false

    func recentEvents() -> [[String: String]] {
      Array(model.diagnosticEvents.dropFirst(traceStart).suffix(2_000))
    }
    func eventCount(_ name: String) -> Int {
      recentEvents().filter { $0["event"] == name }.count
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
    defer {
      // Diagnostics contain event identifiers, geometry and counts only. Never
      // serialize a prompt, transcript, OCR labels, screenshot or user library.
      let result: [String: Any] = [
        "result": passed ? "passed" : "failed", "failureCode": passed ? "" : failureCode,
        "publicFixtureOnly": true, "actualCapturePath": "AppModel/CaptureService",
        "actualCaptureVerified": frames.count == 2,
        "stages": stages.keys.sorted().compactMap { stages[$0] },
        "captureAcceptedEventCount": eventCount("guidance.capture.accepted"),
        "manualContinuationArmedCount": eventCount("guidance.manualContinuation.armed"),
        "manualContinueRequestedCount": eventCount("guidance.manualContinue.requested"),
        "clickObservedCount": eventCount("guidance.userClick.observed"),
        "nativeContinueRequestedFreshCheck": eventCount("guidance.manualContinue.requested") > 0,
        "providerReportedError": model.error != nil,
        "guidanceProviderStatus": String(model.guidanceProviderStatus.prefix(200)),
        "notebookUnchanged": model.scene == originalScene,
        "automaticDesktopActions": false, "microphoneUsed": false, "audioUsed": false,
        "checkboxActionPerformedByHelper": false, "checkboxCompletionVerified": false,
        "taskComplete": false, "endState": passed ? "ready-for-checkbox-click" : "failed-check",
        "elapsedMS": (ProcessInfo.processInfo.systemUptime - started) * 1_000,
        "fixtureDisplayPoints": [screen.frame.width, screen.frame.height],
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
          "readyAtMS": (ProcessInfo.processInfo.systemUptime - started) * 1_000,
        ]
        frames[request.step] = evidence
        stages[request.step] = stage
        try writeJSON(stage, to: output.appendingPathComponent("step\(request.step)-ready.json"))
        try FileHandle.standardOutput.write(
          contentsOf: Data("GUIDANCE_MANUAL_STEP\(request.step)_READY\n".utf8))
      } catch {
        rejection = error.localizedDescription
      }
    }
    cursor.pointerMoved(to: CGPoint(x: screen.frame.midX - 160, y: screen.frame.midY))
    model.beginScreenGuidance(
      "Guide me through typing Release QA into the visible Table name field, then turning off Protect data.",
      speakAloud: false)
    let initialGeneration = model.taskGeneration
    let deadline = started + 120
    while stages[1] == nil {
      try Task.checkCancellation()
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
    if let rejection {
      failureCode = "target-or-continuation-validation"
      throw ProviderError.message(rejection)
    }
    try checkFixture()
    guard model.scene == originalScene, eventCount("visual.accepted") == 0 else {
      failureCode = "unexpected-notebook-mutation"
      throw ProviderError.message("Screen guidance unexpectedly changed a notebook.")
    }
    // Leave a bounded observation interval for the next native mark; no click
    // or checkbox-completion claim is made. Cleanup then stops the whole turn.
    try await Task.sleep(for: .seconds(2))
    try checkFixture()
    guard rejection == nil, model.error == nil,
      model.taskGeneration == initialGeneration + 2, model.scene == originalScene,
      eventCount("visual.accepted") == 0, eventCount("guidance.userClick.observed") == 0
    else {
      failureCode = "next-target-invalidated-before-completion"
      throw ProviderError.message(
        "The next checkbox target changed before the acceptance could finish.")
    }
    passed = true
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
