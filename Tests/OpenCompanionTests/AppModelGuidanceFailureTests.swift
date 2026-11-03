import CompanionCore
import Foundation
import Testing

@testable import OpenCompanion

/// The production failure boundary is exercised without starting a provider,
/// microphone, capture, window, or user's local library.
@Suite @MainActor struct AppModelGuidanceFailureTests {
  @Test func currentGuidanceFailureRemainsVisibleWithoutChangingConversationOrNotebook() throws {
    let model = fixture()
    defer { model.stop() }
    let originalScene = try #require(model.scene)
    let originalMessages = model.messages
    let generation = model.taskGeneration
    let message = "Allow Screen Recording in System Settings, then relaunch OpenCompanion."
    var starts: [(UInt64, Bool)] = []
    var previews: [ProviderTextPreview] = []
    var cancelled: [UInt64] = []
    var notebookOpenings = 0
    model.onCursorResponseStarted = { starts.append(($0, $1)) }
    model.onCursorTextPreview = { actualGeneration, preview in
      #expect(actualGeneration == generation)
      previews.append(preview)
      return true
    }
    model.onCursorCancelled = { cancelled.append($0) }
    model.onSceneReady = { notebookOpenings += 1 }

    model.finishTurnFailure(
      error: ProviderError.message(message), generation: generation, policy: guidancePolicy)

    #expect(model.error == message)
    #expect(!model.busy && model.state == "Ready")
    #expect(model.cursorFailureGeneration == generation)
    #expect(starts.count == 1 && starts.first?.0 == generation && starts.first?.1 == false)
    #expect(previews == [ProviderTextPreview(unitID: 0, text: message, isComplete: true)])
    #expect(cancelled.isEmpty && notebookOpenings == 0)
    #expect(model.messages.map(\.id) == originalMessages.map(\.id))
    #expect(model.messages.map(\.text) == originalMessages.map(\.text))
    #expect(model.scene == originalScene && model.section == "Companion")
    #expect(!model.voice.hasPendingSpeech)
  }

  @Test(arguments: [
    String(repeating: "Long public fixture error. ", count: 100),
    String(repeating: "👨‍👩‍👧‍👦", count: 100), "  \n\t  ",
  ])
  func cursorFailurePreviewIsBoundedButTheFullErrorRemainsAvailable(_ message: String) {
    let model = fixture()
    defer { model.stop() }
    var previews: [ProviderTextPreview] = []
    model.onCursorTextPreview = { _, preview in
      previews.append(preview)
      return true
    }
    model.finishTurnFailure(
      error: ProviderError.message(message), generation: model.taskGeneration,
      policy: guidancePolicy)

    #expect(model.error == message)
    #expect(previews.count == 1)
    #expect(previews.first?.isComplete == true)
    #expect((previews.first?.text.count ?? 0) <= 241)
    #expect((previews.first?.text.utf8.count ?? 0) <= 1_024)
    #expect(previews.first?.text.isEmpty == false)
  }

  @Test func guidanceFailureWithoutCursorCallbacksStillKeepsTheError() {
    let model = fixture()
    defer { model.stop() }
    model.finishTurnFailure(
      error: ProviderError.message("Public permission fixture"),
      generation: model.taskGeneration, policy: guidancePolicy)

    #expect(model.error == "Public permission fixture")
    #expect(!model.busy && model.state == "Ready")
  }

  @Test func staleFailureCannotAlterTheNewGenerationOrItsFeedback() {
    let model = fixture()
    defer { model.stop() }
    let old = model.taskGeneration
    model.stop()
    model.busy = true
    model.state = "Thinking"
    model.error = "Current public fixture error"
    var feedback = 0
    model.onCursorResponseStarted = { _, _ in feedback += 1 }
    model.onCursorTextPreview = { _, _ in
      feedback += 1
      return true
    }
    model.onCursorCancelled = { _ in feedback += 1 }
    let events = model.diagnosticEvents
    model.finishTurnFailure(
      error: ProviderError.message("Stale public fixture error"), generation: old,
      policy: guidancePolicy)

    #expect(model.busy && model.state == "Thinking")
    #expect(model.error == "Current public fixture error")
    #expect(model.cursorFailureGeneration == nil && feedback == 0)
    #expect(model.diagnosticEvents == events)
  }

  @Test func genuineCancellationStaysSilentAndDoesNotReplaceAnExistingError() {
    let model = fixture()
    defer { model.stop() }
    model.error = "Existing public fixture error"
    var starts = 0
    var previews = 0
    var cancelled = 0
    model.onCursorResponseStarted = { _, _ in starts += 1 }
    model.onCursorTextPreview = { _, _ in
      previews += 1
      return true
    }
    model.onCursorCancelled = { _ in cancelled += 1 }
    model.finishTurnFailure(
      error: CancellationError(), generation: model.taskGeneration, policy: guidancePolicy)

    #expect(model.error == "Existing public fixture error")
    #expect(!model.busy && model.state == "Ready")
    #expect(model.cursorFailureGeneration == nil)
    #expect(starts == 0 && previews == 0 && cancelled == 1)
    #expect(!model.diagnosticEvents.contains { $0["event"]?.hasPrefix("guidance.failed.") == true })
  }

  @Test func conversationalFailureKeepsItsExistingCancellationPresentation() {
    let model = fixture()
    defer { model.stop() }
    let policy = ResponsePolicy.resolve(text: "Hello", screenGuidanceEnabled: true)
    model.configureResponseOutput(policy)
    var starts = 0
    var previews = 0
    var cancelled = 0
    model.onCursorResponseStarted = { _, _ in starts += 1 }
    model.onCursorTextPreview = { _, _ in
      previews += 1
      return true
    }
    model.onCursorCancelled = { _ in cancelled += 1 }
    model.finishTurnFailure(
      error: ProviderError.message("Public provider fixture error"),
      generation: model.taskGeneration, policy: policy)

    #expect(model.error == "Public provider fixture error")
    #expect(!model.busy && model.state == "Ready")
    #expect(model.cursorFailureGeneration == nil)
    #expect(starts == 0 && previews == 0 && cancelled == 1)
  }

  @Test func stopDuringFeedbackStartPreventsTheOldErrorPreview() {
    let model = fixture()
    defer { model.stop() }
    var previews = 0
    model.onCursorResponseStarted = { _, _ in model.stop() }
    model.onCursorTextPreview = { _, _ in
      previews += 1
      return true
    }
    let old = model.taskGeneration
    model.finishTurnFailure(
      error: ProviderError.message("Public cancelled fixture error"),
      generation: old, policy: guidancePolicy)

    #expect(model.taskGeneration > old)
    #expect(model.cursorFailureGeneration == nil && previews == 0)
  }

  @Test func failureDiagnosticsContainOnlyClosedStageNames() throws {
    let model = fixture()
    defer { model.stop() }
    let errorMarker = "PUBLIC_ERROR_FIXTURE_MUST_NOT_ENTER_TRACE"
    let target = try JSONDecoder().decode(
      ProviderUnit.self,
      from: Data(
        #"{"type":"target","target":{"x":0.1,"y":0.2,"width":0.1,"height":0.1,"instruction":"Public fixture"}}"#
          .utf8))
    do {
      try model.accept(target, generation: model.taskGeneration, expectedEvidence: nil)
      Issue.record("A target without evidence must be rejected.")
    } catch {
      model.finishTurnFailure(
        error: ProviderError.message(errorMarker), generation: model.taskGeneration,
        policy: guidancePolicy)
    }
    let events = model.diagnosticEvents.compactMap { $0["event"] }
    #expect(events.contains("guidance.stage.prepare"))
    #expect(events.contains("guidance.stage.target"))
    #expect(events.contains("guidance.failed.target"))
    #expect(!model.diagnosticEvents.flatMap { $0.values }.contains { $0.contains(errorMarker) })
  }

  private var guidancePolicy: ResponsePolicy {
    .resolve(text: "Can you open a new chat in ChatGPT?", screenGuidanceEnabled: true)
  }

  private func fixture() -> AppModel {
    let model = AppModel(acceptanceMode: true)
    model.configuration.speechEnabled = false
    model.scene = BuiltInLessons.lever()
    model.messages = [ChatLine(role: "user", text: "Public guidance fixture")]
    model.section = "Companion"
    model.configureResponseOutput(guidancePolicy)
    model.busy = true
    model.state = "Thinking"
    return model
  }
}
