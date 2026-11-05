import Foundation
import Testing

@testable import OpenCompanion

struct StructuredSceneStreamDecoderTests {
  private static let first = #"{"type":"text","text":"First"}"#
  private static let second = #"{"type":"text","text":"Second"}"#

  @Test func everyASCIISplitPreservesEscapesAndReorderedUnitKeys() async throws {
    let escaped = #"{"text":"Braces { [ ] } and \"quotes\" \\ \/ \uD83D\uDE00","type":"text"}"#
    let scene = #"{"nodes":[{"id":"label","kind":"text","text":"Scene"}],"type":"scene"}"#
    let payload = " \n{ \"units\" : [\n" + escaped + "," + scene + "] }\t"
    let bytes = Array(payload.utf8)
    for split in 0...bytes.count {
      var decoder = StructuredSceneStreamDecoder()
      let events = EnvelopeEvents()
      try await append(
        String(decoding: bytes[..<split], as: UTF8.self), to: &decoder, events: events)
      try await append(
        String(decoding: bytes[split...], as: UTF8.self), to: &decoder, events: events)
      try await decoder.finish(onUnit: { await events.unit($0) })
      #expect(decoder.acceptedUnits == 2)
      #expect(await events.types == ["text", "scene"])
      #expect(await events.texts == ["Braces { [ ] } and \"quotes\" \\ / 😀"])
      #expect(await events.order == ["preview:0", "unit:text", "unit:scene"])
    }
  }

  @Test func unicodeScalarFragmentsPreserveWholeDecodedText() async throws {
    let text = "café e\u{301} 👩🏽‍💻 👨‍👩‍👧‍👦"
    let payload = "{\"units\":[{\"type\":\"text\",\"text\":\"" + text + "\"}]}"
    var decoder = StructuredSceneStreamDecoder()
    let events = EnvelopeEvents()
    for scalar in payload.unicodeScalars {
      try await append(String(scalar), to: &decoder, events: events)
    }
    try await decoder.finish(onUnit: { await events.unit($0) })
    #expect(await events.texts == [text])
    #expect(await events.previews == [.init(unitID: 0, text: text, isComplete: true)])
  }

  @Test func unitIsDeliveredBeforeEnvelopeEndsAndSuccessfulFinishDoesNotReplay() async throws {
    var decoder = StructuredSceneStreamDecoder()
    let events = EnvelopeEvents()
    try await append("{\"units\":[" + Self.first, to: &decoder, events: events)
    #expect(await events.texts == ["First"])
    #expect(decoder.acceptedUnits == 1)
    try await append("," + Self.second + "]}", to: &decoder, events: events)
    try await decoder.finish(onUnit: { await events.unit($0) })
    try await decoder.finish(onUnit: { await events.unit($0) })
    #expect(await events.texts == ["First", "Second"])
    await expectFailure { try await decoder.append(" ", onUnit: { await events.unit($0) }) }
    #expect(await events.types.count == 2)
  }

  @Test func malformedRootArraysAndUnitsFailClosed() async {
    let invalid = [
      "[]", "null", "{}", #"{"other":[]}"#, #"{"units":null}"#,
      #"{"units":[null]}"#, #"{"units":[1]}"#, #"{"units":[[]]}"#,
      #"{"units":[,]}"#, #"{"units":[{"type":"text"}]}"#,
      #"{"units":[{"type":"text","text":1}]}"#,
      #"{"units":[{"type":"text","text":"\q"}]}"#,
      #"{"units":[{"type":"text","text":"\uD800"}]}"#,
      #"{"units":[{"type":"text","text":"\uDC00"}]}"#,
      #"{"units":[{"type":"text","text":"Bad"],"x":0}]}"#,
      #"{"uni ts":[]}"#, #"{"\u0075nits":[]}"#,
    ]
    for payload in invalid {
      var decoder = StructuredSceneStreamDecoder()
      let events = EnvelopeEvents()
      await expectFailure {
        try await append(payload, to: &decoder, events: events)
        try await decoder.finish(onUnit: { await events.unit($0) })
      }
      #expect(decoder.acceptedUnits == 0)
      #expect(await events.types.isEmpty)
      await expectFailure {
        try await append("{\"units\":[" + Self.first + "]}", to: &decoder, events: events)
      }
      #expect(await events.types.isEmpty)
    }
  }

  @Test func emptyArrayIsTerminalAndCannotBeReplaced() async throws {
    var decoder = StructuredSceneStreamDecoder()
    let events = EnvelopeEvents()
    try await append(#"{"units":[]}"#, to: &decoder, events: events)
    await expectFailure { try await decoder.finish(onUnit: { await events.unit($0) }) }
    await expectFailure {
      try await append("{\"units\":[" + Self.first + "]}", to: &decoder, events: events)
    }
    #expect(decoder.acceptedUnits == 0)
    #expect(await events.types.isEmpty)
  }

  @Test func emptyTextIsRejectedBeforePreviewOrHostAdmissionButWhitespaceRemainsValid() async throws
  {
    var decoder = StructuredSceneStreamDecoder()
    let rejected = EnvelopeEvents()
    await expectFailure {
      try await append(#"{"units":[{"type":"text","text":""}]}"#, to: &decoder, events: rejected)
    }
    #expect(decoder.acceptedUnits == 0)
    #expect(await rejected.order.isEmpty)
    await expectFailure { try await decoder.finish(onUnit: { await rejected.unit($0) }) }
    #expect(await rejected.order.isEmpty)

    var whitespace = StructuredSceneStreamDecoder()
    let accepted = EnvelopeEvents()
    try await append(#"{"units":[{"type":"text","text":" "}]}"#, to: &whitespace, events: accepted)
    try await whitespace.finish(onUnit: { await accepted.unit($0) })
    #expect(whitespace.acceptedUnits == 1)
    #expect(await accepted.texts == [" "])
  }

  @Test func nonSceneActionsNeverReachHostCallbacks() async {
    for unit in [
      #"{"type":"target","target":{"x":0.1,"y":0.1,"width":0.1,"height":0.1,"instruction":"Review"}}"#,
      #"{"type":"action"}"#, #"{"type":"tool"}"#, #"{"type":"unknown"}"#,
    ] {
      var decoder = StructuredSceneStreamDecoder()
      let events = EnvelopeEvents()
      await expectFailure {
        try await append("{\"units\":[" + unit + "]}", to: &decoder, events: events)
      }
      #expect(await events.order.isEmpty)
      #expect(decoder.acceptedUnits == 0)
    }
  }

  @Test func unknownMixedAndDuplicateUnitFieldsAreRejectedRegardlessOfKeyOrder() async {
    for unit in [
      #"{"type":"text","text":"Safe","nodes":[]}"#,
      #"{"nodes":[],"type":"scene","text":"Mixed"}"#,
      #"{"type":"scene","nodes":[],"operations":[]}"#,
      #"{"parameters":{},"type":"scene","nodes":[]}"#,
      #"{"type":"scene","target":null,"nodes":[]}"#,
      #"{"type":"scene","unknown":true,"nodes":[]}"#,
      #"{"type":"text","text":"First","text":"Second"}"#,
      #"{"type":"scene","nodes":[],"\u006eodes":[]}"#,
      #"{"type":"text","text":"Safe","type":"scene"}"#,
    ] {
      var decoder = StructuredSceneStreamDecoder()
      let events = EnvelopeEvents()
      await expectFailure {
        try await append("{\"units\":[" + unit + "]}", to: &decoder, events: events)
      }
      #expect(decoder.acceptedUnits == 0)
      #expect(await events.order.isEmpty)
    }
  }

  @Test func invalidTailRetainsEarlierAcceptedUnitsWithoutReplay() async {
    for tail in [
      ",]}", "]} trailing", "] ,\"other\":0}", "] ,\"units\":[]}",
      #",{"type":"text","text":"\q"}]}"#,
      #",{"type":"scene","nodes":["#,
      "]", "", "," + Self.second,
    ] {
      var decoder = StructuredSceneStreamDecoder()
      let events = EnvelopeEvents()
      await expectFailure {
        try await append("{\"units\":[" + Self.first + tail, to: &decoder, events: events)
        try await decoder.finish(onUnit: { await events.unit($0) })
      }
      let retained = await events.texts
      #expect(retained.first == "First")
      #expect(decoder.acceptedUnits == retained.count)
      await expectFailure { try await decoder.finish(onUnit: { await events.unit($0) }) }
      await expectFailure { try await append("]}", to: &decoder, events: events) }
      #expect(await events.texts == retained)
    }
  }

  @Test func callbackBackpressureStopsBeforeTheNextUnit() async throws {
    let events = EnvelopeEvents()
    let gate = EnvelopeGate()
    let work = Task {
      var decoder = StructuredSceneStreamDecoder()
      try await decoder.append("{\"units\":[" + Self.first + "," + Self.second + "]}") { value in
        await events.unit(value)
        if value.text == "First" { await gate.wait() }
      }
      try await decoder.finish(onUnit: { await events.unit($0) })
      return decoder.acceptedUnits
    }
    try await waitUntilEntered(gate)
    #expect(await events.texts == ["First"])
    await gate.release()
    let accepted = try await work.value
    #expect(accepted == 2)
    #expect(await events.texts == ["First", "Second"])
  }

  @Test func cancellationDuringHostAdmissionNeverDeliversNextUnit() async throws {
    let events = EnvelopeEvents()
    let gate = EnvelopeGate()
    let work = Task {
      var decoder = StructuredSceneStreamDecoder()
      var cancelled = false
      do {
        try await decoder.append("{\"units\":[" + Self.first + "," + Self.second + "]}") { value in
          await events.unit(value)
          await gate.wait()
        }
      } catch is CancellationError {
        cancelled = true
      }
      return (decoder.acceptedUnits, cancelled)
    }
    try await waitUntilEntered(gate)
    work.cancel()
    let result = try await work.value
    #expect(result.0 == 1)
    #expect(result.1)
    #expect(await events.texts == ["First"])
  }

  @Test func cancellationBeforeParsingAndAfterPreviewAreSilentForUnitAdmission() async throws {
    for cancelAtPreview in [false, true] {
      let events = EnvelopeEvents()
      let result = await Task {
        var decoder = StructuredSceneStreamDecoder()
        if !cancelAtPreview { withUnsafeCurrentTask { $0?.cancel() } }
        var cancelled = false
        do {
          try await decoder.append(
            "{\"units\":[" + Self.first + "]}", onUnit: { await events.unit($0) },
            onText: { value in
              await events.preview(value)
              withUnsafeCurrentTask { $0?.cancel() }
            })
        } catch is CancellationError {
          cancelled = true
        } catch {
          Issue.record("Expected cancellation")
        }
        return (decoder.acceptedUnits, cancelled)
      }.value
      #expect(result.0 == 0)
      #expect(result.1)
      #expect(await events.types.isEmpty)
      #expect(await events.previews.count == (cancelAtPreview ? 1 : 0))
    }
  }

  @Test func rejectedHostCallbackIsTerminalAndEarlierContentSurvives() async throws {
    var decoder = StructuredSceneStreamDecoder()
    let events = EnvelopeEvents()
    do {
      try await decoder.append("{\"units\":[" + Self.first + "," + Self.second + "]}") { value in
        if value.text == "Second" { throw EnvelopeTestError.rejected }
        await events.unit(value)
      }
      Issue.record("Rejected callback unexpectedly succeeded")
    } catch EnvelopeTestError.rejected {}
    #expect(decoder.acceptedUnits == 1)
    await expectFailure { try await append(" ", to: &decoder, events: events) }
    #expect(await events.texts == ["First"])
  }

  @Test func textBoundIsMeasuredInDecodedUTF8Bytes() async throws {
    let exact = String(repeating: "é", count: 16_000)
    var decoder = StructuredSceneStreamDecoder()
    let events = EnvelopeEvents()
    try await append(textEnvelope(exact), to: &decoder, events: events)
    try await decoder.finish(onUnit: { await events.unit($0) })
    #expect(await events.texts == [exact])
    var tooLarge = StructuredSceneStreamDecoder()
    let rejected = EnvelopeEvents()
    await expectFailure {
      try await append(textEnvelope(exact + "a"), to: &tooLarge, events: rejected)
    }
    #expect(await rejected.order.isEmpty)
  }

  @Test func unitByteBudgetAllowsExactLimitAndRejectsOneMoreByte() async throws {
    let prefix = #"{"type":"scene","title":""#
    let suffix = #"","nodes":[]}"#
    let padding =
      StructuredSceneStreamDecoder.maximumUnitBytes - prefix.utf8.count - suffix.utf8.count
    for overflow in [0, 1] {
      var decoder = StructuredSceneStreamDecoder()
      let events = EnvelopeEvents()
      let unit = prefix + String(repeating: "x", count: padding + overflow) + suffix
      let payload = "{\"units\":[" + unit + "]}"
      if overflow == 0 {
        try await append(payload, to: &decoder, events: events)
        try await decoder.finish(onUnit: { await events.unit($0) })
        #expect(decoder.acceptedUnits == 1)
      } else {
        await expectFailure { try await append(payload, to: &decoder, events: events) }
        #expect(await events.types.isEmpty)
      }
    }
  }

  @Test func totalByteBudgetRetainsTheUnitBeforeOverflowInTheSameDelta() async throws {
    let envelope = "{\"units\":[" + Self.first + "]}"
    let remaining = StructuredSceneStreamDecoder.maximumTotalBytes - envelope.utf8.count
    for overflow in [0, 1] {
      var decoder = StructuredSceneStreamDecoder()
      let events = EnvelopeEvents()
      let payload = envelope + String(repeating: " ", count: remaining + overflow)
      if overflow == 0 {
        try await append(payload, to: &decoder, events: events)
        try await decoder.finish(onUnit: { await events.unit($0) })
      } else {
        await expectFailure { try await append(payload, to: &decoder, events: events) }
      }
      #expect(decoder.acceptedUnits == 1)
      #expect(await events.texts == ["First"])
    }
  }

  @Test func unitCountCapDoesNotReplayOrAdmitTheOverflowUnit() async throws {
    for count in [96, 97] {
      var decoder = StructuredSceneStreamDecoder()
      let events = EnvelopeEvents()
      let payload =
        "{\"units\":[" + Array(repeating: Self.first, count: count).joined(separator: ",") + "]}"
      if count == 96 {
        try await append(payload, to: &decoder, events: events)
        try await decoder.finish(onUnit: { await events.unit($0) })
      } else {
        await expectFailure { try await append(payload, to: &decoder, events: events) }
      }
      #expect(decoder.acceptedUnits == 96)
      #expect(await events.types.count == 96)
    }
  }

  @Test func nestedContainersAreBoundedEvenWhenNativeDecodingIgnoresTheField() async throws {
    // Unit object + nodes array + node object leave 29 frames within the 32-frame limit.
    for depth in [29, 30] {
      var decoder = StructuredSceneStreamDecoder()
      let events = EnvelopeEvents()
      let nested = String(repeating: "[", count: depth) + "0" + String(repeating: "]", count: depth)
      let payload =
        #"{"units":[{"type":"scene","nodes":[{"id":"group","kind":"group","extra":"#
        + nested + #"}]}]}"#
      if depth == 29 {
        try await append(payload, to: &decoder, events: events)
        try await decoder.finish(onUnit: { await events.unit($0) })
        #expect(decoder.acceptedUnits == 1)
      } else {
        await expectFailure { try await append(payload, to: &decoder, events: events) }
        #expect(await events.types.isEmpty)
      }
    }
  }

  private func append(
    _ value: String, to decoder: inout StructuredSceneStreamDecoder, events: EnvelopeEvents
  ) async throws {
    try await decoder.append(
      value, onUnit: { await events.unit($0) }, onText: { await events.preview($0) })
  }

  private func expectFailure(_ operation: () async throws -> Void) async {
    do {
      try await operation()
      Issue.record("Invalid structured envelope unexpectedly succeeded")
    } catch {}
  }

  private func textEnvelope(_ text: String) -> String {
    "{\"units\":[{\"type\":\"text\",\"text\":\"" + text + "\"}]}"
  }

  private func waitUntilEntered(_ gate: EnvelopeGate) async throws {
    for _ in 0..<200 {
      if await gate.entered { return }
      try await Task.sleep(for: .milliseconds(1))
    }
    await gate.release()
    throw EnvelopeTestError.gateDidNotStart
  }
}

private enum EnvelopeTestError: Error { case rejected, gateDidNotStart }

private actor EnvelopeEvents {
  private(set) var types: [String] = []
  private(set) var texts: [String] = []
  private(set) var previews: [ProviderTextPreview] = []
  private(set) var order: [String] = []
  func unit(_ value: ProviderUnit) {
    types.append(value.type)
    if let text = value.text { texts.append(text) }
    order.append("unit:" + value.type)
  }
  func preview(_ value: ProviderTextPreview) {
    previews.append(value)
    order.append("preview:\(value.unitID)")
  }
}

private actor EnvelopeGate {
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
