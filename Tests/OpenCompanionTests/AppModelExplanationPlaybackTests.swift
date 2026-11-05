import AVFoundation
import CompanionCore
import Foundation
import Testing

@testable import OpenCompanion

@Suite @MainActor struct AppModelExplanationPlaybackTests {
  @Test func partFocusStartsAfterItsRenderAndEndsBeforeTheNextPartNarration() throws {
    let fixture = Fixture()
    let model = fixture.model
    defer { model.stop() }
    var starts: [(VoiceNarrationContext, ExplanationPresentation)] = []
    var ends: [VoiceNarrationContext] = []
    model.onExplanationFocusStarted = { starts.append(($0, $1)) }
    model.onExplanationFocusEnded = { ends.append($0) }
    try fixture.accept(1, narration: "First public block.", focusID: "part-1")
    let first = try #require(model.explanationPresentation)
    try fixture.accept(2, narration: "Second public block.", focusID: "part-2")
    #expect(first.focusID == "part-1" && starts.isEmpty)
    model.acknowledgeExplanationRenderSubmitted(first)
    #expect(starts.count == 1 && starts[0].1.focusID == "part-1")
    let authority = try SceneFocusAuthority.make(
      presentationLease: UUID(), generation: first.generation, beatID: first.beatID,
      document: first.document, focusID: "part-1")
    #expect(model.explanationFocusIsCurrent(authority))
    let queued = try #require(fixture.updates.first { $0.kind == .enqueued })
    fixture.deliver(.started, index: 0, token: queued.token)
    fixture.deliver(.finished, index: 0, token: queued.token)
    #expect(ends == [starts[0].0] && starts.count == 1)
    #expect(!model.explanationFocusIsCurrent(authority))
    let second = try #require(model.explanationPresentation)
    #expect(second.focusID == "part-2")
    model.acknowledgeExplanationRenderSubmitted(second)
    #expect(starts.count == 2 && starts[1].1.focusID == "part-2")
    model.stop()
    #expect(ends == starts.map { $0.0 })
    #expect(!model.explanationFocusIsCurrent(authority))
  }

  @Test func textFallbackOwnsItsDeclaredPartUntilActualCaptionCompletion() throws {
    let fixture = Fixture()
    let model = fixture.model
    defer { model.stop() }
    model.configuration.speechEnabled = false
    model.onNarrationCaptionStarted = { _, _, _ in true }
    var started: VoiceNarrationContext?
    var ended: VoiceNarrationContext?
    model.onExplanationFocusStarted = { context, _ in started = context }
    model.onExplanationFocusEnded = { ended = $0 }
    try fixture.accept(1, narration: "Public block.", focusID: "part-1")
    model.acknowledgeExplanationRenderSubmitted(try #require(model.explanationPresentation))
    let context = try #require(started)
    #expect(ended == nil && fixture.utterances.isEmpty && model.presentingExplanation)
    model.completeExplanationCaption(context: context)
    #expect(ended == context && !model.presentingExplanation)
  }

  @Test func invalidFocusCannotPublishItsSceneOrNarration() throws {
    let fixture = Fixture()
    let model = fixture.model
    defer { model.stop() }
    try fixture.accept(1, narration: "First public block.")
    let canonical = model.scene
    let messages = model.messages.map(\.id)
    #expect(throws: (any Error).self) {
      try fixture.accept(2, narration: "Invalid focused block.", focusID: "not-in-scene")
    }
    #expect(model.scene == canonical && model.messages.map(\.id) == messages)
    #expect(fixture.utterances.isEmpty)
  }

  @Test func canonicalTransactionsCanAdvanceWhileNativePresentationWaitsForSpeech() throws {
    let fixture = Fixture()
    let model = fixture.model
    defer { model.stop() }
    try fixture.accept(1, narration: "First public block.")
    let first = try #require(model.explanationPresentation)
    try fixture.accept(2, narration: "Second public block.")
    #expect(model.scene?.revision == 2 && model.scene?.nodes.count == 2)
    #expect(model.explanationDisplayDocument == first.document)
    #expect(fixture.utterances.isEmpty && model.presentingExplanation)

    model.acknowledgeExplanationRenderSubmitted(first)
    #expect(fixture.utterances.count == 1)
    let queued = try #require(fixture.updates.first { $0.kind == .enqueued })
    fixture.deliver(.started, index: 0, token: queued.token)
    fixture.deliver(.range(location: 0, length: 5), index: 0, token: queued.token)
    #expect(model.explanationPresentation == first)
    fixture.deliver(.finished, index: 0, token: queued.token)
    let second = try #require(model.explanationPresentation)
    #expect(second.beatID != first.beatID && second.document == model.scene)
    #expect(fixture.utterances.count == 1)
    model.acknowledgeExplanationRenderSubmitted(first)
    #expect(fixture.utterances.count == 1)
    model.acknowledgeExplanationRenderSubmitted(second)
    #expect(fixture.utterances.count == 2)
    let queued2 = try #require(fixture.updates.last { $0.kind == .enqueued })
    fixture.deliver(.started, index: 1, token: queued2.token)
    fixture.deliver(.finished, index: 1, token: queued2.token)
    #expect(!model.presentingExplanation)
    #expect(model.scene == second.document && model.explanationDisplayDocument == second.document)
    #expect(model.messages.map(\.text) == ["First public block.", "Second public block."])
  }

  @Test func stopRetainsOnlyLastReleasedVisualAndRejectsLateSpeechAndRenderReceipts() throws {
    let fixture = Fixture()
    let model = fixture.model
    defer { model.stop() }
    try fixture.accept(1, narration: "First public block.")
    let first = try #require(model.explanationPresentation)
    model.acknowledgeExplanationRenderSubmitted(first)
    let queued = try #require(fixture.updates.first)
    try fixture.accept(2, narration: "Second public block.")
    let canonical = model.scene
    model.stop()
    fixture.deliver(.finished, index: 0, token: queued.token)
    model.acknowledgeExplanationRenderSubmitted(first)
    model.completeExplanationCaption(context: queued.context)
    #expect(model.scene == canonical)
    #expect(model.explanationDisplayDocument == first.document)
    #expect(fixture.utterances.count == 1 && !model.presentingExplanation)
    #expect(!model.voice.hasPendingSpeech)
  }

  @Test func speechOffRequiresExplicitLocalCaptionCompletion() throws {
    let fixture = Fixture()
    let model = fixture.model
    defer { model.stop() }
    model.configuration.speechEnabled = false
    var captions: [(VoiceNarrationContext, Bool)] = []
    model.onNarrationCaptionStarted = { _, context, native in
      captions.append((context, native))
      return true
    }
    try fixture.accept(1, narration: "First public block.")
    let first = try #require(model.explanationPresentation)
    model.acknowledgeExplanationRenderSubmitted(first)
    try fixture.accept(2, narration: "Second public block.")
    #expect(captions.count == 1 && !captions[0].1 && fixture.utterances.isEmpty)
    #expect(model.explanationPresentation == first)
    model.completeExplanationCaption(context: captions[0].0)
    let second = try #require(model.explanationPresentation)
    #expect(second.document == model.scene && captions.count == 1)
    model.acknowledgeExplanationRenderSubmitted(second)
    #expect(captions.count == 2)
    model.completeExplanationCaption(context: captions[0].0)
    #expect(model.presentingExplanation)
    model.completeExplanationCaption(context: captions[1].0)
    #expect(!model.presentingExplanation)
  }

  @Test func lostSurfaceRevokesSpeechAndPendingPartsWithoutErasingCanonicalContent() throws {
    let fixture = Fixture()
    let model = fixture.model
    defer { model.stop() }
    try fixture.accept(1, narration: "First public block.")
    let first = try #require(model.explanationPresentation)
    model.acknowledgeExplanationRenderSubmitted(first)
    let queued = try #require(fixture.updates.first)
    try fixture.accept(2, narration: "Second public block.")
    let canonical = model.scene
    model.explanationSurfaceBecameUnavailable(documentID: "unrelated-surface")
    #expect(model.presentingExplanation && model.voice.hasPendingSpeech)
    model.explanationSurfaceBecameUnavailable(documentID: first.document.id)
    fixture.deliver(.finished, index: 0, token: queued.token)
    #expect(!model.presentingExplanation && !model.voice.hasPendingSpeech)
    #expect(model.scene == canonical && model.explanationDisplayDocument == first.document)
    #expect(fixture.utterances.count == 1)
  }

  @Test func sameRevisionUserEditInvalidatesPendingSnapshotsAndKeepsTheEdit() throws {
    let fixture = Fixture()
    let model = fixture.model
    defer { model.stop() }
    try fixture.accept(1, narration: "First public block.")
    let first = try #require(model.explanationPresentation)
    model.acknowledgeExplanationRenderSubmitted(first)
    let queued = try #require(fixture.updates.first)
    try fixture.accept(2, narration: "Second public block.")
    var edited = try #require(model.scene)
    edited.title = "User edit at the same revision"
    let oldGeneration = model.taskGeneration
    model.scene = edited
    fixture.deliver(.finished, index: 0, token: queued.token)
    #expect(!model.presentingExplanation && !model.voice.hasPendingSpeech)
    #expect(model.scene == edited && model.explanationPresentation == nil)
    #expect(fixture.utterances.count == 1)
    #expect(throws: CancellationError.self) {
      try model.accept(
        ProviderUnit(type: "text", text: "Stale future narration."), generation: oldGeneration,
        expectedEvidence: nil)
    }
    #expect(throws: CancellationError.self) { try fixture.accept(3, narration: "Stale part.") }
    #expect(model.scene == edited)
  }

  @Test func queueAndNarrationRejectionHappenBeforeCanonicalPublication() throws {
    let fixture = Fixture()
    let model = fixture.model
    defer { model.stop() }
    for index in 1...ExplanationPlayback.maximumPendingBeats {
      try fixture.accept(index, narration: "Public block \(index).")
    }
    let canonical = model.scene
    let messages = model.messages
    #expect(throws: ExplanationPlaybackError.beatCapacity) {
      try fixture.accept(65, narration: "Too many pending parts.")
    }
    #expect(model.scene == canonical && model.messages.map(\.id) == messages.map(\.id))
    #expect(throws: (any Error).self) {
      try fixture.accept(66, narration: String(repeating: "a", count: 32_001))
    }
    #expect(model.scene == canonical && fixture.utterances.isEmpty)
  }

  @Test func unavailableVoiceDoesNotConsumeDedupeBeforeSuccessfulAdmission() throws {
    let fixture = Fixture()
    let model = fixture.model
    defer { model.stop() }
    for _ in 0..<24 { _ = model.voice.speak("Public occupied voice queue.") }
    try fixture.accept(1, narration: "Public repeated paragraph.")
    model.acknowledgeExplanationRenderSubmitted(try #require(model.explanationPresentation))
    #expect(!model.presentingExplanation)
    model.voice.stop()
    try fixture.accept(2, narration: "Public repeated paragraph.")
    model.acknowledgeExplanationRenderSubmitted(try #require(model.explanationPresentation))
    #expect(model.voice.hasPendingSpeech && fixture.utterances.count == 25)
    #expect(fixture.updates.filter { $0.kind == .enqueued }.count == 1)
  }

  @MainActor private final class Fixture {
    private final class Driver {
      var utterances: [AVSpeechUtterance] = []
    }
    private let driver = Driver()
    var utterances: [AVSpeechUtterance] { driver.utterances }
    var updates: [VoiceUtteranceUpdate] = []
    let model: AppModel

    init() {
      let driver = self.driver
      let voice = VoiceService(nativeSpeak: { driver.utterances.append($0) }, nativeStop: {})
      model = AppModel(acceptanceMode: true, voice: voice)
      model.configuration.speechEnabled = true
      model.onExplanationNarrationEvent = { [weak self] update in self?.updates.append(update) }
      model.configureResponseOutput(.init(route: .notebook, includesExistingNotebook: false))
    }

    func accept(_ index: Int, narration: String, focusID: String? = nil) throws {
      var object: [String: Any] = [
        "type": "scene", "narration": narration,
        "nodes": [["id": "part-\(index)", "kind": "rectangle", "width": 20, "height": 20]],
      ]
      if let focusID { object["focusID"] = focusID }
      let unit = try JSONDecoder().decode(
        ProviderUnit.self,
        from: JSONSerialization.data(withJSONObject: object))
      try model.accept(unit, generation: model.taskGeneration, expectedEvidence: nil)
    }

    func deliver(_ event: VoiceSpeechEvent, index: Int, token: UUID) {
      model.voice.acceptSpeechEvent(
        event, utteranceID: ObjectIdentifier(utterances[index]), token: token,
        observedUptime: ProcessInfo.processInfo.systemUptime)
    }
  }
}
