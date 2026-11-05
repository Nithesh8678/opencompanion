import CompanionCore
import Foundation
import Testing

@testable import OpenCompanion

@MainActor struct ExplanationPlaybackTests {
  @Test func immutableSnapshotsWaitForRenderAndExplicitNarrationCompletion() throws {
    let playback = ExplanationPlayback()
    var presentations: [ExplanationPresentation] = []
    var narration: [(VoiceNarrationContext, String)] = []
    var activity: [Bool] = []
    playback.onPresent = { presentations.append($0) }
    playback.onNarration = { narration.append(($0, $1)) }
    playback.onActivityChanged = { activity.append($0) }
    playback.begin(generation: 10)
    var first = document(revision: 1)
    try playback.enqueue(document: first, narration: "First part.")
    first.nodes[0].text = "A later user edit to the caller's value"
    try playback.enqueue(document: document(revision: 2, count: 2), narration: "Second part.")
    #expect(playback.pendingCount == 2 && playback.isActive)
    #expect(presentations.map(\.document.revision) == [1] && narration.isEmpty)
    #expect(playback.currentPresentation?.document.nodes[0].text == "")
    let one = try #require(presentations.first)
    #expect(ack(one, playback))
    #expect(narration.map(\.1) == ["First part."])
    #expect(playback.currentPresentation?.document.revision == 1)
    #expect(playback.completeNarration(context: narration[0].0))
    #expect(presentations.map(\.document.revision) == [1, 2])
    #expect(narration.count == 1)
    #expect(ack(presentations[1], playback))
    #expect(narration.map(\.1) == ["First part.", "Second part."])
    #expect(playback.completeNarration(context: narration[1].0))
    #expect(!playback.isActive && playback.pendingCount == 0)
    #expect(playback.currentPresentation?.document.revision == 2)
    #expect(activity == [true, false])
  }

  @Test func wrongOrRepeatedRenderAndNarrationReceiptsCannotAdvance() throws {
    let playback = ExplanationPlayback()
    var context: VoiceNarrationContext?
    playback.onNarration = {
      context = $0
      _ = $1
    }
    playback.begin(generation: 2)
    try playback.enqueue(document: document(revision: 3), narration: "A part.")
    let presentation = try #require(playback.currentPresentation)
    #expect(
      !playback.acknowledgeRenderSubmitted(
        beatID: UUID(), generation: 2, documentID: "lesson", revision: 3))
    #expect(
      !playback.acknowledgeRenderSubmitted(
        beatID: presentation.beatID, generation: 1, documentID: "lesson", revision: 3))
    #expect(
      !playback.acknowledgeRenderSubmitted(
        beatID: presentation.beatID, generation: 2, documentID: "other", revision: 3))
    #expect(
      !playback.acknowledgeRenderSubmitted(
        beatID: presentation.beatID, generation: 2, documentID: "lesson", revision: 4))
    #expect(context == nil && playback.pendingCount == 1)
    #expect(
      !playback.completeNarration(context: .init(generation: 2, narrationID: presentation.beatID)))
    #expect(ack(presentation, playback))
    #expect(!ack(presentation, playback))
    let accepted = try #require(context)
    #expect(!playback.completeNarration(context: .init(generation: 2, narrationID: UUID())))
    #expect(
      !playback.completeNarration(context: .init(generation: 1, narrationID: accepted.narrationID)))
    #expect(playback.completeNarration(context: accepted))
    #expect(!playback.completeNarration(context: accepted))
  }

  @Test func textOnlyBeatRetainsSceneAndExplicitFallbackCompletionReleasesNext() throws {
    let playback = ExplanationPlayback()
    var presentations: [ExplanationPresentation] = []
    var contexts: [VoiceNarrationContext] = []
    playback.onPresent = { presentations.append($0) }
    playback.onNarration = {
      contexts.append($0)
      _ = $1
    }
    playback.begin(generation: 1)
    try playback.enqueue(document: document(revision: 1), narration: nil)
    #expect(ack(try #require(presentations.first), playback))
    #expect(!playback.isActive)
    let retained = playback.currentPresentation
    try playback.enqueue(document: nil, narration: "  Text fallback keeps every word.\n")
    try playback.enqueue(document: document(revision: 2), narration: nil)
    #expect(playback.currentPresentation == retained && presentations.count == 1)
    // Voice-off fallback supplies this explicit completion; no clock or AV service is involved.
    #expect(playback.completeNarration(context: try #require(contexts.first)))
    #expect(presentations.count == 2 && playback.currentPresentation?.document.revision == 2)
    #expect(ack(presentations[1], playback))
    #expect(playback.pendingCount == 0)
  }

  @Test func nonRenderableGroupPublishesSnapshotWithoutWaitingForARender() throws {
    let playback = ExplanationPlayback()
    var presentations: [ExplanationPresentation] = []
    var contexts: [VoiceNarrationContext] = []
    playback.onPresent = { presentations.append($0) }
    playback.onNarration = {
      contexts.append($0)
      _ = $1
    }
    playback.begin(generation: 1)
    let group = SceneDocument(
      id: "lesson", revision: 1, nodes: [.init(id: "assembly", kind: .group)])
    try playback.enqueue(document: group, narration: "An assembly.")
    #expect(presentations.count == 1 && contexts.count == 1)
    #expect(!ack(presentations[0], playback))
    #expect(playback.completeNarration(context: contexts[0]))
    try playback.enqueue(document: .init(id: "lesson", revision: 2), narration: " \n\t")
    #expect(presentations.count == 2 && playback.pendingCount == 0)
    #expect(playback.currentPresentation?.document.revision == 2)
  }

  @Test func invalidateRevokesQueuedIDsBeforeLateReceiptsAndEqualGenerationCannotRestart() throws {
    let playback = ExplanationPlayback()
    var contexts: [VoiceNarrationContext] = []
    playback.onNarration = {
      contexts.append($0)
      _ = $1
    }
    playback.begin(generation: 8)
    try playback.enqueue(document: document(), narration: "Old narration.")
    let old = try #require(playback.currentPresentation)
    #expect(ack(old, playback))
    try playback.enqueue(document: document(revision: 2), narration: "Never release.")
    playback.invalidate()
    #expect(!playback.isActive && playback.currentPresentation == nil)
    #expect(!ack(old, playback) && !playback.completeNarration(context: contexts[0]))
    playback.begin(generation: 8)
    #expect(throws: ExplanationPlaybackError.inactive) {
      try playback.enqueue(document: nil, narration: "Cannot revive.")
    }
    playback.begin(generation: 9)
    try playback.enqueue(document: document(revision: 3), narration: "New narration.")
    let new = try #require(playback.currentPresentation)
    playback.begin(generation: 7)
    #expect(playback.currentPresentation == new)
    #expect(!ack(old, playback) && !playback.completeNarration(context: contexts[0]))
    #expect(ack(new, playback))
    #expect(contexts.count == 2 && contexts[1].generation == 9)
  }

  @Test func presentationCallbackCanInvalidateBeforeAnyNarrationIsReleased() throws {
    let playback = ExplanationPlayback()
    var narrationCount = 0
    var activity: [Bool] = []
    playback.onActivityChanged = { activity.append($0) }
    playback.onPresent = { _ in playback.invalidate() }
    playback.onNarration = { _, _ in narrationCount += 1 }
    playback.begin(generation: 1)
    try playback.enqueue(document: document(), narration: "Must not start.")
    #expect(narrationCount == 0 && !playback.isActive)
    #expect(playback.currentPresentation == nil && activity == [true, false])
  }

  @Test func activityCallbackCanInvalidateBeforePresentation() throws {
    let playback = ExplanationPlayback()
    var presentations = 0
    var narration = 0
    playback.onActivityChanged = { if $0 { playback.invalidate() } }
    playback.onPresent = { _ in presentations += 1 }
    playback.onNarration = { _, _ in narration += 1 }
    playback.begin(generation: 1)
    try playback.enqueue(document: document(), narration: "Revoked before presentation.")
    #expect(presentations == 0 && narration == 0 && playback.pendingCount == 0)
  }

  @Test func narrationCallbackInvalidationCannotReleaseQueuedScene() throws {
    let playback = ExplanationPlayback()
    var presentations: [ExplanationPresentation] = []
    playback.onPresent = { presentations.append($0) }
    playback.onNarration = { _, _ in playback.invalidate() }
    playback.begin(generation: 1)
    try playback.enqueue(document: document(), narration: "Current.")
    try playback.enqueue(document: document(revision: 2), narration: "Queued.")
    #expect(ack(try #require(presentations.first), playback))
    #expect(presentations.count == 1 && playback.currentPresentation == nil)
    #expect(!playback.isActive)
  }

  @Test func reentrantNewTurnDoesNotLoseOrReplayItsPresentation() throws {
    let playback = ExplanationPlayback()
    var presentations: [ExplanationPresentation] = []
    var contexts: [VoiceNarrationContext] = []
    playback.onPresent = { presentation in
      presentations.append(presentation)
      if presentation.generation == 1 {
        playback.begin(generation: 2)
        do { try playback.enqueue(document: document(revision: 2), narration: "New turn.") } catch {
          Issue.record(error)
        }
      }
    }
    playback.onNarration = {
      contexts.append($0)
      _ = $1
    }
    playback.begin(generation: 1)
    try playback.enqueue(document: document(), narration: "Old turn.")
    #expect(presentations.map(\.generation) == [1, 2] && contexts.isEmpty)
    #expect(!ack(presentations[0], playback))
    #expect(ack(presentations[1], playback))
    #expect(contexts.map(\.generation) == [2])
  }

  @Test func synchronousRenderAndFallbackCallbacksDrainWithoutRecursiveCallbackGrowth() throws {
    let playback = ExplanationPlayback()
    var depth = 0
    var maximumDepth = 0
    var count = 0
    playback.onPresent = { _ = ack($0, playback) }
    playback.onNarration = { context, text in
      depth += 1
      maximumDepth = max(maximumDepth, depth)
      count += 1
      #expect(text == "Fallback \(count)")
      if count < 20 {
        do {
          try playback.enqueue(
            document: document(revision: count + 1), narration: "Fallback \(count + 1)")
        } catch { Issue.record(error) }
      }
      #expect(playback.completeNarration(context: context))
      depth -= 1
    }
    playback.begin(generation: 1)
    try playback.enqueue(document: document(), narration: "Fallback 1")
    #expect(count == 20 && maximumDepth == 1 && !playback.isActive)
    #expect(playback.currentPresentation?.document.revision == 20)
  }

  @Test func beatCapacityCheckIsSideEffectFreeAndEnqueueCannotBypassIt() throws {
    let playback = ExplanationPlayback()
    var contexts: [VoiceNarrationContext] = []
    playback.onNarration = {
      contexts.append($0)
      _ = $1
    }
    playback.begin(generation: 1)
    for _ in 0..<64 { try playback.enqueue(document: nil, narration: "Queued paragraph.") }
    #expect(playback.pendingCount == 64 && contexts.count == 1)
    #expect(throws: ExplanationPlaybackError.beatCapacity) {
      try playback.checkCapacity(document: nil, narration: "One too many.")
    }
    #expect(throws: ExplanationPlaybackError.beatCapacity) {
      try playback.enqueue(document: nil, narration: "One too many.")
    }
    #expect(playback.pendingCount == 64 && contexts.count == 1)
    #expect(playback.completeNarration(context: contexts[0]))
    try playback.checkCapacity(document: nil, narration: "Capacity returned.")
    #expect(playback.pendingCount == 63 && contexts.count == 2)
  }

  @Test func retainedLastSceneAndQueuedSnapshotsShareTheNodeReferenceBudget() throws {
    let playback = ExplanationPlayback()
    playback.begin(generation: 1)
    try playback.enqueue(document: document(count: 1_024), narration: nil)
    #expect(ack(try #require(playback.currentPresentation), playback))
    try playback.enqueue(document: nil, narration: "Hold the last scene while reading.")
    for revision in 2...8 {
      try playback.enqueue(document: document(revision: revision, count: 1_024), narration: nil)
    }
    #expect(playback.pendingCount == 8 && playback.currentPresentation?.document.revision == 1)
    #expect(throws: ExplanationPlaybackError.nodeCapacity) {
      try playback.checkCapacity(document: document(revision: 9), narration: nil)
    }
    #expect(throws: ExplanationPlaybackError.nodeCapacity) {
      try playback.enqueue(document: document(revision: 9), narration: nil)
    }
    playback.invalidate()
    playback.begin(generation: 2)
    try playback.enqueue(document: document(revision: 10, count: 1_024), narration: nil)
    #expect(playback.pendingCount == 1)
  }

  @Test func narrationBudgetsUseUTF8AndReleaseCapacityOnlyAtCompletion() throws {
    let playback = ExplanationPlayback()
    var contexts: [VoiceNarrationContext] = []
    playback.onNarration = {
      contexts.append($0)
      _ = $1
    }
    playback.begin(generation: 1)
    let fullParagraph = String(repeating: "😀", count: 8_000)
    for _ in 0..<4 { try playback.enqueue(document: nil, narration: fullParagraph) }
    try playback.enqueue(document: nil, narration: String(repeating: "x", count: 3_072))
    #expect(throws: ExplanationPlaybackError.narrationCapacity) {
      try playback.enqueue(document: nil, narration: "é")
    }
    #expect(throws: ExplanationPlaybackError.narrationTooLarge) {
      try playback.checkCapacity(document: nil, narration: fullParagraph + "😀")
    }
    #expect(throws: ExplanationPlaybackError.narrationTooLarge) {
      try playback.checkCapacity(document: nil, narration: String(repeating: " ", count: 32_001))
    }
    #expect(playback.pendingCount == 5)
    #expect(playback.completeNarration(context: contexts[0]))
    try playback.checkCapacity(document: nil, narration: fullParagraph)
    #expect(playback.pendingCount == 4)
  }

  @Test func inactiveMalformedAndBlankInputsCannotPublishAPlaybackBeat() throws {
    let playback = ExplanationPlayback()
    #expect(throws: ExplanationPlaybackError.inactive) {
      try playback.checkCapacity(document: nil, narration: "No owner.")
    }
    playback.begin(generation: 0)
    try playback.enqueue(document: nil, narration: " \n\t")
    #expect(!playback.isActive && playback.currentPresentation == nil)
    #expect(throws: ExplanationPlaybackError.invalidDocument) {
      try playback.enqueue(document: .init(id: ""), narration: "Invalid identity.")
    }
    #expect(throws: ExplanationPlaybackError.invalidDocument) {
      try playback.enqueue(document: .init(id: "lesson", revision: -1), narration: nil)
    }
    #expect(playback.pendingCount == 0 && playback.currentPresentation == nil)
  }

  private func ack(_ presentation: ExplanationPresentation, _ playback: ExplanationPlayback) -> Bool
  {
    playback.acknowledgeRenderSubmitted(
      beatID: presentation.beatID, generation: presentation.generation,
      documentID: presentation.document.id, revision: presentation.document.revision)
  }

  private func document(revision: Int = 1, count: Int = 1) -> SceneDocument {
    SceneDocument(
      id: "lesson", revision: revision,
      nodes: (0..<count).map { .init(id: "part-\($0)", kind: .rectangle, width: 20, height: 20) })
  }
}
