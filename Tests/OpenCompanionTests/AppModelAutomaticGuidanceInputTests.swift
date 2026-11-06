import CompanionCore
import CoreGraphics
import Foundation
import ImageIO
import Testing

@testable import OpenCompanion

/// Executes host request/payload/admission with authored acquisition and stream
/// dependencies. No native capture/preparation, event, microphone or model runs.
@Suite @MainActor struct AppModelAutomaticGuidanceInputTests {
  @Test(
    arguments: [
      "can u tell me how to create a new table",
      "check screen and tell me how to create a new table",
    ], [false, true])
  func unqualifiedUIQuestionsSendANewImageForTypedAndAuthoredPTTCompletion(
    _ text: String, _ voiceCompletion: Bool
  ) async throws {
    let probe = AutomaticGuidanceInputProbe()
    let fixture = makeModel(probe: probe)
    let model = fixture.model
    defer { model.stop() }
    let old = try evidence(marker: "OLD_AUTOMATIC_FRAME", red: 0.8, blue: 0.1)
    let notebook = BuiltInLessons.lever()
    model.scene = notebook
    model.section = "Companion"
    model.selectedContext = "UNRELATED_PUBLIC_FILE_MEMORY_CONTEXT"
    model.contextTitle = "Public unrelated attachment"
    model.evidence = old
    model.messages = [
      ChatLine(role: "user", text: "Earlier public question."),
      ChatLine(role: "assistant", text: "I don't have a view of your screen here."),
      ChatLine(role: "assistant", text: "Which app: Excel, Word or Notion?"),
    ]
    #expect(GuidanceIntent.requestsScreenGuidance(text: text))
    let policy = ResponsePolicy.resolve(text: text, screenGuidanceEnabled: true)
    #expect(policy.route == .screenGuidance)
    let plan = ResponseInputPlan.resolve(
      policy: policy, voiceOnly: voiceCompletion, selectedContext: model.selectedContext,
      evidence: old, explicitManualEvidence: nil)
    #expect(plan.requiresFreshGuidanceCapture && plan.image == nil && plan.context.isEmpty)
    if voiceCompletion { model.input = "Keep this typed draft" }

    try submit(text, voiceCompletion: voiceCompletion, fixture: fixture, probe: probe)
    let declared = try #require(model.activeGuidanceRequest)
    #expect(declared.prompt == text && declared.selectedScope == nil)
    #expect(model.guidanceSession.workflow?.phase == .checking)
    try await until { probe.inputs.count == 1 && !model.busy }

    let input = try #require(probe.inputs.first)
    let fresh = try #require(probe.returnedFrame)
    let acquisition = try #require(probe.acquisitions.first)
    #expect(probe.acquisitions.count == 1 && probe.finishedAcquisitions == 1)
    #expect(acquisition.request == declared && acquisition.generation == model.taskGeneration)
    #expect(acquisition.captureToken == model.capturePublicationRevision)
    #expect(acquisition.expectedForegroundPID == nil)
    #expect(input.image == fresh.image && input.image != old.image)
    #expect(input.context.contains(fresh.semanticText))
    #expect(input.context.contains(fresh.groundingCandidates[0].id))
    #expect(!input.context.contains(old.semanticText))
    #expect(!input.context.contains(old.groundingCandidates[0].id))
    #expect(!input.context.contains("UNRELATED_PUBLIC_FILE_MEMORY_CONTEXT"))
    #expect(input.messages.map(\.text) == [text])
    #expect(!input.messages.contains { $0.text.contains("view of your screen") })
    #expect(!input.messages.contains { $0.text.contains("Which app:") })
    #expect(input.scene == nil && input.responsePolicy.route == .screenGuidance)
    #expect(!input.responsePolicy.allowsNotebook && !input.responsePolicy.includesExistingNotebook)
    #expect(ScreenEvidenceIdentity(fresh).matches(model.evidence))
    #expect(model.selectedCaptureSelectionID == nil)
    #expect(model.guidanceSession.workflow?.checks.last?.outcome == .uncertain)
    #expect(
      model.scene == notebook && model.selectedContext == "UNRELATED_PUBLIC_FILE_MEMORY_CONTEXT")
    #expect(model.error == nil && probe.speechStarts == 0)
    #expect(model.input == (voiceCompletion ? "Keep this typed draft" : ""))
    #expect(probe.authoredVoiceCompletions == (voiceCompletion ? 1 : 0))
    expectNoNativeTargetOrTransport(model)
  }

  @Test(arguments: [false, true])
  func acquisitionFailureDoesNotReachAProviderOrInventATextOnlyFallback(
    _ voiceCompletion: Bool
  ) async throws {
    let probe = AutomaticGuidanceInputProbe()
    probe.failure = true
    let fixture = makeModel(probe: probe)
    let model = fixture.model
    defer { model.stop() }
    let text = "can u tell me how to create a new table"

    try submit(text, voiceCompletion: voiceCompletion, fixture: fixture, probe: probe)
    try await until { probe.finishedAcquisitions == 1 && !model.busy }

    #expect(probe.acquisitions.count == 1 && probe.inputs.isEmpty)
    #expect(model.error?.contains("Authored acquisition unavailable") == true)
    #expect(model.messages.filter { $0.role == "assistant" }.isEmpty)
    #expect(model.activeGuidanceRequest == nil)
    #expect(model.guidanceSession.workflow?.phase == .paused)
    #expect(!model.diagnosticEvents.contains { $0["event"] == "generation.completed" })
    #expect(probe.speechStarts == 0)
    expectNoNativeTargetOrTransport(model)
  }

  @Test(arguments: [false, true])
  func stopWhileAcquisitionIsSuspendedRejectsItsLateFrameAndProviderDispatch(
    _ voiceCompletion: Bool
  ) async throws {
    let probe = AutomaticGuidanceInputProbe()
    let barrier = AutomaticGuidanceAcquisitionBarrier()
    let fixture = makeModel(probe: probe, barrier: barrier)
    let model = fixture.model
    defer {
      model.stop()
      barrier.release()
    }
    let old = try evidence(marker: "OLD_AUTOMATIC_FRAME", red: 0.8, blue: 0.1)
    model.evidence = old
    try submit(
      "check screen and tell me how to create a new table", voiceCompletion: voiceCompletion,
      fixture: fixture, probe: probe)
    try await until { barrier.entered }
    let generation = model.taskGeneration

    model.stop()
    barrier.release()
    try await until { probe.finishedAcquisitions == 1 && !model.busy }

    #expect(model.taskGeneration > generation && model.activeGuidanceRequest == nil)
    #expect(probe.inputs.isEmpty && probe.acquisitions.count == 1)
    #expect(ScreenEvidenceIdentity(old).matches(model.evidence))
    #expect(model.evidence?.frameID != probe.returnedFrame?.frameID)
    #expect(model.guidanceSession.workflow?.phase == .paused)
    #expect(model.messages.filter { $0.role == "assistant" }.isEmpty)
    #expect(probe.speechStarts == 0)
    expectNoNativeTargetOrTransport(model)
  }

  @Test(arguments: ["nonJPEG", "sameFrame", "wrongPID", "window", "oldTimestamp"])
  func invalidAuthoredAcquisitionCannotCrossThePreProviderBoundary(_ invalid: String) async throws {
    let probe = AutomaticGuidanceInputProbe()
    probe.invalidFrame = invalid
    let fixture = makeModel(probe: probe)
    let model = fixture.model
    defer { model.stop() }
    let old = try evidence(marker: "OLD_AUTOMATIC_FRAME", red: 0.8, blue: 0.1)
    probe.previousFrameID = old.frameID
    model.evidence = old
    model.input = "can u tell me how to create a new table"

    model.send()
    try await until { probe.finishedAcquisitions == 1 && !model.busy }

    #expect(probe.inputs.isEmpty && probe.acquisitions.count == 1)
    #expect(model.error != nil && model.activeGuidanceRequest == nil)
    #expect(ScreenEvidenceIdentity(old).matches(model.evidence))
    #expect(!model.diagnosticEvents.contains { $0["event"] == "generation.completed" })
    expectNoNativeTargetOrTransport(model)
  }

  @Test func anExplicitScreenPrivacyOptOutDoesNotUseTheAutomaticAcquisitionDependency()
    async throws
  {
    let probe = AutomaticGuidanceInputProbe()
    let fixture = makeModel(probe: probe)
    let model = fixture.model
    defer { model.stop() }
    model.evidence = try evidence(marker: "UNSELECTED_OLD_FRAME", red: 0.8, blue: 0.1)
    model.input = "Don't capture my screen. How do I create a new table?"

    model.send()
    try await until { probe.inputs.count == 1 && !model.busy }

    #expect(probe.acquisitions.isEmpty)
    #expect(probe.inputs[0].responsePolicy.route == .conversation)
    #expect(probe.inputs[0].image == nil && probe.inputs[0].scene == nil)
    #expect(model.activeGuidanceRequest == nil && probe.speechStarts == 0)
    expectNoNativeTargetOrTransport(model)
  }

  @Test(
    arguments: [
      "can u tell me how to create a new table? Don't screenshot.",
      "can u tell me how to create a new table? Don’t screenshot.",
      "check screen and tell me how to create a new table. Don't screenshot.",
      "check screen and tell me how to create a new table. Don’t screenshot.",
      "Do not check my screen. How do I create a table?",
      "Don’t analyze my screen. How do I create a table?",
      "How do I create a table without inspecting my screen?",
      "Help me create a table, but do not start capturing anything.",
    ], [false, true])
  func trailingScreenshotOptOutPreventsCaptureAndImagePayloadForTypedAndAuthoredPTT(
    _ text: String, _ voiceCompletion: Bool
  ) async throws {
    let probe = AutomaticGuidanceInputProbe()
    let fixture = makeModel(probe: probe)
    let model = fixture.model
    defer { model.stop() }
    let old = try evidence(marker: "UNSELECTED_SCREEN_CONTEXT", red: 0.8, blue: 0.1)
    model.evidence = old
    #expect(!GuidanceIntent.requestsScreenGuidance(text: text))

    try submit(text, voiceCompletion: voiceCompletion, fixture: fixture, probe: probe)
    try await until { probe.inputs.count == 1 && !model.busy }

    let input = try #require(probe.inputs.first)
    #expect(probe.acquisitions.isEmpty)
    #expect(input.responsePolicy.route == .conversation)
    #expect(input.image == nil && input.scene == nil)
    #expect(!input.context.contains(old.semanticText))
    #expect(!input.context.contains(old.groundingCandidates[0].id))
    #expect(input.messages.last?.text == text)
    #expect(model.activeGuidanceRequest == nil && model.error == nil)
    #expect(probe.speechStarts == 0)
    expectNoNativeTargetOrTransport(model)
  }

  @Test(
    arguments: [
      "can u tell me how to create a new table? Don't screenshot.",
      "can u tell me how to create a new table? Don’t screenshot.",
      "Do not check my screen. How do I create a table?",
      "Don’t analyze my screen. How do I create a table?",
      "How do I create a table without inspecting my screen?",
      "Help me create a table, but do not start capturing anything.",
    ], [false, true])
  func trailingScreenshotOptOutAlsoExcludesAnExistingManualScreenAttachment(
    _ text: String, _ screenDerivedStrokes: Bool
  ) async throws {
    let probe = AutomaticGuidanceInputProbe()
    let fixture = makeModel(probe: probe)
    let model = fixture.model
    defer { model.stop() }
    let selected = try evidence(marker: "SELECTED_SCREEN_SEMANTICS", red: 0.8, blue: 0.1)
    model.selectedContext = "INDEPENDENT_PUBLIC_FILE_MEMORY_CONTEXT"
    let published = model.publishSelectedCapture(
      selected, token: model.capturePublicationRevision,
      strokes: screenDerivedStrokes ? "[[0.2,0.4],[0.3,0.5]]" : "")
    #expect(published)
    let selectionID = try #require(model.selectedCaptureSelectionID)
    let selectedContext = model.selectedContext
    model.input = text

    model.send()
    try await until { probe.inputs.count == 1 && !model.busy }

    let input = try #require(probe.inputs.first)
    #expect(probe.acquisitions.isEmpty)
    #expect(input.responsePolicy.route == .conversation)
    #expect(input.image == nil && input.scene == nil)
    #expect(!input.context.contains(selected.semanticText))
    #expect(!input.context.contains(selected.groundingCandidates[0].id))
    if screenDerivedStrokes {
      #expect(selectedContext.contains("User-drawn spatial context"))
      #expect(input.context.isEmpty)
    } else {
      #expect(input.context == "INDEPENDENT_PUBLIC_FILE_MEMORY_CONTEXT")
    }
    // Per-request suppression must not destroy the user's independent selected
    // attachment or silently replace its capture authorization in the UI.
    #expect(ScreenEvidenceIdentity(selected).matches(model.evidence))
    #expect(model.selectedCaptureSelectionID == selectionID)
    #expect(model.selectedContext == selectedContext)
    #expect(model.activeGuidanceRequest == nil && model.error == nil)
    #expect(probe.speechStarts == 0)
    expectNoNativeTargetOrTransport(model)
  }

  private func makeModel(
    probe: AutomaticGuidanceInputProbe, barrier: AutomaticGuidanceAcquisitionBarrier? = nil
  ) -> AutomaticGuidanceFixture {
    let voice = VoiceService(nativeSpeak: { _ in probe.speechStarts += 1 }, nativeStop: {})
    let model = AppModel(
      acceptanceMode: true, voice: voice, guidanceForegroundPID: { 424_242 },
      screenGuidanceEnabled: { true },
      automaticGuidanceCapture: { request, generation, captureToken, expectedForegroundPID in
        probe.acquisitions.append(
          .init(
            request: request, generation: generation, captureToken: captureToken,
            expectedForegroundPID: expectedForegroundPID))
        defer { probe.finishedAcquisitions += 1 }
        if probe.failure { throw ProviderError.message("Authored acquisition unavailable") }
        var frame = try evidence(marker: "FRESH_AUTOMATIC_FRAME", red: 0.1, blue: 0.8)
        if let barrier { await barrier.suspend() }
        frame.capturedAt = ProcessInfo.processInfo.systemUptime
        switch probe.invalidFrame {
        case "nonJPEG": frame.image = Data([0, 1, 2])
        case "sameFrame": frame.frameID = probe.previousFrameID ?? frame.frameID
        case "wrongPID": frame.foregroundPID = 555_555
        case "window": frame.windowID = 42
        case "oldTimestamp": frame.capturedAt -= 60
        default: break
        }
        probe.returnedFrame = frame
        return frame
      },
      responseStream: { input, onUnit, _ in
        probe.inputs.append(input)
        guard input.responsePolicy.route == .screenGuidance else { return }
        try await onUnit(
          ProviderUnit(
            type: "guidanceStatus", text: nil, title: nil, nodes: nil, removeIDs: nil,
            target: nil,
            guidance: .init(status: .uncertain, summary: "Public screenshot input received.")))
      })
    model.configuration.speechEnabled = false
    return .init(model: model, voice: voice)
  }

  private func submit(
    _ text: String, voiceCompletion: Bool, fixture: AutomaticGuidanceFixture,
    probe: AutomaticGuidanceInputProbe
  ) throws {
    guard voiceCompletion else {
      fixture.model.input = text
      fixture.model.send()
      return
    }
    let forwardState = fixture.voice.onInputState
    fixture.voice.onInputState = { snapshot in
      if snapshot.mode == .pushToTalk { probe.voiceSessionID = snapshot.sessionID }
      forwardState?(snapshot)
    }
    defer { fixture.voice.onInputState = forwardState }
    fixture.model.beginPushToTalk()
    let id = try #require(probe.voiceSessionID)
    // No suspension occurs between begin and this authored completion. Its
    // production handler sends, and send cancels VoiceService input before the
    // queued startListening task can pass requirePreparing or ask permission.
    // This tests callback routing, not recognizer/microphone/hotkey delivery.
    let complete = try #require(fixture.voice.onInputCompletion)
    probe.authoredVoiceCompletions += 1
    complete(.init(sessionID: id, mode: .pushToTalk, transcript: text, isFinal: true))
  }

  private func evidence(marker: String, red: Double, blue: Double) throws
    -> OpenCompanion.ScreenEvidence
  {
    let frameID = UUID()
    let candidate = ScreenGroundingCandidate(
      id: ScreenGrounding.candidateID(frameID: frameID, index: 0), source: .ocr,
      role: "text", label: "Public control", enabled: true, actionable: false,
      x: 0.1, y: 0.1, width: 0.2, height: 0.1)
    return .init(
      frameID: frameID, revision: 2, capturedAt: ProcessInfo.processInfo.systemUptime - 1,
      displayID: 7, foregroundPID: 424_242, foregroundName: "Authored public application",
      screenRect: .init(x: -800, y: -200, width: 800, height: 600),
      image: try jpeg(red: red, blue: blue), semanticText: marker + " " + candidate.id,
      groundingCandidates: [candidate], imageWidth: 32, imageHeight: 24)
  }

  private func jpeg(red: Double, blue: Double) throws -> Data {
    guard
      let context = CGContext(
        data: nil, width: 32, height: 24, bitsPerComponent: 8, bytesPerRow: 32 * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { throw FixtureFailure.image }
    context.setFillColor(CGColor(red: red, green: 0.2, blue: blue, alpha: 1))
    context.fill(.init(x: 0, y: 0, width: 32, height: 24))
    guard let image = context.makeImage() else { throw FixtureFailure.image }
    let data = NSMutableData()
    guard
      let destination = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil)
    else { throw FixtureFailure.image }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { throw FixtureFailure.image }
    return data as Data
  }

  private func until(_ condition: @MainActor () -> Bool) async throws {
    for _ in 0..<500 {
      if condition() { return }
      try await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("The authored automatic-input transaction did not reach its checkpoint.")
    throw FixtureFailure.checkpoint
  }

  private func expectNoNativeTargetOrTransport(_ model: AppModel) {
    #expect(model.codex == nil && model.overlay.presentationDiagnostics.isEmpty)
    #expect(!model.diagnosticEvents.contains { $0["event"] == "visual.accepted" })
  }

  private enum FixtureFailure: Error { case image, checkpoint }
}

@MainActor private struct AutomaticGuidanceFixture {
  let model: AppModel
  let voice: VoiceService
}

@MainActor private final class AutomaticGuidanceInputProbe {
  struct Acquisition {
    let request: ScreenGuidanceRequest
    let generation: UInt64
    let captureToken: UInt64
    let expectedForegroundPID: pid_t?
  }
  var acquisitions: [Acquisition] = []
  var finishedAcquisitions = 0
  var inputs: [ReasoningTurnInput] = []
  var returnedFrame: OpenCompanion.ScreenEvidence?
  var failure = false
  var invalidFrame: String?
  var previousFrameID: UUID?
  var voiceSessionID: UUID?
  var authoredVoiceCompletions = 0
  var speechStarts = 0
}

@MainActor private final class AutomaticGuidanceAcquisitionBarrier {
  private var continuation: CheckedContinuation<Void, Never>?
  private(set) var entered = false

  func suspend() async {
    await withCheckedContinuation { continuation in
      self.continuation = continuation
      entered = true
    }
  }

  func release() {
    continuation?.resume()
    continuation = nil
  }
}
