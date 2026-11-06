import CompanionCore
import CompanionStore
import Foundation
import Testing

@testable import OpenCompanion

/// Exercise the actual synchronous submission/admission boundaries. Every
/// queued turn is stopped before yielding, so no capture, provider, audio or
/// displayed window is involved. Authored evidence supplies identity only.
@Suite @MainActor struct AppModelGuidanceWorkflowTests {
  @Test func anUnofferedContinueCannotAdvanceTheRequestOrSemanticCheck() throws {
    let model = makeModel()
    defer { model.stop() }
    let notebook = retainedNotebook(model)
    model.beginScreenGuidance("Guide me through naming this document", speakAloud: false)
    let request = try #require(model.activeGuidanceRequest)
    let token = try #require(model.guidanceSession.currentToken)
    let original = model.guidanceSession.workflow
    let frame = evidence()
    model.evidence = frame
    let generation = model.taskGeneration
    model.continueScreenGuidance(
      request: request, expectedEvidence: ScreenEvidenceIdentity(frame), generation: generation,
      observation: .explicitContinue)
    #expect(model.taskGeneration == generation && model.activeGuidanceRequest == request)
    #expect(model.guidanceSession.workflow == original && model.guidanceSession.owns(token))
    #expect(model.messages.map(\.text) == [request.prompt])
    #expect(model.error != nil && model.scene == notebook)
    model.stop()
    expectNoCaptureOrNotebookOutput(model)
  }

  @Test func anOfferedManualActionIsObservedOnceBeforeAFreshCheckIsDeclared() throws {
    let model = makeModel()
    defer { model.stop() }
    let notebook = retainedNotebook(model)
    model.input = "Keep this unsent draft"
    model.beginScreenGuidance("Guide me through naming this document", speakAloud: false)
    let request = try #require(model.activeGuidanceRequest)
    let token = try #require(model.guidanceSession.currentToken)
    try model.guidanceSession.presentAction(
      token: token, instruction: "Enter the public name, then Continue", label: "Name",
      kind: .manual)
    let originalAction = try #require(model.guidanceSession.workflow?.currentAction)
    let frame = evidence()
    model.evidence = frame
    let generation = model.taskGeneration
    model.continueScreenGuidance(
      request: request, expectedEvidence: ScreenEvidenceIdentity(frame), generation: generation,
      observation: .explicitContinue)
    let current = try #require(model.guidanceSession.currentToken)
    let workflow = try #require(model.guidanceSession.workflow)
    #expect(current.workflowID == token.workflowID && current.checkID != token.checkID)
    #expect(!model.guidanceSession.owns(token) && model.guidanceSession.owns(current))
    #expect(workflow.actions.count == 1 && workflow.currentAction?.id == originalAction.id)
    #expect(workflow.currentAction?.observation?.kind == .manualContinue)
    #expect(workflow.checks.count == 2 && workflow.phase == .checking)
    #expect(workflow.checks.first?.outcome == nil && workflow.checks.first?.verification == nil)
    #expect(model.activeGuidanceRequest?.id == request.id && model.activeGuidanceRequest?.step == 1)
    #expect(model.activeGuidanceRequest?.expires == request.expires)
    #expect(model.taskGeneration > generation && model.input == "Keep this unsent draft")
    #expect(model.messages.map(\.text) == [request.prompt, "Continue"])
    #expect(model.scene == notebook)
    let advancedGeneration = model.taskGeneration
    model.continueScreenGuidance(
      request: request, expectedEvidence: ScreenEvidenceIdentity(frame), generation: generation,
      observation: .explicitContinue)
    #expect(
      model.taskGeneration == advancedGeneration && model.guidanceSession.workflow == workflow)
    model.stop()
    expectNoCaptureOrNotebookOutput(model)
  }

  @Test func pauseRevokesRuntimeAndCheckAuthorityWithoutLosingProgress() throws {
    let model = makeModel()
    defer { model.stop() }
    let notebook = retainedNotebook(model)
    model.beginScreenGuidance("Guide me through entering this value", speakAloud: false)
    let token = try #require(model.guidanceSession.currentToken)
    try model.guidanceSession.presentAction(
      token: token, instruction: "Enter the value", kind: .manual)
    let action = model.guidanceSession.workflow?.currentAction
    let generation = model.taskGeneration
    model.pauseGuidance()
    #expect(model.taskGeneration > generation && model.activeGuidanceRequest == nil && !model.busy)
    #expect(!model.guidanceSession.owns(token) && model.guidanceSession.currentToken == nil)
    #expect(model.guidanceSession.workflow?.phase == .paused)
    #expect(model.guidanceSession.workflow?.currentAction == action)
    #expect(model.guidanceSession.workflow?.checks.count == 1 && model.scene == notebook)
    let paused = model.guidanceSession.workflow
    #expect(throws: (any Error).self) {
      try model.accept(
        status(.complete), generation: generation,
        expectedEvidence: ScreenEvidenceIdentity(evidence()))
    }
    #expect(model.guidanceSession.workflow == paused && model.scene == notebook)
    expectNoCaptureOrNotebookOutput(model)
  }

  @Test func resumeDeclaresANewRequestAndCheckDespiteAnOldSelectedImage() throws {
    let model = makeModel()
    defer { model.stop() }
    let notebook = retainedNotebook(model)
    model.beginScreenGuidance("Guide me through editing this public document", speakAloud: false)
    let originalRequest = try #require(model.activeGuidanceRequest)
    let originalToken = try #require(model.guidanceSession.currentToken)
    model.pauseGuidance()
    let frame = evidence()
    model.evidence = frame
    model.selectedContext = "Authored selected file context that must not become guidance evidence"
    model.contextTitle = "An old selected image"
    let generation = model.taskGeneration
    let captureRevision = model.capturePublicationRevision
    var preparations = 0
    model.onPrepareScreenGuidance = { _, _ in preparations += 1 }
    // The same response-input policy used by send must force fresh capture
    // even if this authored image had explicit manual-selection provenance.
    let plan = ResponseInputPlan.resolve(
      policy: .resolve(
        text: originalRequest.prompt, screenGuidanceEnabled: true, explicitGuidance: true),
      voiceOnly: true, selectedContext: model.selectedContext, evidence: frame,
      explicitManualEvidence: ScreenEvidenceIdentity(frame))
    #expect(plan.requiresFreshGuidanceCapture && plan.image == nil && plan.context.isEmpty)
    model.resumeGuidance()
    let resumedRequest = try #require(model.activeGuidanceRequest)
    let resumedToken = try #require(model.guidanceSession.currentToken)
    #expect(
      resumedRequest.id != originalRequest.id && resumedRequest.prompt == originalRequest.prompt)
    #expect(
      resumedRequest.speakAloud == false && resumedToken.workflowID == originalToken.workflowID)
    #expect(
      resumedToken.checkID != originalToken.checkID
        && model.guidanceSession.workflow?.checks.count == 2)
    #expect(model.guidanceSession.workflow?.checks.first?.disposition == .interrupted)
    #expect(model.responsePolicy.route == .screenGuidance && model.taskGeneration > generation)
    #expect(model.capturePublicationRevision > captureRevision && preparations == 0)
    #expect(model.messages.last?.text == "Resume guide" && model.scene == notebook)
    model.stop()
    expectNoCaptureOrNotebookOutput(model)
  }

  @Test func changedEvidenceAndStaleGenerationCannotConsumeTheAssessmentSlot() throws {
    let model = makeModel()
    defer { model.stop() }
    let notebook = retainedNotebook(model)
    model.beginScreenGuidance("Explain this public screen", speakAloud: false)
    let frame = evidence()
    model.evidence = frame
    let generation = model.taskGeneration
    let original = model.guidanceSession.workflow
    #expect(throws: (any Error).self) {
      try model.accept(
        status(.progress), generation: generation - 1,
        expectedEvidence: ScreenEvidenceIdentity(frame))
    }
    #expect(throws: (any Error).self) {
      try model.accept(
        status(.complete), generation: generation,
        expectedEvidence: ScreenEvidenceIdentity(evidence()))
    }
    #expect(model.guidanceSession.workflow == original)
    try model.accept(
      status(.progress), generation: generation, expectedEvidence: ScreenEvidenceIdentity(frame))
    let accepted = model.guidanceSession.workflow
    #expect(accepted?.checks.last?.outcome == .progress && accepted?.phase == .needsAttention)
    #expect(throws: (any Error).self) {
      try model.accept(
        status(.complete), generation: generation, expectedEvidence: ScreenEvidenceIdentity(frame))
    }
    #expect(model.guidanceSession.workflow == accepted && model.scene == notebook)
    model.stop()
    expectNoCaptureOrNotebookOutput(model)
  }

  @Test func aWrongRouteStatusCannotInventOrMutateGuidanceProgress() throws {
    let model = makeModel()
    defer { model.stop() }
    let notebook = retainedNotebook(model)
    model.input = "Hello"
    model.send()
    let frame = evidence()
    model.evidence = frame
    #expect(model.responsePolicy.route == .conversation)
    #expect(throws: (any Error).self) {
      try model.accept(
        status(.complete), generation: model.taskGeneration,
        expectedEvidence: ScreenEvidenceIdentity(frame))
    }
    #expect(model.guidanceSession.workflow == nil && model.scene == notebook)
    model.stop()
    expectNoCaptureOrNotebookOutput(model)
  }

  @Test func modelCompletionIsUnverifiedAndCanStartAnExplicitFreshRecheck() async throws {
    let (url, store) = try fixtureStore()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let model = makeModel(store: store)
    defer { model.stop() }
    let notebook = retainedNotebook(model)
    model.beginScreenGuidance("Check the current public result", speakAloud: false)
    let token = try #require(model.guidanceSession.currentToken)
    let request = try #require(model.activeGuidanceRequest)
    let frame = evidence()
    model.evidence = frame
    try model.accept(
      status(.complete), generation: model.taskGeneration,
      expectedEvidence: ScreenEvidenceIdentity(frame))
    #expect(model.guidanceSession.workflow?.phase == .modelReportedComplete)
    #expect(model.guidanceSession.workflow?.checks.last?.verification == nil)
    #expect(model.guidanceSession.workflow?.canBeginCheck == true)
    #expect(model.guidanceProgressDetail.contains("not been independently verified"))
    // This fixture never runs the provider task. Supply only its quiescent UI
    // flag, then synchronously cancel that queued task via the real Recheck path.
    model.busy = false
    model.recheckGuidance()
    let recheck = try #require(model.guidanceSession.currentToken)
    #expect(recheck.checkID != token.checkID && recheck.workflowID == token.workflowID)
    #expect(model.activeGuidanceRequest?.id != request.id)
    #expect(model.guidanceSession.workflow?.checks.first?.outcome == .goalComplete)
    #expect(model.guidanceSession.workflow?.checks.count == 2 && model.scene == notebook)
    model.stop()
    expectNoCaptureOrNotebookOutput(model)
    await model.guidanceSession.flushPersistence()
  }

  @Test func clearingContextInvalidatesTheOldFrameForStatusWithoutDeletingSemanticHistory() throws {
    let model = makeModel()
    defer { model.stop() }
    model.beginScreenGuidance("Check this public control", speakAloud: false)
    let frame = evidence()
    model.evidence = frame
    model.selectedContext = "Authored old attachment"
    let original = model.guidanceSession.workflow
    let generation = model.taskGeneration
    model.clearContext()
    #expect(model.evidence == nil && model.selectedContext.isEmpty)
    #expect(throws: (any Error).self) {
      try model.accept(
        status(.complete), generation: generation, expectedEvidence: ScreenEvidenceIdentity(frame))
    }
    #expect(model.guidanceSession.workflow == original)
    model.stop()
    expectNoCaptureOrNotebookOutput(model)
  }

  @Test func openingASavedGuideCreatesACleanChatAndQueuedOpenCannotOverrideANewerChat() async throws
  {
    let (url, store) = try fixtureStore()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    var saved = try GuidanceWorkflow(goal: "Resume the public saved task", speakAloud: false)
    let check = try saved.beginCheck()
    try saved.presentAction(checkID: check, instruction: "Enter the public name", kind: .manual)
    try saved.pause()
    let row = try await store.createGuidance(
      id: saved.id.uuidString, title: "Public saved task", body: saved.goal,
      payload: JSONEncoder().encode(saved))
    let model = makeModel(store: store)
    defer { model.stop() }
    let notebook = retainedNotebook(model)
    model.input = "Old draft"
    model.messages = [.init(role: "user", text: "An old public chat")]
    model.selectedContext = "Old selected context"
    model.contextTitle = "Old attachment"
    model.evidence = evidence()
    let oldChat = model.conversationID
    let opening = try #require(model.openRecord(row))
    await opening.value
    #expect(model.conversationID != oldChat && model.conversationID != row.id)
    #expect(
      model.messages.isEmpty && model.input.isEmpty && model.selectedContext.isEmpty
        && model.evidence == nil)
    #expect(
      model.guidanceSession.workflow?.id == saved.id
        && model.guidanceSession.workflow?.phase == .paused)
    #expect(
      model.guidanceSession.workflow?.actions == saved.actions
        && model.guidanceSession.currentToken == nil)
    #expect(model.activeGuidanceRequest == nil && model.scene == notebook)
    await model.guidanceSession.flushPersistence()
    let queued = try #require(model.openRecord(row))
    model.newConversation()
    let explicitChat = model.conversationID
    await queued.value
    #expect(model.conversationID == explicitChat && model.guidanceSession.workflow == nil)
    #expect(model.messages.isEmpty && model.error == nil && model.scene == notebook)
    await model.guidanceSession.flushPersistence()
    #expect(try await store.records(kind: "guidance").count == 1)
    expectNoCaptureOrNotebookOutput(model)
  }

  private func makeModel(store: LocalStore? = nil) -> AppModel {
    let model = AppModel(
      acceptanceMode: true, store: store, guidanceForegroundPID: { 424_242 },
      screenGuidanceEnabled: { true })
    model.configuration.speechEnabled = false
    return model
  }

  private func retainedNotebook(_ model: AppModel) -> SceneDocument {
    let notebook = BuiltInLessons.lever()
    model.scene = notebook
    model.section = "Notebook"
    return notebook
  }

  private func evidence() -> OpenCompanion.ScreenEvidence {
    .init(
      frameID: UUID(), revision: 1, capturedAt: ProcessInfo.processInfo.systemUptime - 1,
      displayID: 1, foregroundPID: 424_242, foregroundName: "Authored public fixture",
      screenRect: .init(x: -400, y: 0, width: 800, height: 600), image: Data([0]),
      semanticText: "Authored identity fixture; no real pixels captured")
  }

  private func status(_ status: ProviderGuidanceAssessment.Status) -> ProviderUnit {
    .init(
      type: "guidanceStatus", text: nil, title: nil, nodes: nil, removeIDs: nil, target: nil,
      guidance: .init(status: status, summary: "Authored fresh-screen assessment"))
  }

  private func expectNoCaptureOrNotebookOutput(_ model: AppModel) {
    #expect(
      !model.diagnosticEvents.contains {
        ["guidance.capture.started", "guidance.capture.accepted", "visual.accepted"]
          .contains($0["event"] ?? "")
      })
    #expect(!model.voice.hasPendingSpeech)
  }

  private func fixtureStore() throws -> (URL, LocalStore) {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("OpenCompanion-AppWorkflow-\(UUID().uuidString)", isDirectory: true)
      .appendingPathComponent("store.sqlite")
    return (url, try LocalStore(url: url))
  }
}
