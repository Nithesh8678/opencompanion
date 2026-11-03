import AppKit
import QuartzCore
@preconcurrency import ScreenCaptureKit

/// Isolated native acceptance. Synthetic locations drive this app's own panel;
/// it never injects system input, records audio, or sends private screen content.
enum CursorCompanionAcceptance {
  @MainActor static func run(
    cursor: CursorCompanionCoordinator, shell: CompanionShell, model: AppModel, output: URL
  ) async throws {
    guard !cursor.observesPointer, !shell.observesPointer, let screen = NSScreen.main else {
      throw Failure.message("Cursor acceptance requires isolated pointer observation.")
    }
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    let originalSpeechEnabled = model.configuration.speechEnabled
    model.configuration.speechEnabled = false
    defer {
      model.stop()
      model.configuration.speechEnabled = originalSpeechEnabled
      cursor.shutdown()
    }
    let foreground = NSWorkspace.shared.frontmostApplication?.processIdentifier
    let display = screen.frame
    let first = CGPoint(x: display.midX - 190, y: display.midY + 100)
    cursor.pointerMoved(to: first)
    try await Task.sleep(for: .milliseconds(400))
    let idle = cursor.snapshot
    try JSONEncoder().encode(idle).write(to: output.appendingPathComponent("cursor-initial.json"))
    try require(
      idle.visible && idle.ignoresMouseEvents && !idle.canBecomeKey,
      "Cursor must be visible, click-through, and unable to become key.")
    try require(!idle.displayLinkRunning, "A settled idle cursor kept its display clock running.")
    try require(
      abs(idle.bodyCenter.x - first.x - 17) < 1 && abs(idle.bodyCenter.y - first.y + 22) < 1,
      "Follower did not settle at the expected logical-point offset.")
    try await cursor.exportSnapshot(to: output.appendingPathComponent("cursor-idle.png"))

    // A real mounted layer tree, changing its pose at display cadence. Retarget
    // before settling, including a reversal, rather than snapshotting a mock.
    for index in 0..<24 {
      let fraction = Double(index) / 23
      let point = CGPoint(
        x: display.midX + sin(fraction * .pi * 2) * 180,
        y: display.midY + cos(fraction * .pi * 2) * 100)
      cursor.pointerMoved(to: point)
      try await Task.sleep(for: .milliseconds(17))
      try require(
        cursor.snapshot.frame.origin.x.isFinite && cursor.snapshot.frame.origin.y.isFinite,
        "Follower produced a nonfinite native frame while reversing.")
    }
    cursor.pointerMoved(to: first)
    try await Task.sleep(for: .milliseconds(450))
    try require(!cursor.snapshot.displayLinkRunning, "Idle clock failed to stop after retargeting.")

    model.stop()
    model.listening = true
    model.voiceInputState = "Preparing microphone"
    model.state = "Preparing microphone"
    cursor.beginInput(generation: model.taskGeneration)
    try await Task.sleep(for: .milliseconds(60))
    try require(
      cursor.snapshot.phase == "preparing" && cursor.snapshot.text.isEmpty,
      "Fresh microphone preparation inherited old response content.")
    try await cursor.exportSnapshot(to: output.appendingPathComponent("cursor-preparing.png"))
    model.voiceInputState = "Listening"
    model.state = "Listening"
    try await Task.sleep(for: .milliseconds(100))
    try require(
      cursor.snapshot.phase == "listening" && cursor.snapshot.text.isEmpty,
      "Listening was not the first active input phase.")
    try await cursor.exportSnapshot(to: output.appendingPathComponent("cursor-listening.png"))

    model.stop()
    let response = model.taskGeneration
    model.busy = true
    model.state = "Thinking"
    cursor.beginResponse(generation: response)
    try await Task.sleep(for: .milliseconds(100))
    try await cursor.exportSnapshot(to: output.appendingPathComponent("cursor-thinking.png"))
    let originalMessages = model.messages.count
    let began = ProcessInfo.processInfo.systemUptime
    cursor.accept(
      ProviderTextPreview(unitID: 0, text: "delt", isComplete: false), generation: response)
    try await Task.sleep(for: .milliseconds(115))
    try require(
      cursor.snapshot.text.isEmpty && !cursor.snapshot.displayLinkRunning,
      "An unfinished word revealed a fragment or kept its display clock running.")
    try require(model.messages.count == originalMessages, "Inert preview mutated canonical Chat.")
    try await cursor.exportSnapshot(
      to: output.appendingPathComponent("cursor-fragment-waiting.png"))
    cursor.accept(
      ProviderTextPreview(unitID: 0, text: "deltoid ", isComplete: false), generation: response)
    let firstWordDeadline = ProcessInfo.processInfo.systemUptime + 1.5
    while cursor.snapshot.text.isEmpty && ProcessInfo.processInfo.systemUptime < firstWordDeadline {
      try await Task.sleep(for: .milliseconds(25))
    }
    try require(
      cursor.snapshot.text == "deltoid", "A completed word boundary did not reveal one whole word.")
    try require(model.messages.count == originalMessages, "Word preview mutated canonical Chat.")
    let firstObservedWordMS = (ProcessInfo.processInfo.systemUptime - began) * 1_000
    try await cursor.exportSnapshot(to: output.appendingPathComponent("cursor-prefix.png"))
    let completeCaption = "deltoid muscle."
    cursor.accept(
      ProviderTextPreview(unitID: 0, text: completeCaption, isComplete: true), generation: response)
    let completedUnit = try JSONDecoder().decode(
      ProviderUnit.self, from: Data(#"{"type":"text","text":"deltoid muscle."}"#.utf8))
    try model.accept(completedUnit, generation: response, expectedEvidence: nil)
    try await Task.sleep(for: .milliseconds(450))
    try require(
      cursor.snapshot.text == completeCaption, "Complete caption did not finish in order.")
    try require(
      model.messages.count == originalMessages + 1 && model.messages.last?.text == completeCaption,
      "The completed validated text unit did not commit exactly once to canonical Chat.")
    try await cursor.exportSnapshot(to: output.appendingPathComponent("cursor-caption.png"))
    model.busy = false
    model.state = "Ready"
    try await Task.sleep(for: .milliseconds(100))
    try require(
      cursor.snapshot.phase == "idle" && cursor.snapshot.text == completeCaption,
      "Completed caption disappeared before its reading hold.")
    try await cursor.exportSnapshot(to: output.appendingPathComponent("cursor-completed-hold.png"))

    // Interrupt directly from a visible reply. No idle frame is required to
    // clear the prior text or work-in-progress indicators before the new hold.
    model.stop()
    let inputGeneration = model.taskGeneration
    model.listening = true
    model.voiceInputState = "Preparing microphone"
    model.state = "Preparing microphone"
    cursor.beginInput(generation: inputGeneration)
    cursor.accept(
      ProviderTextPreview(unitID: 1, text: "STALE", isComplete: true), generation: response)
    try require(
      cursor.snapshot.text.isEmpty && cursor.snapshot.phase == "preparing",
      "An old response revived during a new input hold.")
    model.voiceInputState = "Listening"
    model.state = "Listening"
    try await Task.sleep(for: .milliseconds(100))
    try await cursor.exportSnapshot(
      to: output.appendingPathComponent("cursor-restarted-listening.png"))
    try require(shell.geometry.surface == "tucked", "Cursor feedback expanded the notch dashboard.")

    // Reduce Motion bypasses travel/reveal, including long Unicode captions.
    model.stop()
    model.busy = true
    model.state = "Thinking"
    cursor.setReduceMotionForAcceptance(true)
    cursor.beginResponse(generation: model.taskGeneration)
    let long = String(repeating: "Clear guidance 👨‍👩‍👧‍👦. ", count: 40)
    cursor.accept(
      ProviderTextPreview(unitID: 0, text: long, isComplete: true), generation: model.taskGeneration
    )
    try await Task.sleep(for: .milliseconds(80))
    try require(
      cursor.snapshot.text == CursorCompanionCoordinator.captionWindow(long),
      "Reduce Motion did not reveal the bounded Unicode caption immediately.")
    try await cursor.exportSnapshot(
      to: output.appendingPathComponent("cursor-long-reduced-motion.png"))
    cursor.setReduceMotionForAcceptance(false)

    // Use the same validated target entry point as real provider output. The
    // fixture is explicit, has no captured pixels, and cannot click anything.
    model.stop()
    model.busy = true
    model.state = "Thinking"
    cursor.beginResponse(generation: model.taskGeneration, isGuidance: true)
    let fixture = ScreenEvidence(
      frameID: UUID(), revision: 1, capturedAt: ProcessInfo.processInfo.systemUptime,
      displayID: (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?
        .uint32Value ?? 0,
      foregroundPID: foreground ?? 0, foregroundName: "Acceptance fixture", screenRect: display,
      image: Data(), semanticText: "")
    model.evidence = fixture
    let unit = try JSONDecoder().decode(
      ProviderUnit.self,
      from: Data(
        #"{"type":"target","target":{"x":0.65,"y":0.43,"width":0.08,"height":0.06,"instruction":"Open this control","label":"Open this control","shape":"roundedRectangle","advanceOn":"manual"}}"#
          .utf8))
    try model.accept(
      unit, generation: model.taskGeneration, expectedEvidence: ScreenEvidenceIdentity(fixture))
    try await Task.sleep(for: .milliseconds(180))
    try require(!cursor.snapshot.following, "Validated target did not acquire guidance ownership.")
    cursor.accept(
      ProviderTextPreview(unitID: 1, text: "Narration after the target.", isComplete: true),
      generation: model.taskGeneration)
    try require(!cursor.snapshot.following, "Narration interrupted independent guidance ownership.")
    try await cursor.exportSnapshot(to: output.appendingPathComponent("cursor-guidance-flight.png"))
    // Maximum .65s flight + .16s fade +17*.06s glyph steps, with enough
    // scheduling margin for the actual annotation layer to finish its mask.
    try await Task.sleep(for: .milliseconds(2_100))
    try require(
      cursor.snapshot.text.isEmpty, "Guidance duplicated its attached label in a cursor caption.")
    let annotation = try annotationPanel(label: "Open this control")
    let annotationText = try annotationTextLayer(in: annotation)
    try require(
      annotation.ignoresMouseEvents && !annotation.canBecomeKey,
      "Guidance annotation was interactive or able to steal keyboard focus.")
    try require(
      annotationText.mask?.animation(forKey: "guidance.labelReveal") == nil,
      "The attached guidance label had not completed its native glyph reveal.")
    try await exportAnnotationSnapshot(
      panel: annotation, to: output.appendingPathComponent("guidance-attached-label.png"))
    try await cursor.exportSnapshot(
      to: output.appendingPathComponent("cursor-guidance-caption.png"))
    // The writing flight deliberately returns to following after settling.
    // Acquire a fresh flight before testing invalidation, so an already expired
    // animation cannot make the evidence-change assertion pass vacuously.
    try model.accept(
      unit, generation: model.taskGeneration, expectedEvidence: ScreenEvidenceIdentity(fixture))
    try await Task.sleep(for: .milliseconds(25))
    try require(
      !cursor.snapshot.following, "A repeated validated target did not begin a new flight.")
    var replaced = fixture
    replaced.frameID = UUID()
    model.evidence = replaced
    try await Task.sleep(for: .milliseconds(80))
    try require(
      cursor.snapshot.following, "A newer evidence frame did not invalidate old guidance.")
    model.overlay.clear()
    NotificationCenter.default.post(
      name: NSApplication.didChangeScreenParametersNotification, object: nil)
    try require(
      model.evidence == nil,
      "Display rearrangement retained coordinate authority from an old capture.")
    var rejectedTopologyTarget = false
    do {
      try model.accept(
        unit, generation: model.taskGeneration, expectedEvidence: ScreenEvidenceIdentity(replaced))
    } catch { rejectedTopologyTarget = true }
    try require(
      rejectedTopologyTarget, "A late target reused coordinates after a display rearrangement.")

    let notch = shell.geometry.cutoutFrame ?? shell.geometry.frame
    cursor.pointerMoved(to: CGPoint(x: notch.midX, y: notch.midY))
    try await Task.sleep(for: .milliseconds(80))
    try require(!cursor.snapshot.visible, "Cursor obscured the notch surface.")
    cursor.pointerMoved(to: first)
    model.stop()
    try await Task.sleep(for: .milliseconds(450))
    try require(
      cursor.snapshot.visible && !cursor.snapshot.displayLinkRunning
        && cursor.snapshot.text.isEmpty,
      "Stopped response did not return to the quiet settled follower.")
    try require(
      NSApp.keyWindow == nil
        && NSWorkspace.shared.frontmostApplication?.processIdentifier == foreground,
      "Cursor presentation changed foreground focus.")
    model.busy = true
    model.state = "Thinking"
    cursor.beginResponse(generation: model.taskGeneration)
    cursor.accept(
      ProviderTextPreview(unitID: 0, text: "Done.", isComplete: true),
      generation: model.taskGeneration)
    try await Task.sleep(for: .milliseconds(250))
    model.busy = false
    model.state = "Ready"
    try await Task.sleep(for: .milliseconds(100))
    try require(
      !cursor.snapshot.displayLinkRunning && cursor.snapshot.text == "Done.",
      "A static reading hold kept the display clock running.")
    try await Task.sleep(for: .milliseconds(3_800))
    try require(
      cursor.snapshot.text.isEmpty && cursor.snapshot.phase == "idle"
        && !cursor.snapshot.displayLinkRunning,
      "The bounded reading hold did not fade back to the idle follower.")
    let statistics = cursor.snapshot
    try JSONEncoder().encode(statistics).write(
      to: output.appendingPathComponent("cursor-final.json"))
    let evidence: [String: Any] = [
      "result": "passed", "firstObservedWordMS": firstObservedWordMS,
      "wordObservationIncludesIntentionalWait": true,
      "unfinishedWordHeldUntilBoundary": true,
      "canonicalCompletedTextCommittedExactlyOnce": true,
      "guidanceLabelCapturedFromOwnedAnnotationPanel": true,
      "guidanceDoesNotDuplicateCursorCaption": true,
      "displayClockCallbacks": statistics.callbacks,
      "p95CallbackIntervalMS": statistics.p95CallbackIntervalMS,
      "callbackIntervalsAreNotPresentedFPS": true,
      "microphoneAndProviderUsed": false,
      "frontmostUnchanged": true,
      "canonicalChatUnchangedByPartialPreview": true,
      "fullNotchDashboardStayedTucked": true,
    ]
    try JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys])
      .write(to: output.appendingPathComponent("cursor-acceptance.json"))
  }

  @MainActor static func exportGuidanceAnnotation(label: String, to url: URL) async throws {
    try await exportAnnotationSnapshot(panel: annotationPanel(label: label), to: url)
  }

  @MainActor private static func annotationPanel(label: String) throws -> AnnotationPanel {
    for case let panel as AnnotationPanel in NSApp.windows
    where panel.isVisible && panel.contentView is GuidanceAnnotationView {
      guard let textLayer = try? annotationTextLayer(in: panel),
        (textLayer.string as? NSAttributedString)?.string == label
      else { continue }
      return panel
    }
    throw Failure.message("The fixture's owned guidance annotation panel is unavailable.")
  }

  @MainActor private static func annotationTextLayer(in panel: AnnotationPanel) throws
    -> CATextLayer
  {
    guard
      let pill = panel.contentView?.layer?.sublayers?.first(where: { $0.name == "guidance.label" }),
      !pill.isHidden,
      let text = pill.sublayers?.first(where: { $0.name == "guidance.label.text" }) as? CATextLayer
    else { throw Failure.message("The guidance annotation has no visible retained label layer.") }
    return text
  }

  /// Captures only the explicitly admitted fixture's own transparent window.
  /// A desktop-independent window filter excludes all other application pixels.
  @MainActor private static func exportAnnotationSnapshot(panel: AnnotationPanel, to url: URL)
    async throws
  {
    let inventory = try await SCShareableContent.excludingDesktopWindows(
      false, onScreenWindowsOnly: true)
    guard
      let window = inventory.windows.first(where: {
        $0.windowID == CGWindowID(panel.windowNumber)
          && $0.owningApplication?.processID == ProcessInfo.processInfo.processIdentifier
      })
    else { throw Failure.message("The owned annotation window is unavailable for capture.") }
    let configuration = SCStreamConfiguration()
    configuration.width = max(1, Int(panel.frame.width * panel.backingScaleFactor))
    configuration.height = max(1, Int(panel.frame.height * panel.backingScaleFactor))
    configuration.showsCursor = false
    let image = try await SCScreenshotManager.captureImage(
      contentFilter: SCContentFilter(desktopIndependentWindow: window), configuration: configuration
    )
    guard let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    else { throw CocoaError(.fileWriteUnknown) }
    try data.write(to: url, options: .atomic)
  }

  private static func require(_ condition: Bool, _ message: String) throws {
    if !condition { throw Failure.message(message) }
  }
  private enum Failure: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let message) = self { message } else { nil } }
  }
}

/// Explicit opt-in request through the real AppModel → signed-in Codex adapter
/// → preview → native caption path. The prompt contains only a public fixture.
enum CursorCompanionLiveAcceptance {
  @MainActor static func run(
    cursor: CursorCompanionCoordinator, model: AppModel, output: URL
  ) async throws {
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    defer {
      model.stop()
      cursor.shutdown()
    }
    guard let screen = NSScreen.main, !cursor.observesPointer else {
      throw ProviderError.message("Live cursor acceptance requires isolated presentation.")
    }
    cursor.pointerMoved(to: CGPoint(x: screen.frame.midX - 160, y: screen.frame.midY + 100))
    model.providerMode = "ChatGPT via Codex"
    model.configuration.speechEnabled = false
    model.input =
      "Explain why the Moon has phases in two useful sentences. Return one text unit only, no diagram."
    let started = ProcessInfo.processInfo.systemUptime
    model.send()
    var firstPrefix: CursorCompanionSnapshot?
    while model.busy && ProcessInfo.processInfo.systemUptime - started < 75 {
      if firstPrefix == nil && !cursor.snapshot.text.isEmpty {
        firstPrefix = cursor.snapshot
        try await cursor.exportSnapshot(to: output.appendingPathComponent("cursor-live-prefix.png"))
      }
      try await Task.sleep(for: .milliseconds(25))
    }
    guard !model.busy, model.error == nil else {
      model.stop()
      throw ProviderError.message(model.error ?? "Live cursor turn timed out.")
    }
    let completedMS = (ProcessInfo.processInfo.systemUptime - started) * 1_000
    guard let reply = model.messages.last(where: { $0.role == "assistant" })?.text, !reply.isEmpty
    else {
      throw ProviderError.message("Live turn did not commit a validated answer to Chat.")
    }
    let expected = CursorCompanionCoordinator.captionWindow(reply)
    let revealDeadline = ProcessInfo.processInfo.systemUptime + 30
    while cursor.snapshot.text != expected && ProcessInfo.processInfo.systemUptime < revealDeadline
    {
      try await Task.sleep(for: .milliseconds(25))
    }
    let final = cursor.snapshot
    guard final.text == expected, let previewMS = final.timing.firstPreviewMS,
      let glyphMS = final.timing.firstGlyphRenderSubmissionMS,
      let completeTextMS = final.timing.firstCompleteTextMS,
      glyphMS >= previewMS, previewMS <= completeTextMS
    else {
      throw ProviderError.message("Live preview/canonical reply/reveal timings did not agree.")
    }
    try await cursor.exportSnapshot(to: output.appendingPathComponent("cursor-live-answer.png"))
    let result: [String: Any] = [
      "result": "passed", "provider": "ChatGPT via Codex app-server",
      "publicFixtureOnly": true, "microphoneAndSpeechOutputUsed": false,
      "responseCompletedMS": completedMS,
      "firstPreviewMS": previewMS, "firstCompleteTextMS": completeTextMS,
      "firstGlyphRenderSubmissionMS": glyphMS,
      "previewToGlyphSubmissionMS": glyphMS - previewMS,
      "incrementalPreviewObserved": previewMS < completeTextMS,
      "answerUTF8Bytes": reply.utf8.count,
      "answer": reply,
      "timingsAreOneTrialNotLatencyGuarantees": true,
      "renderSubmissionIsNotMeasuredPresentationOrAcousticOnset": true,
    ]
    try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
      .write(to: output.appendingPathComponent("cursor-live-acceptance.json"))
  }
}
