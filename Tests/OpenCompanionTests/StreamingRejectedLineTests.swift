import Foundation
import Testing

@testable import OpenCompanion

struct StreamingRejectedLineTests {
  private static let malformedPublicUnit =
    #"{"type":"scene","nodes":[{"id":"public-part","kind":"mesh","spatial3D":{"geometry":{"type":"sphere","radius":1,"height":2}}}]}"#
  private static let protocolError =
    "Model output did not match the line protocol. Accepted earlier content was retained."

  @Test func optInRecordsOnlyTheExactFailedCompleteLineAndRetainsEarlierAdmission() async throws {
    var decoder = ProviderTextStreamDecoder()
    let events = RejectedLineEvents()
    let rejected = " \t" + Self.malformedPublicUnit + "\r"
    do {
      try await decoder.append(
        "{\"type\":\"text\",\"text\":\"Public accepted narration\"}\n" + rejected + "\n"
          + "{\"type\":\"text\",\"text\":\"Must not replay\"}\n",
        onUnit: { await events.unit($0) }, onText: { await events.preview($0) },
        onRejectedLine: { await events.rejected($0) })
      Issue.record("The invalid geometry unexpectedly decoded")
    } catch {
      #expect(error.localizedDescription == Self.protocolError)
    }
    #expect(await events.rejectedLines == [Data(rejected.utf8)])
    #expect(await events.texts == ["Public accepted narration"])
    #expect(await events.order == ["preview:0", "unit:text", "rejected"])
    #expect(decoder.acceptedUnits == 1)
    try await decoder.finish(
      onUnit: { await events.unit($0) }, onRejectedLine: { await events.rejected($0) })
    #expect(await events.texts == ["Public accepted narration"])
    #expect(await events.rejectedLines.count == 1)
    #expect(decoder.acceptedUnits == 1)
  }

  @Test func partialTransportNeverTriggersDiagnosticUntilItsLineIsFinalized() async throws {
    var decoder = ProviderTextStreamDecoder()
    let events = RejectedLineEvents()
    let split = Self.malformedPublicUnit.index(Self.malformedPublicUnit.startIndex, offsetBy: 30)
    try await decoder.append(
      String(Self.malformedPublicUnit[..<split]), onUnit: { await events.unit($0) },
      onRejectedLine: { await events.rejected($0) })
    #expect(await events.rejectedLines.isEmpty)
    try await decoder.append(
      String(Self.malformedPublicUnit[split...]), onUnit: { await events.unit($0) },
      onRejectedLine: { await events.rejected($0) })
    #expect(await events.rejectedLines.isEmpty)
    do {
      try await decoder.append(
        "\n", onUnit: { await events.unit($0) },
        onRejectedLine: { await events.rejected($0) })
      Issue.record("The finalized invalid unit unexpectedly decoded")
    } catch {
      #expect(error.localizedDescription == Self.protocolError)
    }
    #expect(await events.rejectedLines == [Data(Self.malformedPublicUnit.utf8)])
    #expect(await events.texts.isEmpty && decoder.acceptedUnits == 0)
  }

  @Test func finalLineWithoutNewlineReportsOnceOnlyWhenExplicitlyOptedIn() async throws {
    for optedIn in [false, true] {
      var decoder = ProviderTextStreamDecoder()
      let events = RejectedLineEvents()
      let diagnostic: @Sendable (Data) async -> Void = { await events.rejected($0) }
      let callback = optedIn ? diagnostic : nil
      try await decoder.append(
        Self.malformedPublicUnit, onUnit: { await events.unit($0) }, onRejectedLine: callback)
      do {
        try await decoder.finish(onUnit: { await events.unit($0) }, onRejectedLine: callback)
        Issue.record("The invalid final line unexpectedly decoded")
      } catch {
        #expect(error.localizedDescription == Self.protocolError)
      }
      try await decoder.finish(onUnit: { await events.unit($0) }, onRejectedLine: callback)
      #expect(await events.rejectedLines.count == (optedIn ? 1 : 0))
      #expect(await events.texts.isEmpty && decoder.acceptedUnits == 0)
    }
  }

  @Test func validUnitsAndEmptyLinesNeverTriggerDiagnostics() async throws {
    var decoder = ProviderTextStreamDecoder()
    let events = RejectedLineEvents()
    try await decoder.append(
      " \r\n{\"type\":\"text\",\"text\":\"Public valid narration\"}\n"
        + "{\"type\":\"scene\",\"nodes\":[]}",
      onUnit: { await events.unit($0) }, onRejectedLine: { await events.rejected($0) })
    try await decoder.finish(
      onUnit: { await events.unit($0) }, onRejectedLine: { await events.rejected($0) })
    #expect(await events.rejectedLines.isEmpty)
    #expect(await events.types == ["text", "scene"])
    #expect(decoder.acceptedUnits == 2)
  }

  @Test func semanticAdmissionAndTextBudgetFailuresAreNotDecodeDiagnostics() async throws {
    let events = RejectedLineEvents()
    var semantic = ProviderTextStreamDecoder()
    do {
      try await semantic.append(
        "{\"type\":\"scene\",\"nodes\":[]}\n",
        onUnit: { _ in throw ProviderError.message("Public semantic rejection") },
        onRejectedLine: { await events.rejected($0) })
      Issue.record("The semantic rejection unexpectedly succeeded")
    } catch {
      #expect(error.localizedDescription == "Public semantic rejection")
    }
    var oversized = ProviderTextStreamDecoder()
    do {
      try await oversized.append(
        "{\"type\":\"text\",\"text\":\"" + String(repeating: "x", count: 32_001) + "\"}\n",
        onUnit: { await events.unit($0) }, onRejectedLine: { await events.rejected($0) })
      Issue.record("The text budget rejection unexpectedly succeeded")
    } catch {
      #expect(error.localizedDescription == "Invalid or oversized text unit.")
    }
    #expect(await events.rejectedLines.isEmpty)
    #expect(await events.types.isEmpty)
    #expect(semantic.acceptedUnits == 0 && oversized.acceptedUnits == 0)
  }

  @Test func diagnosticPayloadHonorsExistingLineBoundWithoutOversizeFallback() async throws {
    let events = RejectedLineEvents()
    var decoder = ProviderTextStreamDecoder()
    let bounded =
      String(repeating: " ", count: ProviderTextStreamDecoder.maximumLineBytes - 2) + "{}"
    do {
      try await decoder.append(
        bounded + "\n", onUnit: { await events.unit($0) },
        onRejectedLine: { await events.rejected($0) })
      Issue.record("The missing unit type unexpectedly decoded")
    } catch {
      #expect(error.localizedDescription == Self.protocolError)
    }
    #expect(await events.rejectedLines.first?.count == ProviderTextStreamDecoder.maximumLineBytes)
    var oversize = ProviderTextStreamDecoder()
    do {
      try await oversize.append(
        bounded + "x", onUnit: { await events.unit($0) },
        onRejectedLine: { await events.rejected($0) })
      Issue.record("The oversized line unexpectedly decoded")
    } catch {
      #expect(error.localizedDescription == "A response unit exceeded 256 KiB.")
    }
    #expect(await events.rejectedLines.count == 1)
  }

  @Test func cancelledTaskCannotEmitRejectedContent() async throws {
    let events = RejectedLineEvents()
    let task = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      var decoder = ProviderTextStreamDecoder()
      try await decoder.append(
        Self.malformedPublicUnit + "\n", onUnit: { await events.unit($0) },
        onRejectedLine: { await events.rejected($0) })
    }
    do {
      try await task.value
      Issue.record("The cancelled decoder unexpectedly ran")
    } catch is CancellationError {} catch {
      Issue.record("Unexpected cancellation error: \(error)")
    }
    #expect(await events.rejectedLines.isEmpty)
  }
}

private actor RejectedLineEvents {
  var rejectedLines: [Data] = []
  var types: [String] = []
  var texts: [String] = []
  var order: [String] = []
  func rejected(_ line: Data) {
    rejectedLines.append(line)
    order.append("rejected")
  }
  func unit(_ unit: ProviderUnit) {
    types.append(unit.type)
    if let text = unit.text { texts.append(text) }
    order.append("unit:" + unit.type)
  }
  func preview(_ preview: ProviderTextPreview) { order.append("preview:\(preview.unitID)") }
}
