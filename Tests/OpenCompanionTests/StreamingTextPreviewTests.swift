import Foundation
import Testing

@testable import OpenCompanion

struct StreamingTextPreviewTests {
  @Test func canonicalTextArrivesBeforeItsCompletedUnitOncePerDelta() async throws {
    var decoder = ProviderTextStreamDecoder()
    let received = PreviewEvents()
    try await decoder.append(
      "{\"type\":\"text\",\"text\":\"A useful first clause",
      onUnit: { await received.unit($0) }, onText: { await received.preview($0) })
    #expect(await received.previews == [
      .init(unitID: 0, text: "A useful first clause", isComplete: false)
    ])
    #expect(await received.types.isEmpty)
    try await decoder.append(
      ".\"}", onUnit: { await received.unit($0) }, onText: { await received.preview($0) })
    #expect(await received.previews.last == .init(
      unitID: 0, text: "A useful first clause.", isComplete: false))
    #expect(await received.types.isEmpty)
    try await decoder.append(
      "\n", onUnit: { await received.unit($0) }, onText: { await received.preview($0) })
    #expect(await received.order.suffix(2) == ["complete:0", "unit:text"])
    #expect(decoder.acceptedUnits == 1)
  }

  @Test func escapesAndSurrogatePairsNeverExposeHalfAnEscape() async throws {
    var decoder = ProviderTextStreamDecoder()
    let received = PreviewEvents()
    for fragment in [
      " { \"type\" : \"text\" , \"text\" : \"Hi ",
      "\\uD83", "D", "\\", "uDE", "00", " ",
      "\\\"quoted\\\" \\\\ \\/ \\b\\f\\n\\r\\t \\u03A9",
      " café 👩🏽‍💻\" }\r\n",
    ] {
      try await decoder.append(
        fragment, onUnit: { await received.unit($0) }, onText: { await received.preview($0) })
    }
    let expected = "Hi 😀 \"quoted\" \\ / \u{8}\u{c}\n\r\t Ω café 👩🏽‍💻"
    let previews = await received.previews
    #expect(previews.first?.text == "Hi ")
    #expect(previews[1].text == "Hi 😀")
    #expect(previews.last == .init(unitID: 0, text: expected, isComplete: true))
    #expect(await received.texts == [expected])
    #expect(!previews.contains { $0.text.contains("\\uD83") })
  }

  @Test func unsupportedPrefixesHaveOnlyAValidatedCompleteFallback() async throws {
    for line in [
      #"{"text":"reordered","type":"text"}"#,
      #"{"type":"te\u0078t","text":"escaped type"}"#,
      #"{"type":"text","extra":true,"text":"metadata first"}"#,
    ] {
      var decoder = ProviderTextStreamDecoder()
      let received = PreviewEvents()
      let midpoint = line.index(line.startIndex, offsetBy: line.count / 2)
      try await decoder.append(
        String(line[..<midpoint]), onUnit: { await received.unit($0) },
        onText: { await received.preview($0) })
      #expect(await received.previews.isEmpty)
      try await decoder.append(
        String(line[midpoint...]) + "\n", onUnit: { await received.unit($0) },
        onText: { await received.preview($0) })
      #expect(await received.previews.count == 1)
      #expect(await received.previews.first?.isComplete == true)
      #expect(await received.types == ["text"])
    }
  }

  @Test func sceneAndTargetStayCompleteOnlyAndAdvanceUnitIdentity() async throws {
    var decoder = ProviderTextStreamDecoder()
    let received = PreviewEvents()
    try await decoder.append(
      #"{"type":"scene","title":"not preview text","nodes":[]}"#,
      onUnit: { await received.unit($0) }, onText: { await received.preview($0) })
    #expect(await received.types.isEmpty)
    #expect(await received.previews.isEmpty)
    try await decoder.append(
      "\n\n{\"type\":\"target\",\"target\":{\"x\":0.1,\"y\":0.2,\"width\":0.1,\"height\":0.1,\"instruction\":\"Review\"}}\n"
        + "{\"type\":\"text\",\"text\":\"Now explain",
      onUnit: { await received.unit($0) }, onText: { await received.preview($0) })
    #expect(await received.types == ["scene", "target"])
    #expect(await received.previews == [
      .init(unitID: 2, text: "Now explain", isComplete: false)
    ])
    try await decoder.append(
      "\"}\n", onUnit: { await received.unit($0) }, onText: { await received.preview($0) })
    #expect(await received.previews.last?.unitID == 2)
    #expect(decoder.acceptedUnits == 3)
  }

  @Test func coalescedTransportKeepsCompletedUnitsAndOneFinalPartial() async throws {
    var decoder = ProviderTextStreamDecoder()
    let received = PreviewEvents()
    try await decoder.append(
      " \r\n{\"type\":\"text\",\"text\":\"One\"}\n"
        + "{\"type\":\"text\",\"text\":\"Two\"}\n"
        + "{\"type\":\"text\",\"text\":\"Three",
      onUnit: { await received.unit($0) }, onText: { await received.preview($0) })
    #expect(await received.previews == [
      .init(unitID: 0, text: "One", isComplete: true),
      .init(unitID: 1, text: "Two", isComplete: true),
      .init(unitID: 2, text: "Three", isComplete: false),
    ])
    #expect(await received.texts == ["One", "Two"])
  }

  @Test func invalidLaterLineRetainsEarlierAcceptedContentInTheSameDelta() async throws {
    var decoder = ProviderTextStreamDecoder()
    let received = PreviewEvents()
    do {
      try await decoder.append(
        "{\"type\":\"text\",\"text\":\"Keep me\"}\n{broken}\n",
        onUnit: { await received.unit($0) }, onText: { await received.preview($0) })
      Issue.record("Invalid line unexpectedly accepted")
    } catch {}
    #expect(await received.texts == ["Keep me"])
    #expect(await received.previews == [.init(unitID: 0, text: "Keep me", isComplete: true)])
    #expect(decoder.acceptedUnits == 1)
  }

  @Test func invalidEscapesDoNotAdvancePreviewAndCannotComplete() async throws {
    for suffix in [#"\uD800x"# + #""}"#, #"\uDC00"# + #""}"#, #"\q"# + #""}"#] {
      var decoder = ProviderTextStreamDecoder()
      let received = PreviewEvents()
      try await decoder.append(
        "{\"type\":\"text\",\"text\":\"Safe ",
        onUnit: { await received.unit($0) }, onText: { await received.preview($0) })
      try await decoder.append(
        suffix, onUnit: { await received.unit($0) }, onText: { await received.preview($0) })
      #expect(await received.previews == [.init(unitID: 0, text: "Safe ", isComplete: false)])
      do {
        try await decoder.finish(
          onUnit: { await received.unit($0) }, onText: { await received.preview($0) })
        Issue.record("Invalid JSON escape unexpectedly accepted")
      } catch {}
      #expect(await received.types.isEmpty)
    }
  }

  @Test func malformedCanonicalTailsNeverPublishCompletedText() async throws {
    for tail in [#"","extra":}"#, #""} trailing"#, #"","extra":true"#, #""],"#] {
      var decoder = ProviderTextStreamDecoder()
      let received = PreviewEvents()
      try await decoder.append(
        "{\"type\":\"text\",\"text\":\"Safe partial",
        onUnit: { await received.unit($0) }, onText: { await received.preview($0) })
      try await decoder.append(
        tail, onUnit: { await received.unit($0) }, onText: { await received.preview($0) })
      do {
        try await decoder.finish(
          onUnit: { await received.unit($0) }, onText: { await received.preview($0) })
        Issue.record("Malformed canonical tail unexpectedly accepted")
      } catch {}
      #expect(await received.previews == [
        .init(unitID: 0, text: "Safe partial", isComplete: false)
      ])
      #expect(await received.types.isEmpty)
      #expect(decoder.acceptedUnits == 0)
    }
  }

  @Test func validNoncanonicalTailRequiresFullDecoderFallback() async throws {
    var decoder = ProviderTextStreamDecoder()
    let received = PreviewEvents()
    try await decoder.append(
      #"{"type":"text","text":"Fallback","extra":true}"#,
      onUnit: { await received.unit($0) }, onText: { await received.preview($0) })
    #expect(await received.previews.isEmpty)
    #expect(await received.types.isEmpty)
    try await decoder.finish(onUnit: { await received.unit($0) }, onText: { await received.preview($0) })
    #expect(await received.previews == [.init(unitID: 0, text: "Fallback", isComplete: true)])
    #expect(await received.texts == ["Fallback"])
  }

  @Test func textBudgetCountsUTF8AndAllowsItsExactBoundary() async throws {
    var decoder = ProviderTextStreamDecoder()
    let received = PreviewEvents()
    let bounded = String(repeating: "😀", count: 8_000)
    try await decoder.append(
      "{\"type\":\"text\",\"text\":\"" + bounded,
      onUnit: { await received.unit($0) }, onText: { await received.preview($0) })
    #expect(await received.previews.last?.text.utf8.count == 32_000)
    try await decoder.append(
      "\"}\n", onUnit: { await received.unit($0) }, onText: { await received.preview($0) })
    #expect(await received.texts == [bounded])
    do {
      try await decoder.append(
        "{\"type\":\"text\",\"text\":\"" + bounded + "x\"}\n",
        onUnit: { await received.unit($0) }, onText: { await received.preview($0) })
      Issue.record("Oversized text unexpectedly accepted")
    } catch {}
    #expect(await received.texts.count == 1)
    #expect(await received.previews.allSatisfy { $0.text.utf8.count <= 32_000 })
  }

  @Test func unfinishedLineBudgetIsBoundedBeforeJSONDecode() async throws {
    var decoder = ProviderTextStreamDecoder()
    let received = PreviewEvents()
    do {
      try await decoder.append(
        String(repeating: " ", count: ProviderTextStreamDecoder.maximumLineBytes + 1),
        onUnit: { await received.unit($0) }, onText: { await received.preview($0) })
      Issue.record("Unbounded line unexpectedly accepted")
    } catch {}
    #expect(await received.types.isEmpty)
    #expect(await received.previews.isEmpty)
  }

  @Test func finalLineWithoutNewlineGetsCompleteFallbackExactlyOnce() async throws {
    var decoder = ProviderTextStreamDecoder()
    let received = PreviewEvents()
    try await decoder.append(
      #"{"text":"EOF fallback","type":"text"}"#,
      onUnit: { await received.unit($0) }, onText: { await received.preview($0) })
    #expect(await received.previews.isEmpty)
    try await decoder.finish(onUnit: { await received.unit($0) }, onText: { await received.preview($0) })
    try await decoder.finish(onUnit: { await received.unit($0) }, onText: { await received.preview($0) })
    #expect(await received.previews == [.init(unitID: 0, text: "EOF fallback", isComplete: true)])
    #expect(await received.texts == ["EOF fallback"])
  }

  @Test func previewFailureStopsCanonicalUnitDelivery() async throws {
    var decoder = ProviderTextStreamDecoder()
    let received = PreviewEvents()
    do {
      try await decoder.append(
        "{\"type\":\"text\",\"text\":\"Cancelled preview\"}\n",
        onUnit: { await received.unit($0) }, onText: { _ in throw CancellationError() })
      Issue.record("Cancelled preview unexpectedly accepted")
    } catch is CancellationError {} catch { Issue.record("Unexpected error: \(error)") }
    #expect(await received.types.isEmpty)
  }

  @Test func aCancelledTaskCannotEmitLatePartialOrCanonicalContent() async throws {
    let received = PreviewEvents()
    let task = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      var decoder = ProviderTextStreamDecoder()
      try await decoder.append(
        "{\"type\":\"text\",\"text\":\"Late\"}\n",
        onUnit: { await received.unit($0) }, onText: { await received.preview($0) })
    }
    do {
      try await task.value
      Issue.record("Cancelled task unexpectedly accepted")
    } catch is CancellationError {} catch { Issue.record("Unexpected error: \(error)") }
    #expect(await received.previews.isEmpty)
    #expect(await received.types.isEmpty)
  }

  @Test func cancellationAfterAPartialPreventsItsLaterCommit() async throws {
    let received = PreviewEvents()
    let task = Task {
      var decoder = ProviderTextStreamDecoder()
      try await decoder.append(
        "{\"type\":\"text\",\"text\":\"Ephemeral",
        onUnit: { await received.unit($0) },
        onText: {
          await received.preview($0)
          withUnsafeCurrentTask { $0?.cancel() }
        })
      try await decoder.append(
        "\"}\n", onUnit: { await received.unit($0) }, onText: { await received.preview($0) })
    }
    do {
      try await task.value
      Issue.record("Cancelled partial unexpectedly reached a later commit")
    } catch is CancellationError {} catch { Issue.record("Unexpected error: \(error)") }
    // The caller can clear this ephemeral preview with its own task generation;
    // no completed unit or replacement preview is delivered after cancellation.
    #expect(await received.previews == [.init(unitID: 0, text: "Ephemeral", isComplete: false)])
    #expect(await received.types.isEmpty)
  }
}

private actor PreviewEvents {
  var previews: [ProviderTextPreview] = []
  var types: [String] = []
  var texts: [String] = []
  var order: [String] = []
  func preview(_ value: ProviderTextPreview) {
    previews.append(value)
    order.append(value.isComplete ? "complete:\(value.unitID)" : "partial:\(value.unitID)")
  }
  func unit(_ value: ProviderUnit) {
    types.append(value.type)
    if let text = value.text { texts.append(text) }
    order.append("unit:\(value.type)")
  }
}
