import CompanionCore
import Foundation
import Testing

@testable import OpenCompanion

struct CodexNDJSONOutputTests: Sendable {
  @Test func exactMissingTailAndCompletedOnlyItemsKeepGlobalPreviewIdentity() async throws {
    var output = try bound()
    let events = NDJSONEvents()
    let first = #"{"type":"text","text":"First 😀"}"#
    try await receive(&output, start("one"), events)
    try await receive(&output, delta(String(first.dropLast(2)), id: "one"), events)
    #expect(await events.texts.isEmpty)
    try await receive(&output, complete(first, id: "one"), events)
    // No start and no delta is a valid authoritative owned message.
    try await receive(&output, complete(text("Second"), id: "two"), events)
    try output.finishTurn()
    #expect(await events.texts == ["First 😀", "Second"])
    #expect(await events.previews.filter(\.isComplete).map(\.unitID) == [0, 1])
    let audit = output.audit(outcome: .completed)
    #expect(audit.acceptedUnits == 2 && audit.completedOnlyItems == 1)
    #expect(audit.items[0].appendedSuffixUTF8Bytes == 2)
    #expect(audit.items[1].appendedSuffixUTF8Bytes == text("Second").utf8.count)
  }

  @Test func sequentialItemEOFSeparatesMessagesWithoutInventingNewlines() async throws {
    var output = try bound()
    let events = NDJSONEvents()
    for (index, phase) in ["commentary", "partial_answer", "final_answer"].enumerated() {
      let id = "part-\(index)"
      let value = text("Part \(index)")
      try await receive(&output, start(id, phase: phase), events)
      try await receive(&output, delta(value, id: id), events)
      #expect(await events.texts.count == index)
      try await receive(&output, complete(value, id: id, phase: phase), events)
    }
    try output.finishTurn()
    #expect(await events.texts == ["Part 0", "Part 1", "Part 2"])
    #expect(await events.previews.filter(\.isComplete).map(\.unitID) == [0, 1, 2])
  }

  @Test func duplicateCompletionNeverReplaysAndConflictingCompletionFails() async throws {
    var output = try bound()
    let events = NDJSONEvents()
    let value = text("Once")
    try await receive(&output, complete(value), events)
    try await receive(&output, complete(value), events)
    #expect(await events.texts == ["Once"])
    #expect(output.audit(outcome: .completed).duplicateCompletions == 1)
    await mustReject(&output, complete(text("Changed")), events)
    #expect(await events.texts == ["Once"])
  }

  @Test func mismatchRetainsPreviouslyAdmittedUnitsWithoutAppendingAnyReplacement() async throws {
    var output = try bound()
    let events = NDJSONEvents()
    try await receive(&output, start(), events)
    try await receive(&output, delta(text("Keep") + "\n"), events)
    #expect(output.acceptedUnits == 1)
    await mustReject(&output, complete(text("Replace") + "\n"), events)
    #expect(await events.texts == ["Keep"])
    #expect(output.acceptedUnits == 1)
  }

  @Test func rawUTF8PrefixComparisonRejectsCanonicallyEquivalentDifferentBytes() async throws {
    var output = try bound()
    let events = NDJSONEvents()
    try await receive(&output, start(), events)
    try await receive(&output, delta(text("é") + "\n"), events)
    await mustReject(&output, complete(text("e\u{301}") + "\n"), events)
    #expect(await events.texts == ["é"])
  }

  @Test func foreignAndMissingScopeNeverContaminateOwnedItem() async throws {
    var output = try bound()
    let events = NDJSONEvents()
    try await receive(&output, start(), events)
    for event in [
      delta("bad", thread: "foreign"), delta("bad", turn: "old"),
      complete(text("foreign"), thread: "foreign"),
      Event(method: "item/agentMessage/delta", params: .object(["delta": .string("bad")])),
    ] { try await receive(&output, event, events) }
    try await receive(&output, delta(text("Owned")), events)
    try await receive(&output, complete(text("Owned")), events)
    try output.finishTurn()
    #expect(await events.texts == ["Owned"])
    #expect(output.audit(outcome: .completed).ignoredScopeEvents == 4)
  }

  @Test func contradictoryCompletionScopeCannotEndTheOwnedTurn() throws {
    let output = try bound()
    let nested: JSONValue = .object(["id": .string("turn")])
    let valid: JSONValue = .object([
      "threadId": .string("thread"), "turnId": .string("turn"), "turn": nested,
    ])
    #expect(output.matchesTurn(valid))
    for (direct, nestedID) in [("turn", "other"), ("other", "turn")] {
      let conflict: JSONValue = .object([
        "threadId": .string("thread"), "turnId": .string(direct),
        "turn": .object(["id": .string(nestedID)]),
      ])
      #expect(!output.matchesTurn(conflict))
    }
  }

  @Test func overlapsLateDeltasRestartTypeMutationAndMissingIDFailClosed() async throws {
    let cases: [[Event]] = [
      [start(), start("other")],
      [start(), delta("bad", id: "other")],
      [complete(text("Done")), delta("late")],
      [complete(text("Done")), start()],
      [
        start(),
        Event(
          method: "item/completed",
          params: scope([
            "item": .object(["id": .string("answer"), "type": .string("reasoning")])
          ])),
      ],
      [
        start(), Event(method: "item/agentMessage/delta", params: scope(["delta": .string("bad")])),
      ],
      [start(phase: "final_answer"), complete(text("bad"), phase: "commentary")],
      [complete(text("Done")), complete(text("Done"), phase: nil)],
    ]
    for sequence in cases {
      var output = try bound()
      let events = NDJSONEvents()
      for event in sequence.dropLast() { try await receive(&output, event, events) }
      await mustReject(&output, try #require(sequence.last), events)
    }
  }

  @Test func unknownPhaseRemainsUnknownAndInvalidPhaseIsNotTreatedAsFinal() async throws {
    var output = try bound()
    let events = NDJSONEvents()
    try await receive(&output, start(phase: nil), events)
    try await receive(&output, complete(text("Unknown metadata"), phase: nil), events)
    try output.finishTurn()
    #expect(output.audit(outcome: .completed).items.first?.phase == "unknown")
    var invalid = try bound()
    await mustReject(&invalid, start(phase: "invented"), NDJSONEvents())
  }

  @Test func completedOnlyStillUsesOriginalStrictLineAndTextBounds() async throws {
    for value in [
      "{invalid}", text(String(repeating: "a", count: 32_001)),
      #"{"type":"scene","padding":""# + String(repeating: "x", count: 262_144) + #""}"#,
    ] {
      var output = try bound()
      let events = NDJSONEvents()
      await mustReject(&output, complete(value), events)
      #expect(await events.texts.isEmpty)
    }
  }

  @Test func itemAndBothByteChannelsAreBounded() async throws {
    var items = try bound()
    let events = NDJSONEvents()
    for index in 0..<16 {
      try await receive(&items, complete(text("x"), id: "\(index)"), events)
    }
    await mustReject(&items, complete(text("x"), id: "17"), events)
    var completed = try bound()
    await mustReject(&completed, complete(String(repeating: " ", count: 2_000_001)), NDJSONEvents())
    var deltaOutput = try bound()
    try await receive(&deltaOutput, start(), NDJSONEvents())
    await mustReject(
      &deltaOutput, delta(String(repeating: " ", count: 2_000_001)), NDJSONEvents())
  }

  @Test func cumulativeByteChannelsCannotBeBypassedWithSmallIndividualEvents() async throws {
    var completed = try bound()
    let spaces = String(repeating: " ", count: 250_000)
    let events = NDJSONEvents()
    for index in 0..<8 {
      try await receive(&completed, complete(spaces, id: "\(index)"), events)
    }
    await mustReject(&completed, complete(" ", id: "overflow"), events)
    var deltas = try bound()
    try await receive(&deltas, start(), events)
    for _ in 0..<7 { try await receive(&deltas, delta(spaces + "\n"), events) }
    await mustReject(&deltas, delta(spaces + "\n"), events)
    #expect(await events.texts.isEmpty)
  }

  @Test func successfulTurnRequiresEveryStartedMessageAuthoritativelyCompleted() async throws {
    var output = try bound()
    let events = NDJSONEvents()
    try await receive(&output, start(), events)
    try await receive(&output, delta(text("Already accepted") + "\n"), events)
    do {
      try output.finishTurn()
      Issue.record("Uncompleted item was accepted at turn end")
    } catch {}
    #expect(output.acceptedUnits == 1)
    #expect(await events.texts == ["Already accepted"])
  }

  @Test func cancellationAfterSuccessfulHostAdmissionCountsItAndStopsFollowingUnits() async throws {
    let events = NDJSONEvents()
    let task = Task {
      var output = try bound()
      do {
        try await output.receive(
          method: "item/completed", params: complete(text("Keep") + "\n" + text("Never")).params,
          onUnit: { unit in
            await events.accept(unit)
            withUnsafeCurrentTask { $0?.cancel() }
          })
        Issue.record("Cancellation was not observed")
      } catch {}
      return output.audit(outcome: .cancelled)
    }
    let audit = try await task.value
    #expect(await events.texts == ["Keep"])
    #expect(audit.acceptedUnits == 1)
  }

  @Test func cancellationFromPreviewPreventsCanonicalAdmissionAndAnyReplay() async throws {
    let events = NDJSONEvents()
    let task = Task {
      var output = try bound()
      do {
        try await output.receive(
          method: "item/completed", params: complete(text("Never")).params,
          onUnit: { await events.accept($0) },
          onText: { _ in
            withUnsafeCurrentTask { $0?.cancel() }
          })
        Issue.record("Preview cancellation was not observed")
      } catch {}
      return output.audit(outcome: .cancelled)
    }
    let audit = try await task.value
    #expect(await events.texts.isEmpty)
    #expect(audit.acceptedUnits == 0)
  }

  @Test func auditDoesNotContainPublicCanaryOrRemoteIdentity() async throws {
    var output = try bound()
    let events = NDJSONEvents()
    let canary = "PUBLIC-CANARY-NOT-A-METRIC"
    try await receive(&output, complete(text(canary), id: "REMOTE-PRIVATE-IDENTITY"), events)
    let encoded = String(
      decoding: try JSONEncoder().encode(output.audit(outcome: .completed)), as: UTF8.self)
    #expect(!encoded.contains(canary) && !encoded.contains("REMOTE-PRIVATE-IDENTITY"))
    #expect(encoded.utf8.count < 4_096)
  }

  private struct Event {
    let method: String
    let params: JSONValue
  }
  private func bound() throws -> CodexNDJSONOutput {
    var output = CodexNDJSONOutput(threadID: "thread")
    try output.bind(turnID: "turn")
    return output
  }
  private func scope(
    _ values: [String: JSONValue], thread: String = "thread", turn: String = "turn"
  ) -> JSONValue {
    var values = values
    values["threadId"] = .string(thread)
    values["turnId"] = .string(turn)
    return .object(values)
  }
  private func text(_ value: String) -> String {
    // The prefix-preview recognizer intentionally requires canonical type-first order.
    let quoted = String(
      decoding: try! JSONSerialization.data(withJSONObject: [value]), as: UTF8.self)
    return "{\"type\":\"text\",\"text\":" + quoted.dropFirst().dropLast() + "}"
  }
  private func start(_ id: String = "answer", phase: String? = "final_answer") -> Event {
    var item: [String: JSONValue] = ["id": .string(id), "type": .string("agentMessage")]
    item["phase"] = phase.map(JSONValue.string) ?? .null
    return Event(method: "item/started", params: scope(["item": .object(item)]))
  }
  private func delta(
    _ value: String, id: String = "answer", thread: String = "thread", turn: String = "turn"
  ) -> Event {
    Event(
      method: "item/agentMessage/delta",
      params: scope(["itemId": .string(id), "delta": .string(value)], thread: thread, turn: turn))
  }
  private func complete(
    _ value: String, id: String = "answer", phase: String? = "final_answer",
    thread: String = "thread"
  ) -> Event {
    Event(
      method: "item/completed",
      params: scope(
        [
          "item": .object([
            "id": .string(id), "type": .string("agentMessage"), "text": .string(value),
            "phase": phase.map(JSONValue.string) ?? .null,
          ])
        ], thread: thread))
  }
  private func receive(_ output: inout CodexNDJSONOutput, _ event: Event, _ events: NDJSONEvents)
    async throws
  {
    try await output.receive(
      method: event.method, params: event.params,
      onUnit: { await events.accept($0) }, onText: { await events.preview($0) })
  }
  private func mustReject(_ output: inout CodexNDJSONOutput, _ event: Event, _ events: NDJSONEvents)
    async
  {
    do {
      try await receive(&output, event, events)
      Issue.record("Invalid item was accepted")
    } catch {}
  }
}

private actor NDJSONEvents {
  private(set) var texts: [String] = []
  private(set) var previews: [ProviderTextPreview] = []
  func accept(_ unit: ProviderUnit) { if let text = unit.text { texts.append(text) } }
  func preview(_ value: ProviderTextPreview) { previews.append(value) }
}
