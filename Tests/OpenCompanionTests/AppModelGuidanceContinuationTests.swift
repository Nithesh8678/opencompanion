import CompanionStore
import Foundation
import Testing

@testable import OpenCompanion

/// Real submission/transcript/persistence boundaries are exercised while the
/// queued turn is cancelled synchronously, before capture or provider work.
@Suite @MainActor struct AppModelGuidanceContinuationTests {
  @Test func buttonContinuePersistsOnlyTheVisibleCommand() async throws {
    let (folder, store) = try fixtureStore()
    defer { try? FileManager.default.removeItem(at: folder) }
    let model = AppModel(acceptanceMode: true, store: store, screenGuidanceEnabled: { true })
    defer { model.stop() }
    model.configuration.speechEnabled = false
    model.input = "Keep this unsent draft"
    model.beginScreenGuidance("Guide me through renaming this item", speakAloud: false)
    let request = try #require(model.activeGuidanceRequest)
    // Authored semantic action; this transcript test never displays a window.
    let token = try #require(model.guidanceSession.currentToken)
    try model.guidanceSession.presentAction(
      token: token, instruction: "Enter the requested name", kind: .manual)
    let frame = evidence()
    model.evidence = frame
    let generation = model.taskGeneration

    model.continueScreenGuidance(
      request: request, expectedEvidence: ScreenEvidenceIdentity(frame), generation: generation,
      observation: .explicitContinue)

    #expect(model.messages.map(\.text) == [request.prompt, "Continue"])
    #expect(model.input == "Keep this unsent draft")
    #expect(model.activeGuidanceRequest?.id == request.id)
    #expect(model.activeGuidanceRequest?.step == 1)
    #expect(model.activeGuidanceRequest?.speakAloud == false)
    model.stop()
    await model.persistConversation()
    let record = try await store.record(id: model.conversationID)
    let lines = try JSONDecoder().decode([ChatLine].self, from: #require(record.payload))
    #expect(lines.map(\.text) == [request.prompt, "Continue"])
    #expect(!record.body.contains("Copy candidate IDs"))
    #expect(!record.body.contains("Guidance step:"))
    #expect(!record.body.contains("Original task:"))
    #expect(!model.diagnosticEvents.contains { $0["event"] == "guidance.capture.accepted" })
  }

  @Test(arguments: [false, true])
  func spokenContinueUsesRecognizedTextAndPreservesOriginalSpeechPolicy(_ speakAloud: Bool) throws {
    let model = AppModel(acceptanceMode: true, screenGuidanceEnabled: { true })
    defer { model.stop() }
    model.configuration.speechEnabled = false
    model.input = "Unsent typed question"
    let frame = evidence()
    model.evidence = frame
    let continuation = continuation(model: model, frame: frame, speakAloud: speakAloud)
    let recognized = "I’m done!"

    #expect(
      model.continueManualGuidanceVoice(
        continuation, transcript: recognized, foregroundPID: frame.foregroundPID,
        now: ProcessInfo.processInfo.systemUptime))
    #expect(model.messages.map(\.text) == [recognized])
    #expect(model.input == "Unsent typed question")
    #expect(model.activeGuidanceRequest?.id == continuation.step.request.id)
    #expect(model.activeGuidanceRequest?.prompt == continuation.step.request.prompt)
    #expect(model.activeGuidanceRequest?.step == continuation.step.request.step + 1)
    #expect(model.activeGuidanceRequest?.speakAloud == speakAloud)
    #expect(model.activeGuidanceRequest?.expires == continuation.step.request.expires)
    #expect(model.responsePolicy.route == .screenGuidance)
    if !speakAloud {
      // A silent request must not queue speech merely because Continue was
      // spoken. No audible test is needed to detect the previous true override.
      try model.accept(
        ProviderUnit(
          type: "text", text: "Public next-step fixture", title: nil, nodes: nil, removeIDs: nil,
          target: nil), generation: model.taskGeneration, expectedEvidence: nil)
      #expect(!model.voice.hasPendingSpeech)
    }
    model.stop()
  }

  @Test func disablingGuidanceAfterTakingTheVoiceLeaseRefusesWithoutATurn() {
    let switcher = GuidancePreferenceFixture()
    let model = AppModel(
      acceptanceMode: true, screenGuidanceEnabled: { switcher.enabled })
    defer { model.stop() }
    let frame = evidence()
    model.evidence = frame
    let pending = continuation(model: model, frame: frame)
    let generation = model.taskGeneration
    let captureRevision = model.capturePublicationRevision
    switcher.enabled = false

    #expect(
      model.continueManualGuidanceVoice(
        pending, transcript: "Continue.", foregroundPID: frame.foregroundPID,
        now: ProcessInfo.processInfo.systemUptime))
    #expect(model.messages.isEmpty && model.taskGeneration == generation)
    #expect(model.capturePublicationRevision == captureRevision)
    #expect(model.activeGuidanceRequest == nil && !model.busy)
    #expect(model.notice?.contains("disabled") == true && model.voiceNotice == model.notice)
    #expect(!model.diagnosticEvents.contains { $0["event"] == "guidance.voiceContinue.requested" })
  }

  @Test func finalSendGateAlsoRefusesADisableBetweenValidationAndSubmission() {
    var reads = 0
    let model = AppModel(
      acceptanceMode: true,
      screenGuidanceEnabled: {
        reads += 1
        return reads == 1
      })
    defer { model.stop() }
    let frame = evidence()
    model.evidence = frame
    let pending = continuation(model: model, frame: frame)
    let generation = model.taskGeneration
    #expect(
      model.continueManualGuidanceVoice(
        pending, transcript: "Continue", foregroundPID: frame.foregroundPID,
        now: ProcessInfo.processInfo.systemUptime))
    #expect(reads == 2)
    #expect(model.messages.isEmpty && model.taskGeneration == generation && !model.busy)
    #expect(model.activeGuidanceRequest == nil && model.notice?.contains("disabled") == true)
  }

  @Test func expiredCommandIsHandledWithoutBecomingAnOrdinaryQuestion() {
    let model = AppModel(acceptanceMode: true, screenGuidanceEnabled: { true })
    defer { model.stop() }
    let frame = evidence()
    model.evidence = frame
    let pending = continuation(model: model, frame: frame)
    let generation = model.taskGeneration
    #expect(
      model.continueManualGuidanceVoice(
        pending, transcript: "Continue", foregroundPID: frame.foregroundPID,
        now: pending.step.expiresAt))
    #expect(model.messages.isEmpty && model.taskGeneration == generation && !model.busy)
    #expect(model.notice?.contains("expired") == true && model.voiceNotice == model.notice)
  }

  @Test(arguments: ["What does this button do?", "Do not continue", "\"continue\""])
  func ordinaryOrNegatedUtterancesStayAvailableForNormalRouting(_ transcript: String) {
    let model = AppModel(acceptanceMode: true, screenGuidanceEnabled: { true })
    defer { model.stop() }
    let frame = evidence()
    model.evidence = frame
    let pending = continuation(model: model, frame: frame)
    let generation = model.taskGeneration
    #expect(
      !model.continueManualGuidanceVoice(
        pending, transcript: transcript, foregroundPID: frame.foregroundPID,
        now: ProcessInfo.processInfo.systemUptime))
    #expect(model.messages.isEmpty && model.taskGeneration == generation && model.notice == nil)
  }

  private func evidence() -> ScreenEvidence {
    ScreenEvidence(
      frameID: UUID(), revision: 1, capturedAt: ProcessInfo.processInfo.systemUptime - 1,
      displayID: 1, foregroundPID: 424_242, foregroundName: "Authored public fixture",
      screenRect: CGRect(x: -400, y: 0, width: 800, height: 600), image: Data(),
      semanticText: "No actual pixels captured")
  }

  private func continuation(
    model: AppModel, frame: ScreenEvidence, speakAloud: Bool = false
  ) -> ManualGuidanceVoiceContinuation {
    let now = ProcessInfo.processInfo.systemUptime
    let request = ScreenGuidanceRequest(
      prompt: "Guide me through renaming this item", step: 0, expires: now + 180,
      speakAloud: speakAloud)
    let step = ManualGuidanceStep(
      id: UUID(), label: "Enter a name", instruction: "Rename this item",
      evidence: ScreenEvidenceIdentity(frame), generation: model.taskGeneration, request: request,
      targetRect: CGRect(x: -200, y: 390, width: 160, height: 60), expiresAt: now + 45)
    return ManualGuidanceVoiceContinuation(step: step, inputGeneration: model.taskGeneration)
  }

  private func fixtureStore() throws -> (URL, LocalStore) {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(
      "OpenCompanionContinuationTranscript-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return (folder, try LocalStore(url: folder.appendingPathComponent("library.sqlite")))
  }
}

@MainActor private final class GuidancePreferenceFixture {
  var enabled = true
}
