import CompanionCore
import Foundation
import Testing

@testable import OpenCompanion

/// Exercise the production cancellation boundary synchronously before queued
/// capture/provider work can run. Acceptance mode attaches no OS listeners.
@Suite @MainActor struct AppModelGuidanceSceneTests {
  @Test(arguments: [GuidanceSceneChange.foregroundChanged, .scroll, .expired, .displayChanged])
  func sceneChangesRevokeRuntimeAuthorityWhileKeepingSemanticProgressAndAttachments(
    _ reason: GuidanceSceneChange
  ) throws {
    let model = makeModel()
    defer { model.stop() }
    let notebook = BuiltInLessons.lever()
    model.scene = notebook
    model.section = "Notebook"
    model.input = "Keep this unsent draft"
    model.selectedContext = "Explicitly selected public memory"
    model.contextTitle = "Selected memory"
    model.beginScreenGuidance("Guide me through editing this public document", speakAloud: false)
    let frame = evidence()
    model.evidence = frame
    let generation = model.taskGeneration
    let captureRevision = model.capturePublicationRevision
    let conversation = model.conversationID
    let messages = model.messages.map(\.text)
    let token = try #require(model.guidanceSession.currentToken)
    try model.monitorGuidanceScene(
      generation: generation, foregroundPID: frame.foregroundPID, sourceRect: frame.screenRect)
    let scope = try #require(model.guidanceSceneScope)
    #expect(scope.generation == generation && scope.foregroundPID == frame.foregroundPID)
    #expect(scope.sourceRect == frame.screenRect)

    model.guidanceSceneDidChange(scope: scope, reason: reason)

    let stoppedGeneration = model.taskGeneration
    #expect(stoppedGeneration > generation && model.capturePublicationRevision > captureRevision)
    #expect(model.evidence == nil && model.guidanceSceneScope == nil)
    #expect(model.activeGuidanceRequest == nil && !model.busy && model.state == "Ready")
    #expect(model.guidanceSession.workflow?.id == token.workflowID)
    #expect(model.guidanceSession.workflow?.phase == .paused)
    #expect(model.guidanceSession.workflow?.checks.last?.disposition == .interrupted)
    #expect(model.guidanceSession.currentToken == nil && !model.guidanceSession.owns(token))
    #expect(model.selectedContext == "Explicitly selected public memory")
    #expect(model.contextTitle == "Selected memory" && model.input == "Keep this unsent draft")
    #expect(model.scene == notebook && model.section == "Notebook")
    #expect(model.conversationID == conversation && model.messages.map(\.text) == messages)
    #expect(model.notice?.isEmpty == false && model.error == nil)
    model.guidanceSceneDidChange(scope: scope, reason: reason)
    #expect(model.taskGeneration == stoppedGeneration)
    expectNoCaptureOrProvider(model)
  }

  @Test func aQueuedOldScopeCannotCancelAReplacementGuideOrClearItsFrame() throws {
    let model = makeModel()
    defer { model.stop() }
    let first = evidence()
    model.beginScreenGuidance("Guide me through the first public task", speakAloud: false)
    try model.monitorGuidanceScene(
      generation: model.taskGeneration, foregroundPID: first.foregroundPID,
      sourceRect: first.screenRect)
    let oldScope = try #require(model.guidanceSceneScope)
    model.beginScreenGuidance("Guide me through another public task", speakAloud: false)
    let replacement = evidence()
    model.evidence = replacement
    try model.monitorGuidanceScene(
      generation: model.taskGeneration, foregroundPID: replacement.foregroundPID,
      sourceRect: replacement.screenRect)
    let supersededScope = try #require(model.guidanceSceneScope)
    try model.monitorGuidanceScene(
      generation: model.taskGeneration, foregroundPID: replacement.foregroundPID,
      sourceRect: replacement.screenRect)
    let currentScope = try #require(model.guidanceSceneScope)
    let generation = model.taskGeneration
    let captureRevision = model.capturePublicationRevision
    let workflow = model.guidanceSession.workflow
    let token = try #require(model.guidanceSession.currentToken)
    let events = model.diagnosticEvents

    model.guidanceSceneDidChange(scope: oldScope, reason: .foregroundChanged)
    model.guidanceSceneDidChange(scope: oldScope, reason: .scroll)
    model.guidanceSceneDidChange(scope: supersededScope, reason: .scroll)

    #expect(oldScope.leaseID != currentScope.leaseID)
    #expect(supersededScope.generation == currentScope.generation)
    #expect(supersededScope.leaseID != currentScope.leaseID)
    #expect(model.guidanceSceneScope == currentScope && model.taskGeneration == generation)
    #expect(model.capturePublicationRevision == captureRevision && model.busy)
    #expect(ScreenEvidenceIdentity(replacement).matches(model.evidence))
    #expect(model.guidanceSession.workflow == workflow && model.guidanceSession.owns(token))
    #expect(model.diagnosticEvents == events)
    expectNoCaptureOrProvider(model)
  }

  @Test func stopDisarmsObservationAndIdleCannotAcquireANewScope() throws {
    let model = makeModel()
    defer { model.stop() }
    let frame = evidence()
    model.beginScreenGuidance("Guide me through a public task", speakAloud: false)
    try model.monitorGuidanceScene(
      generation: model.taskGeneration, foregroundPID: frame.foregroundPID,
      sourceRect: frame.screenRect)
    let scope = try #require(model.guidanceSceneScope)
    model.stop()
    let generation = model.taskGeneration
    let captureRevision = model.capturePublicationRevision
    let events = model.diagnosticEvents

    model.guidanceSceneDidChange(scope: scope, reason: .scroll)
    #expect(throws: CancellationError.self) {
      try model.monitorGuidanceScene(
        generation: generation, foregroundPID: frame.foregroundPID, sourceRect: frame.screenRect)
    }

    #expect(model.guidanceSceneScope == nil && !model.busy)
    #expect(
      model.taskGeneration == generation && model.capturePublicationRevision == captureRevision)
    #expect(model.diagnosticEvents == events)
    expectNoCaptureOrProvider(model)
  }

  @Test(arguments: [false, true])
  func failureAndNewChatDisarmWithoutLeavingAnOldCallbackAbleToChangeState(_ newChat: Bool) throws {
    let model = makeModel()
    defer { model.stop() }
    let frame = evidence()
    model.beginScreenGuidance("Guide me through a public task", speakAloud: false)
    try model.monitorGuidanceScene(
      generation: model.taskGeneration, foregroundPID: frame.foregroundPID,
      sourceRect: frame.screenRect)
    let scope = try #require(model.guidanceSceneScope)
    if newChat {
      model.newConversation()
    } else {
      model.finishTurnFailure(
        error: ProviderError.message("Public fixture refusal"), generation: model.taskGeneration,
        policy: model.responsePolicy)
    }
    let generation = model.taskGeneration
    let issue = model.error
    let notice = model.notice
    let workflow = model.guidanceSession.workflow
    let events = model.diagnosticEvents

    model.guidanceSceneDidChange(scope: scope, reason: .foregroundChanged)

    #expect(model.guidanceSceneScope == nil && !model.busy)
    #expect(model.taskGeneration == generation && model.error == issue && model.notice == notice)
    #expect(model.guidanceSession.workflow == workflow && model.diagnosticEvents == events)
    expectNoCaptureOrProvider(model)
  }

  @Test(arguments: [GuidanceSceneChange.foregroundChanged, .scroll])
  func aChangedSelectedWindowCannotSilentlyBecomeAFullDisplayOnTypedRetry(
    _ reason: GuidanceSceneChange
  ) throws {
    let model = makeModel()
    defer { model.stop() }
    let notebook = BuiltInLessons.lever()
    model.scene = notebook
    model.selectedContext = "Explicitly selected public file text"
    model.contextTitle = "Selected public file"
    var frame = evidence()
    frame.windowID = 73
    let publicationToken = model.capturePublicationRevision
    let published = model.publishSelectedCapture(frame, token: publicationToken)
    #expect(published && ScreenEvidenceIdentity(frame).matches(model.evidence))
    let prompt = "Show me where to click on this screen"
    model.input = prompt
    model.send()
    #expect(model.responsePolicy.route == .screenGuidance)
    try model.monitorGuidanceScene(
      generation: model.taskGeneration, foregroundPID: frame.foregroundPID,
      sourceRect: frame.screenRect)
    let scope = try #require(model.guidanceSceneScope)

    model.guidanceSceneDidChange(scope: scope, reason: reason)

    #expect(model.evidence == nil)
    #expect(model.selectedContext == "Explicitly selected public file text")
    #expect(model.contextTitle == "Selected public file" && model.scene == notebook)
    // A cancelled capture completion cannot restore provenance or remove the
    // refusal that protects the user's earlier, deliberately narrower scope.
    let latePublication = model.publishSelectedCapture(frame, token: publicationToken)
    #expect(!latePublication && model.evidence == nil)
    let generation = model.taskGeneration
    let captureRevision = model.capturePublicationRevision
    let messages = model.messages.map(\.text)
    model.input = prompt
    model.send()

    #expect(model.taskGeneration == generation && !model.busy)
    #expect(model.capturePublicationRevision == captureRevision && model.input == prompt)
    #expect(model.messages.map(\.text) == messages && model.activeGuidanceRequest == nil)
    #expect(model.notice?.localizedCaseInsensitiveContains("recapture") == true)
    #expect(
      model.selectedContext == "Explicitly selected public file text" && model.scene == notebook)
    expectNoCaptureOrProvider(model)

    // Explicit removal relinquishes that old scope. The next send may declare
    // a new current-screen request; stop it before any actual capture can run.
    model.clearContext()
    model.send()
    #expect(model.taskGeneration > generation && model.busy)
    #expect(model.activeGuidanceRequest != nil && model.responsePolicy.route == .screenGuidance)
    #expect(model.messages.count == messages.count + 1 && model.input.isEmpty)
    #expect(model.scene == notebook)
    model.stop()
    expectNoCaptureOrProvider(model)
  }

  private func makeModel() -> AppModel {
    let model = AppModel(
      acceptanceMode: true, guidanceForegroundPID: { 424_242 },
      screenGuidanceEnabled: { true })
    model.configuration.speechEnabled = false
    return model
  }

  private func evidence() -> OpenCompanion.ScreenEvidence {
    OpenCompanion.ScreenEvidence(
      frameID: UUID(), revision: 1, capturedAt: ProcessInfo.processInfo.systemUptime,
      displayID: 1, foregroundPID: 424_242, foregroundName: "Authored public fixture",
      screenRect: CGRect(x: -600, y: -200, width: 800, height: 600), image: Data(),
      semanticText: "Authored identity only; no pixels captured")
  }

  private func expectNoCaptureOrProvider(_ model: AppModel) {
    #expect(
      !model.diagnosticEvents.contains {
        ["guidance.capture.started", "guidance.capture.accepted", "generation.completed"]
          .contains($0["event"] ?? "")
      })
    #expect(!model.voice.hasPendingSpeech)
  }
}
