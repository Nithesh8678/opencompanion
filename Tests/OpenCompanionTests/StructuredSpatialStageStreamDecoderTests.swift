import CompanionCore
import Foundation
import Testing

@testable import OpenCompanion

struct StructuredSpatialStageStreamDecoderTests: Sendable {
  @Test func everyASCIISplitAdmitsNativeSceneBeforeNarration() async throws {
    let stage = try Self.stage(text: #"Braces { [ ] } and "quotes" \ \uD83D\uDE00"#)
    let payload = " \n{ \"steps\" : [" + stage + "] }\t"
    let bytes = Array(payload.utf8)
    for split in 0...bytes.count {
      var decoder = StructuredSpatialStageStreamDecoder()
      let events = StageStreamEvents()
      try await append(
        String(decoding: bytes[..<split], as: UTF8.self), to: &decoder, events: events)
      try await append(
        String(decoding: bytes[split...], as: UTF8.self), to: &decoder, events: events)
      try await decoder.finish(onUnit: { try await events.unit($0) })
      #expect(await events.order == ["scene", "preview:1", "text"])
      #expect(await events.nodeIDs == ["part"])
      #expect(decoder.progress == completeProgress(1))
      #expect(decoder.acceptedUnits == 2)
    }
  }

  @Test func scalarFragmentsAndSurrogateEscapesHaveTheSameNativeMeaning() async throws {
    let text = "café e\u{301} 👩🏽‍💻 👨‍👩‍👧‍👦"
    let stage = try Self.stage(text: text)
    var decoder = StructuredSpatialStageStreamDecoder()
    let events = StageStreamEvents()
    for scalar in ("{\"steps\":[" + stage + "]}").unicodeScalars {
      try await append(String(scalar), to: &decoder, events: events)
    }
    try await decoder.finish(onUnit: { try await events.unit($0) })
    #expect(await events.texts == [text])
    var escaped = StructuredSpatialStageStreamDecoder()
    let other = StageStreamEvents()
    let surrogate = try Self.stage(text: "FACE").replacingOccurrences(
      of: "FACE", with: #"\uD83D\uDE00"#)
    for character in "{\"steps\":[" + surrogate + "]}" {
      try await append(String(character), to: &escaped, events: other)
    }
    try await escaped.finish(onUnit: { try await other.unit($0) })
    #expect(await other.texts == ["😀"])
  }

  @Test func completeStageIsDeliveredBeforeEnvelopeCloseAndFinishNeverReplays() async throws {
    var decoder = StructuredSpatialStageStreamDecoder()
    let events = StageStreamEvents()
    try await append("{\"steps\":[" + Self.stage(), to: &decoder, events: events)
    #expect(decoder.progress == completeProgress(1))
    #expect(await events.types == ["scene", "text"])
    try await append("]}", to: &decoder, events: events)
    try await decoder.finish(onUnit: { try await events.unit($0) })
    try await decoder.finish(onUnit: { try await events.unit($0) })
    await expectFailure { try await append(" ", to: &decoder, events: events) }
    #expect(await events.types == ["scene", "text"])
  }

  @Test func nativeSceneRejectionReleasesNoNarrationAndRetainsDecodedStageCount() async throws {
    var decoder = StructuredSpatialStageStreamDecoder()
    let events = StageStreamEvents()
    let badParent = try Self.stage().replacingOccurrences(
      of: #""parentID":null"#, with: #""parentID":"missing-group""#)
    await expectFailure {
      try await append("{\"steps\":[" + badParent + "]}", to: &decoder, events: events)
    }
    #expect(
      decoder.progress
        == .init(
          decodedStages: 1, admittedSceneUnits: 0, admittedTextUnits: 0, completedStages: 0))
    #expect(await events.order.isEmpty)
    #expect(await events.nodeIDs.isEmpty)
    await expectFailure { try await append("]}", to: &decoder, events: events) }
    #expect(await events.order.isEmpty)
  }

  @Test func cancellationAfterSceneAdmissionNeverReleasesItsTextOrReplays() async throws {
    let events = StageStreamEvents()
    let gate = StageStreamGate()
    let first = try Self.stage()
    let second = try Self.stage(id: "second")
    let work = Task {
      var decoder = StructuredSpatialStageStreamDecoder()
      var cancelled = false
      do {
        try await decoder.append(
          "{\"steps\":[" + first + "," + second + "]}",
          onUnit: { value in
            try await events.unit(value)
            if value.type == "scene" { await gate.wait() }
          }, onText: { await events.preview($0) })
      } catch is CancellationError {
        cancelled = true
      }
      let snapshot = decoder.progress
      do {
        try await decoder.append("]}", onUnit: { try await events.unit($0) })
        Issue.record("Cancelled stage stream restarted")
      } catch {}
      return (snapshot, cancelled)
    }
    try await waitUntilEntered(gate)
    #expect(await events.order == ["scene"])
    work.cancel()
    let result = try await work.value
    #expect(result.1)
    #expect(
      result.0
        == .init(
          decodedStages: 1, admittedSceneUnits: 1, admittedTextUnits: 0, completedStages: 0))
    #expect(await events.order == ["scene"])
  }

  @Test func textPreviewBackpressureBlocksTextAdmissionAndTheNextStage() async throws {
    let events = StageStreamEvents()
    let gate = StageStreamGate()
    let first = try Self.stage()
    let second = try Self.stage(id: "second")
    let work = Task {
      var decoder = StructuredSpatialStageStreamDecoder()
      try await decoder.append(
        "{\"steps\":[" + first + "," + second + "]}",
        onUnit: { try await events.unit($0) },
        onText: { value in
          await events.preview(value)
          if value.unitID == 1 { await gate.wait() }
        })
      try await decoder.finish(onUnit: { try await events.unit($0) })
      return decoder.progress
    }
    try await waitUntilEntered(gate)
    #expect(await events.order == ["scene", "preview:1"])
    #expect(await events.nodeIDs == ["part"])
    await gate.release()
    let progress = try await work.value
    #expect(progress == completeProgress(2))
    #expect(await events.order == ["scene", "preview:1", "text", "scene", "preview:3", "text"])
  }

  @Test func rejectedTextCallbackLeavesTheSceneWithoutCompletingItsStage() async throws {
    var decoder = StructuredSpatialStageStreamDecoder()
    let events = StageStreamEvents()
    do {
      try await decoder.append(
        "{\"steps\":[" + Self.stage() + "]}",
        onUnit: { value in
          if value.type == "text" { throw StageStreamTestError.rejected }
          try await events.unit(value)
        }, onText: { await events.preview($0) })
      Issue.record("Text handler rejection unexpectedly succeeded")
    } catch StageStreamTestError.rejected {}
    #expect(
      decoder.progress
        == .init(
          decodedStages: 1, admittedSceneUnits: 1, admittedTextUnits: 0, completedStages: 0))
    #expect(decoder.acceptedUnits == 1)
    #expect(await events.order == ["scene", "preview:1"])
    await expectFailure { try await decoder.finish(onUnit: { try await events.unit($0) }) }
  }

  @Test func strictCompilerRejectsIncompleteMixedDuplicateAndTextOnlyStagesBeforeCallbacks()
    async throws
  {
    let valid = try Self.stage()
    let invalid = [
      #"{"text":"Narration only"}"#,
      valid.replacingOccurrences(of: #""text":"A public sphere.""#, with: #""text":"""#),
      valid.replacingOccurrences(of: #""radius":1"#, with: #""radius":0"#),
      valid.replacingOccurrences(of: #""parts":["#, with: #""operations":[],"parts":["#),
      valid.replacingOccurrences(of: #""geometry":{"#, with: #""kind":"text","geometry":{"#),
      valid.replacingOccurrences(of: #""radius":1"#, with: #""radius":1,"radius":2"#),
      valid.replacingOccurrences(
        of: #""text":"A public sphere.""#, with: #""text":"First","text":"Second""#),
      valid.replacingOccurrences(of: #""text":"A public sphere.""#, with: #""text":"\q""#),
    ]
    for stage in invalid {
      var decoder = StructuredSpatialStageStreamDecoder()
      let events = StageStreamEvents()
      await expectFailure {
        try await append("{\"steps\":[" + stage + "]}", to: &decoder, events: events)
      }
      #expect(
        decoder.progress
          == .init(
            decodedStages: 0, admittedSceneUnits: 0, admittedTextUnits: 0, completedStages: 0))
      #expect(await events.order.isEmpty)
    }
  }

  @Test func invalidRootOrTailRetainsOnlyPreviouslyAdmittedStage() async throws {
    let valid = try Self.stage()
    for tail in [",]}", "]} trailing", "] ,\"steps\":[]}", "] ,\"other\":[]}", "", ",{"] {
      var decoder = StructuredSpatialStageStreamDecoder()
      let events = StageStreamEvents()
      await expectFailure {
        try await append("{\"steps\":[" + valid + tail, to: &decoder, events: events)
        try await decoder.finish(onUnit: { try await events.unit($0) })
      }
      #expect(decoder.progress == completeProgress(1))
      #expect(await events.order == ["scene", "preview:1", "text"])
      await expectFailure { try await decoder.finish(onUnit: { try await events.unit($0) }) }
      #expect(await events.types.count == 2)
    }
    for root in [#"{"steps":[]}"#, #"{"units":[]}"#, #"{"steps":[null]}"#, #"{"other":[]}"#] {
      var decoder = StructuredSpatialStageStreamDecoder()
      let events = StageStreamEvents()
      await expectFailure {
        try await append(root, to: &decoder, events: events)
        try await decoder.finish(onUnit: { try await events.unit($0) })
      }
      #expect(await events.order.isEmpty)
    }
  }

  @Test func stageCountLimitAdmits48AndRejects49WithoutReplay() async throws {
    let stage = try Self.stage()
    for count in [48, 49] {
      var decoder = StructuredSpatialStageStreamDecoder()
      let events = StageStreamEvents()
      let payload =
        "{\"steps\":[" + Array(repeating: stage, count: count).joined(separator: ",") + "]}"
      if count == 48 {
        try await append(payload, to: &decoder, events: events)
        try await decoder.finish(onUnit: { try await events.unit($0) })
      } else {
        await expectFailure { try await append(payload, to: &decoder, events: events) }
      }
      #expect(decoder.progress == completeProgress(48))
      #expect(decoder.acceptedUnits == 96)
      #expect(await events.types.count == 96)
    }
  }

  @Test func stageAndEnvelopeByteLimitsIncludeWhitespaceAndKeepPriorAdmission() async throws {
    let stage = try Self.stage()
    let padding = StructuredSpatialStageStreamDecoder.maximumStageBytes - stage.utf8.count
    for overflow in [0, 1] {
      var decoder = StructuredSpatialStageStreamDecoder()
      let events = StageStreamEvents()
      let padded = "{" + String(repeating: " ", count: padding + overflow) + stage.dropFirst()
      let payload = "{\"steps\":[" + padded + "]}"
      if overflow == 0 {
        try await append(payload, to: &decoder, events: events)
        try await decoder.finish(onUnit: { try await events.unit($0) })
        #expect(decoder.progress == completeProgress(1))
      } else {
        await expectFailure { try await append(payload, to: &decoder, events: events) }
        #expect(decoder.decodedStages == 0)
      }
    }
    let envelope = "{\"steps\":[" + stage + "]}"
    let remaining = StructuredSpatialStageStreamDecoder.maximumTotalBytes - envelope.utf8.count
    var exact = StructuredSpatialStageStreamDecoder()
    let events = StageStreamEvents()
    try await append(
      envelope + String(repeating: " ", count: remaining), to: &exact, events: events)
    try await exact.finish(onUnit: { try await events.unit($0) })
    #expect(exact.progress == completeProgress(1))
    var overflow = StructuredSpatialStageStreamDecoder()
    let retained = StageStreamEvents()
    await expectFailure {
      try await append(
        envelope + String(repeating: " ", count: remaining + 1), to: &overflow, events: retained)
    }
    #expect(overflow.progress == completeProgress(1))
    #expect(await retained.types == ["scene", "text"])
  }

  @Test func excessiveContainerDepthAndPreCancelledTaskDeliverNothing() async throws {
    var decoder = StructuredSpatialStageStreamDecoder()
    let events = StageStreamEvents()
    let nested = String(repeating: "[", count: 32) + "0" + String(repeating: "]", count: 32)
    await expectFailure {
      try await append("{\"steps\":[{\"text\":" + nested + "}]}", to: &decoder, events: events)
    }
    #expect(decoder.decodedStages == 0)
    #expect(await events.order.isEmpty)
    let stage = try Self.stage()
    let outcome = await Task {
      var cancelled = StructuredSpatialStageStreamDecoder()
      withUnsafeCurrentTask { $0?.cancel() }
      do {
        try await cancelled.append(
          "{\"steps\":[" + stage + "]}", onUnit: { try await events.unit($0) })
        Issue.record("Pre-cancelled stage stream succeeded")
      } catch is CancellationError {} catch { Issue.record("Expected cancellation") }
      return cancelled.progress
    }.value
    #expect(
      outcome
        == .init(
          decodedStages: 0, admittedSceneUnits: 0, admittedTextUnits: 0, completedStages: 0))
    #expect(await events.order.isEmpty)
  }

  @Test func progressSnapshotRoundTripsWithoutSceneOrNarrationContent() throws {
    let progress = StructuredSpatialStageProgress(
      decodedStages: 2, admittedSceneUnits: 2, admittedTextUnits: 1, completedStages: 1)
    let data = try JSONEncoder().encode(progress)
    #expect(try JSONDecoder().decode(StructuredSpatialStageProgress.self, from: data) == progress)
    let fields = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(
      Set(fields.keys) == [
        "decodedStages", "admittedSceneUnits", "admittedTextUnits", "completedStages",
      ])
  }

  private static func stage(text: String = "A public sphere.", id: String = "part") throws -> String
  {
    let encodedText = String(decoding: try JSONEncoder().encode(text), as: UTF8.self)
    let encodedID = String(decoding: try JSONEncoder().encode(id), as: UTF8.self)
    return #"{"text":"# + encodedText
      + #", "title":null,"groups":[],"parts":[{"id":"# + encodedID
      + ##","parentID":null,"fill":"#4488CC","opacity":null,"transform":null,"geometry":{"type":"sphere","radius":1,"segments":24}}],"labels":[],"animations":[],"removeIDs":[]}"##
  }

  private func completeProgress(_ stages: Int) -> StructuredSpatialStageProgress {
    .init(
      decodedStages: stages, admittedSceneUnits: stages,
      admittedTextUnits: stages, completedStages: stages)
  }

  private func append(
    _ value: String, to decoder: inout StructuredSpatialStageStreamDecoder,
    events: StageStreamEvents
  ) async throws {
    try await decoder.append(
      value, onUnit: { try await events.unit($0) }, onText: { await events.preview($0) })
  }

  private func expectFailure(_ operation: () async throws -> Void) async {
    do {
      try await operation()
      Issue.record("Invalid or rejected stage unexpectedly succeeded")
    } catch {}
  }

  private func waitUntilEntered(_ gate: StageStreamGate) async throws {
    for _ in 0..<2_000 {
      if await gate.entered { return }
      try await Task.sleep(for: .milliseconds(1))
    }
    await gate.release()
    throw StageStreamTestError.gateDidNotStart
  }
}

private enum StageStreamTestError: Error { case rejected, gateDidNotStart }

private actor StageStreamEvents {
  private var document = SceneDocument(id: "public-stage-stream-fixture")
  private(set) var order: [String] = []
  private(set) var types: [String] = []
  private(set) var texts: [String] = []
  var nodeIDs: [String] { document.nodes.map(\.id) }

  func unit(_ value: ProviderUnit) throws {
    if value.type == "scene" {
      document = try ProviderSceneBoundary.applying(
        value, to: document, baseRevision: document.revision)
    }
    order.append(value.type)
    types.append(value.type)
    if let text = value.text { texts.append(text) }
  }

  func preview(_ value: ProviderTextPreview) { order.append("preview:\(value.unitID)") }
}

private actor StageStreamGate {
  private let stream: AsyncStream<Void>
  private let continuation: AsyncStream<Void>.Continuation
  private(set) var entered = false

  init() {
    (stream, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
  }
  func wait() async {
    entered = true
    var iterator = stream.makeAsyncIterator()
    _ = await iterator.next()
  }
  func release() {
    continuation.yield(())
    continuation.finish()
  }
}
