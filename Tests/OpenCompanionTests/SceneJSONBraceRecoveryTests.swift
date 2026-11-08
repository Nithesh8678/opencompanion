import CompanionCore
import Foundation
import Testing

@testable import OpenCompanion

struct SceneJSONBraceRecoveryTests {
  private let missing =
    #"{"type":"scene","nodes":[{"id":"body","kind":"mesh","spatial3D":{"geometry":{"type":"sphere","radius":1}}],"removeIDs":[]}"#
  private let extra =
    #"{"type":"scene","nodes":[{"id":"label","kind":"text","text":"Public label"}},{"id":"body","kind":"mesh","spatial3D":{"geometry":{"type":"sphere","radius":1}}}],"removeIDs":[]}"#

  @Test func exactlyOneMissingOrUnexpectedObjectCloseProducesOnlyAScene() throws {
    for value in [missing, extra] {
      let recovered = try SceneJSONBraceRecovery.recover(Data(value.utf8))
      let repaired = try #require(recovered)
      #expect(repaired.type == "scene")
      #expect(repaired.nodes?.contains { $0.id == "body" } == true)
    }
  }

  /// Exact fixed-public model failures: missing initial mesh close and extra
  /// label close. No desktop evidence, private conversation or model invocation.
  @Test func reproducedPublicModelLinesStillPassNormalNativeSceneAdmission() throws {
    let missingInitial =
      ##"{"type":"scene","title":"Butterfly life cycle","nodes":[{"id":"egg","kind":"mesh","fill":"#F2D58A","spatial3D":{"geometry":{"type":"sphere","radius":0.25,"segments":24},"transform":{"position":{"x":-2,"y":1.2,"z":0},"scale":{"x":0.8,"y":1.2,"z":0.8}}}],"narration":"A butterfly begins life as an egg.","focusID":"egg"}"##
    let extraLabel =
      ##"{"type":"scene","nodes":[{"id":"larva1","kind":"mesh","fill":"#75B96B","spatial3D":{"geometry":{"type":"sphere","radius":0.23},"transform":{"position":{"x":1.3,"y":1.05,"z":0}}}},{"id":"larva2","kind":"mesh","fill":"#75B96B","spatial3D":{"geometry":{"type":"sphere","radius":0.25},"transform":{"position":{"x":1.65,"y":1.08,"z":0}}}},{"id":"larva3","kind":"mesh","fill":"#75B96B","spatial3D":{"geometry":{"type":"sphere","radius":0.25},"transform":{"position":{"x":2,"y":1.08,"z":0}}}},{"id":"larva4","kind":"mesh","fill":"#75B96B","spatial3D":{"geometry":{"type":"sphere","radius":0.22},"transform":{"position":{"x":2.34,"y":1.05,"z":0}}}},{"id":"larva-head","kind":"mesh","fill":"#488F57","spatial3D":{"geometry":{"type":"sphere","radius":0.21},"transform":{"position":{"x":2.64,"y":1.02,"z":0}}}},{"id":"larva-label","kind":"text","text":"2 Caterpillar","color":"#FFFFFF","width":150,"height":30,"fontSize":18,"spatial3D":{"labelAnchor":{"targetID":"larva2","leader":true}}}},{"id":"arrow1-stem","kind":"mesh","fill":"#E7E9EF","spatial3D":{"geometry":{"type":"cylinder","radius":0.035,"height":1.1},"transform":{"position":{"x":-0.3,"y":1.1,"z":0},"rotationDegrees":{"x":0,"y":0,"z":-90}}}},{"id":"arrow1-head","kind":"mesh","fill":"#E7E9EF","spatial3D":{"geometry":{"type":"cone","topRadius":0,"bottomRadius":0.11,"height":0.24},"transform":{"position":{"x":0.35,"y":1.1,"z":0},"rotationDegrees":{"x":0,"y":0,"z":-90}}}}],"removeIDs":[],"narration":"The egg hatches into a caterpillar, which eats and grows through several molts.","focusID":"larva2"}"##
    for (value, expectedCount) in [(missingInitial, 1), (extraLabel, 8)] {
      let recovered = try SceneJSONBraceRecovery.recover(Data(value.utf8))
      let unit = try #require(recovered)
      let original = SceneDocument(id: "public-brace-regression")
      let document = try ProviderSceneBoundary.applying(
        unit, to: original, baseRevision: original.revision)
      #expect(document.nodes.count == expectedCount)
      #expect(try document.validated() == document)
    }
  }

  @Test func validJsonIsNeverReinterpretedAndStringBracesEscapesArePreserved() throws {
    let canonical =
      #"{"type":"scene","nodes":[{"id":"label","kind":"text","text":"Literal } ] { \\ \"quoted\" \uD83D\uDE00"}]}"#
    #expect(try SceneJSONBraceRecovery.recover(Data(canonical.utf8)) == nil)
    let malformed = canonical.replacingOccurrences(of: "}]}", with: "}}]}")
    let recovered = try SceneJSONBraceRecovery.recover(Data(malformed.utf8))
    let repaired = try #require(recovered)
    #expect(repaired.nodes?.first?.text == "Literal } ] { \\ \"quoted\" 😀")
    let validButSemanticallyInvalid =
      #"{"type":"scene","nodes":[{"id":"body","kind":"mesh","spatial3D":{"transform":{"position":{"x":1,"y":2}}}}]}"#
    #expect(try SceneJSONBraceRecovery.recover(Data(validButSemanticallyInvalid.utf8)) == nil)
  }

  @Test func rootEofArrayStringCommaKeyValueAndMultipleEditsAreNeverRepaired() throws {
    let failures = [
      #"{"type":"scene","nodes":[]"#,  // Root EOF close.
      #"{"type":"scene","nodes":[]}}"#,  // Extra root close.
      #"{"type":"scene","nodes":[{"id":"n","kind":"text"}}"#,  // Missing array.
      #"{"type":"scene","nodes":[{"id":"n","kind":"text","text":"unfinished}] }"#,
      #"{"type":"scene","nodes":[{"id":"n","kind":"text","text":"bad\q"}}]}"#,
      #"{"type":"scene","nodes":[{"id":"n","kind":"text",}}]}"#,
      #"{"type":"scene","nodes":[{"id" "n","kind":"text"}}]}"#,
      #"{"type":"scene","nodes":[{"id":"n","kind":}}]}"#,
      #"{"type":"scene","nodes":[{"id":"n","kind":"text"}}},{"id":"m","kind":"text"}]}"#,
      #"{"type":"scene","nodes":[{"id":"n","kind":"text","spatial3D":{"transform":{"position":{"x":1,"y":2]}}}"#,
      #"{"type":"scene","nodes":[{"id":"n","kind":"text","width":01}}]}"#,
      #"{"type":"scene","nodes":[{"id":"n","kind":"text","text":"\uD800"}}]}"#,
    ]
    for value in failures {
      #expect(try SceneJSONBraceRecovery.recover(Data(value.utf8)) == nil)
    }
  }

  @Test func otherUnitKindsAndPartialVectorsRemainStrict() throws {
    for kind in ["text", "target", "guidanceStatus", "command"] {
      let candidate = #"{"type":"KIND","nodes":[{"id":"n","kind":"text"}}]}"#
        .replacingOccurrences(of: "KIND", with: kind)
      #expect(try SceneJSONBraceRecovery.recover(Data(candidate.utf8)) == nil)
    }
    let partial =
      #"{"type":"scene","nodes":[{"id":"body","kind":"mesh","spatial3D":{"transform":{"position":{"x":1,"y":2}}}}}]}"#
    #expect(try SceneJSONBraceRecovery.recover(Data(partial.utf8)) == nil)
  }

  @Test func boundsAreCheckedBeforeCandidateAllocationAndNoInsertionCanExceedTheLineCap() throws {
    #expect(try SceneJSONBraceRecovery.recover(Data(repeating: 32, count: 262_145)) == nil)
    let exact = String(repeating: " ", count: 262_144 - missing.utf8.count) + missing
    #expect(exact.utf8.count == 262_144)
    #expect(try SceneJSONBraceRecovery.recover(Data(exact.utf8)) == nil)
    let nested =
      #"{"type":"scene","unused":"# + String(repeating: "[", count: 129)
      + "{}" + String(repeating: "]", count: 129) + "}"
    #expect(try SceneJSONBraceRecovery.recover(Data(nested.utf8)) == nil)
  }

  @Test func defaultDecoderIsStrictAndOptInUsesTheSamePathForNewlineAndItemEof() async throws {
    for value in [missing, extra] {
      var strict = ProviderTextStreamDecoder()
      let denied = SceneBraceEvents()
      do {
        try await strict.append(value + "\n", onUnit: { await denied.accept($0) })
        Issue.record("Default decoding repaired a scene.")
      } catch {}
      #expect(await denied.units.isEmpty && strict.recoveredSceneBraceCount == 0)
      for newline in [false, true] {
        var decoder = ProviderTextStreamDecoder(allowSceneBraceRecovery: true)
        let accepted = SceneBraceEvents()
        let midpoint = value.index(value.startIndex, offsetBy: value.count / 2)
        try await decoder.append(String(value[..<midpoint]), onUnit: { await accepted.accept($0) })
        #expect(await accepted.units.isEmpty)
        try await decoder.append(
          String(value[midpoint...]) + (newline ? "\n" : ""),
          onUnit: { await accepted.accept($0) })
        if !newline { try await decoder.finish(onUnit: { await accepted.accept($0) }) }
        #expect(await accepted.units.count == 1)
        #expect(decoder.acceptedUnits == 1 && decoder.recoveredSceneBraceCount == 1)
      }
    }
  }

  @Test func scenePolicyAndNativeSemanticAdmissionAreNotRelaxedBySyntaxRecovery() async throws {
    var decoder = ProviderTextStreamDecoder(allowSceneBraceRecovery: true)
    let original = SceneDocument(id: "public-retained")
    let state = SceneBraceDocument(original)
    let bad = missing.replacingOccurrences(of: #""radius":1"#, with: #""radius":-1"#)
    do {
      try await decoder.append(bad + "\n", onUnit: { try await state.apply($0) })
      Issue.record("An invalid native geometry was admitted.")
    } catch {}
    #expect(await state.document == original)
    #expect(decoder.acceptedUnits == 0 && decoder.recoveredSceneBraceCount == 1)
  }

  @Test func cancelledGenerationCannotReleaseRecoveredSceneOrCanonicalText() async throws {
    let events = SceneBraceEvents()
    let value = missing
    let task = Task {
      var decoder = ProviderTextStreamDecoder(allowSceneBraceRecovery: true)
      try await decoder.append(value, onUnit: { await events.accept($0) })
      withUnsafeCurrentTask { $0?.cancel() }
      try await decoder.finish(onUnit: { await events.accept($0) })
    }
    do {
      try await task.value
      Issue.record("Cancelled content was admitted.")
    } catch is CancellationError {} catch { Issue.record("Unexpected error: \(error)") }
    #expect(await events.units.isEmpty)
  }

  @Test func rawAuthoritativeBytesStayUnchangedAndDuplicateCompletionNeverReplaysRecovery()
    async throws
  {
    let events = SceneBraceEvents()
    var output = CodexNDJSONOutput(threadID: "thread", allowSceneBraceRecovery: true)
    try output.bind(turnID: "turn")
    try await output.receive(
      method: "item/started",
      params: params(
        item: .object([
          "id": .string("item"), "type": .string("agentMessage"), "phase": .string("final_answer"),
        ])), onUnit: { await events.accept($0) })
    let wire = missing + "\n"
    try await output.receive(
      method: "item/agentMessage/delta",
      params: .object([
        "threadId": .string("thread"), "turnId": .string("turn"),
        "itemId": .string("item"), "delta": .string(wire),
      ]), onUnit: { await events.accept($0) })
    let completion = params(
      item: .object([
        "id": .string("item"), "type": .string("agentMessage"),
        "phase": .string("final_answer"), "text": .string(wire),
      ]))
    for _ in 0..<2 {
      try await output.receive(
        method: "item/completed", params: completion,
        onUnit: { await events.accept($0) })
    }
    try output.finishTurn()
    let audit = output.audit(outcome: .completed)
    #expect(await events.units.count == 1)
    #expect(audit.recoveredSceneBraceCount == 1 && audit.acceptedUnits == 1)
    #expect(audit.items.first?.streamedSHA256 == audit.items.first?.completedSHA256)
    #expect(audit.items.first?.deltaUTF8Bytes == wire.utf8.count)
    #expect(audit.duplicateCompletions == 1)
  }

  @Test func correctedAuthoritativeTextCannotReplaceDifferentMalformedWireBytes() async throws {
    let events = SceneBraceEvents()
    var output = CodexNDJSONOutput(threadID: "thread", allowSceneBraceRecovery: true)
    try output.bind(turnID: "turn")
    try await output.receive(
      method: "item/started",
      params: params(
        item: .object([
          "id": .string("item"), "type": .string("agentMessage"),
        ])), onUnit: { await events.accept($0) })
    try await output.receive(
      method: "item/agentMessage/delta",
      params: .object([
        "threadId": .string("thread"), "turnId": .string("turn"),
        "itemId": .string("item"), "delta": .string(missing + "\n"),
      ]), onUnit: { await events.accept($0) })
    let different = missing.replacingOccurrences(of: "}],", with: "}}],")
    do {
      try await output.receive(
        method: "item/completed",
        params: params(
          item: .object([
            "id": .string("item"), "type": .string("agentMessage"),
            "text": .string(different + "\n"),
          ])), onUnit: { await events.accept($0) })
      Issue.record("Authoritative completion replaced original bytes.")
    } catch {}
    #expect(await events.units.count == 1 && output.acceptedUnits == 1)
  }

  @Test func completedOnlyMessageRecoversOnceAndPreservesGlobalPreviewIds() async throws {
    let events = SceneBraceEvents()
    var output = CodexNDJSONOutput(threadID: "thread", allowSceneBraceRecovery: true)
    try output.bind(turnID: "turn")
    let wire = missing + "\n" + #"{"type":"text","text":"Public narration."}"#
    try await output.receive(
      method: "item/completed",
      params: params(
        item: .object([
          "id": .string("item"), "type": .string("agentMessage"), "text": .string(wire),
        ])), onUnit: { await events.accept($0) }, onText: { await events.preview($0) })
    try output.finishTurn()
    #expect(await events.units.map(\.type) == ["scene", "text"])
    let previews = await events.previews
    // The unterminated text emits its ephemeral preview before the completed
    // item closes it. Both retain the ordinal after the recovered scene.
    #expect(previews.map(\.unitID) == [1, 1])
    #expect(previews.map(\.isComplete) == [false, true])
    #expect(previews.map(\.text) == ["Public narration.", "Public narration."])
    #expect(output.audit(outcome: .completed).recoveredSceneBraceCount == 1)
  }

  private func params(item: JSONValue) -> JSONValue {
    .object(["threadId": .string("thread"), "turnId": .string("turn"), "item": item])
  }
}

private actor SceneBraceEvents {
  private(set) var units: [ProviderUnit] = []
  private(set) var previews: [ProviderTextPreview] = []
  func accept(_ unit: ProviderUnit) { units.append(unit) }
  func preview(_ value: ProviderTextPreview) { previews.append(value) }
}

private actor SceneBraceDocument {
  private(set) var document: SceneDocument
  init(_ document: SceneDocument) { self.document = document }
  func apply(_ unit: ProviderUnit) throws {
    document = try ProviderSceneBoundary.applying(
      unit, to: document, baseRevision: document.revision)
  }
}
