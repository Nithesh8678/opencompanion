import Foundation
import Testing

@testable import OpenCompanion

struct ProviderLineWireClockTests {
  @Test func fragmentedBytesUseObservedArrivalTimesAndExcludeOnlyLF() {
    var clock = ProviderLineWireClock()
    for _ in 0..<5 { clock.appendByte(observedAt: 10) }
    for _ in 0..<3 { clock.appendByte(observedAt: 12) }
    let sample = clock.finishLine(observedAt: 13, termination: .newline)
    #expect(
      sample
        == .init(
          startedUptime: 10, completedUptime: 13, utf8Bytes: 8, termination: .newline))
    let empty = clock.finishLine(observedAt: 14, termination: .newline)
    #expect(empty == nil)
    clock.appendByte(observedAt: 15)
    let eof = clock.finishLine(observedAt: 16, termination: .endOfStream)
    #expect(eof?.termination == .endOfStream)
  }

  @Test func invalidOrBackwardsClockDropsOnlyItsLineAndResetRevokesPartialState() {
    for invalid in [Double.nan, Double.infinity, -1] {
      var clock = ProviderLineWireClock()
      clock.appendByte(observedAt: invalid)
      clock.appendByte(observedAt: 10)
      let rejected = clock.finishLine(observedAt: 11, termination: .newline)
      #expect(rejected == nil)
      clock.appendByte(observedAt: 12)
      let next = clock.finishLine(observedAt: 13, termination: .newline)
      #expect(next?.utf8Bytes == 1)
    }
    var clock = ProviderLineWireClock()
    clock.appendByte(observedAt: 12)
    clock.appendByte(observedAt: 11)
    let backwardsByte = clock.finishLine(observedAt: 13, termination: .newline)
    #expect(backwardsByte == nil)
    clock.appendByte(observedAt: 14)
    let backwardsEnd = clock.finishLine(observedAt: 13, termination: .newline)
    #expect(backwardsEnd == nil)
    clock.appendByte(observedAt: 15)
    clock.reset()
    clock.appendByte(observedAt: 20)
    let afterReset = clock.finishLine(observedAt: 21, termination: .newline)
    #expect(afterReset?.startedUptime == 20)
  }

  @Test func byteBudgetIsExactAndCannotOverflowOrLeakIntoTheNextLine() {
    var clock = ProviderLineWireClock()
    for _ in 0..<ProviderLineWireClock.maximumLineBytes { clock.appendByte(observedAt: 10) }
    let exact = clock.finishLine(observedAt: 11, termination: .newline)
    #expect(exact?.utf8Bytes == 262_144)
    for _ in 0...ProviderLineWireClock.maximumLineBytes { clock.appendByte(observedAt: 12) }
    let oversized = clock.finishLine(observedAt: 13, termination: .newline)
    #expect(oversized == nil)
    clock.appendByte(observedAt: 14)
    let next = clock.finishLine(observedAt: 15, termination: .newline)
    #expect(next?.utf8Bytes == 1)
  }

  @Test func decoderClassifiesTypeLastAndEscapedKeysOnlyAfterItsAuthoritativeDecode() async throws {
    var decoder = ProviderTextStreamDecoder()
    let receiver = WireClockReceiver()
    let fragments = [
      #"{"title":"a \"type\":\"scene\" decoy Ω","nodes":[],"ty\u00"#,
      #"70e":"sc\u0065"#,
      #"ne"}"#,
    ]
    for fragment in fragments {
      try await decoder.append(
        fragment, onUnit: { await receiver.unit($0) },
        onSceneLineDecoded: { await receiver.sample($0) })
      #expect(await receiver.samples.isEmpty)
      #expect(await receiver.types.isEmpty)
    }
    try await decoder.append(
      "\r\n", onUnit: { await receiver.unit($0) },
      onSceneLineDecoded: { await receiver.sample($0) })
    #expect(await receiver.types == ["scene"])
    let sample = try #require(await receiver.samples.first)
    #expect(sample.utf8Bytes == fragments.joined().utf8.count + 1)
    #expect(sample.termination == .newline)
    #expect(await receiver.order == ["decoded", "unit:scene"])
    #expect(decoder.acceptedUnits == 1)
  }

  @Test func coalescedLineTimesAreCapturedBeforeEarlierAwaitedHandlers() async throws {
    var decoder = ProviderTextStreamDecoder()
    let receiver = WireClockReceiver()
    try await decoder.append(
      " \r\n{\"type\":\"text\",\"text\":\"A public paragraph.\"}\n"
        + "{\"type\":\"scene\",\"nodes\":[]}\n{\"type\":\"scene\",\"nodes\":[]}\n",
      onUnit: {
        await receiver.unit($0)
        await Task.yield()
      }, onSceneLineDecoded: { await receiver.sample($0) })
    let samples = await receiver.samples
    let firstHandler = try #require(await receiver.firstHandlerUptime)
    #expect(samples.count == 2)
    #expect(samples.allSatisfy { $0.completedUptime <= firstHandler })
    #expect(samples[0].startedUptime == samples[1].startedUptime)
    #expect(samples[0].completedUptime == samples[1].completedUptime)
    #expect(await receiver.types == ["text", "scene", "scene"])
  }

  @Test func unfinishedEOFIsExplicitAndNeverInventsANewlineBoundary() async throws {
    var decoder = ProviderTextStreamDecoder()
    let receiver = WireClockReceiver()
    try await decoder.append(
      #"{"type":"scene","nodes":[]}"#, onUnit: { await receiver.unit($0) },
      onSceneLineDecoded: { await receiver.sample($0) })
    #expect(await receiver.samples.isEmpty)
    try await decoder.finish(
      onUnit: { await receiver.unit($0) }, onSceneLineDecoded: { await receiver.sample($0) })
    #expect(await receiver.samples.count == 1)
    #expect(await receiver.samples.first?.termination == .endOfStream)
    #expect(await receiver.types == ["scene"])
  }

  @Test func invalidDecodeNeverClassifiesSceneAndRetainsEarlierAcceptedUnits() async throws {
    var decoder = ProviderTextStreamDecoder()
    let receiver = WireClockReceiver()
    do {
      try await decoder.append(
        "{\"type\":\"text\",\"text\":\"Earlier accepted.\"}\n"
          + "{\"type\":\"scene\",\"nodes\":[}\n",
        onUnit: { await receiver.unit($0) },
        onSceneLineDecoded: { await receiver.sample($0) })
      Issue.record("Invalid NDJSON unexpectedly decoded")
    } catch {}
    #expect(await receiver.samples.isEmpty)
    #expect(await receiver.types == ["text"])
    #expect(decoder.acceptedUnits == 1)
  }

  @Test func decodedSceneIsNotPretendedAcceptedWhenItsSemanticHandlerFails() async throws {
    var decoder = ProviderTextStreamDecoder()
    let receiver = WireClockReceiver()
    do {
      try await decoder.append(
        "{\"type\":\"scene\",\"nodes\":[]}\n",
        onUnit: { _ in throw WireClockFailure.semanticRejected },
        onSceneLineDecoded: { await receiver.sample($0) })
      Issue.record("Semantic rejection unexpectedly succeeded")
    } catch WireClockFailure.semanticRejected {}
    #expect(await receiver.samples.count == 1)
    #expect(decoder.acceptedUnits == 0)
  }

  @Test func enablingDiagnosticsMidLineCannotMislabelTheTailAsItsStart() async throws {
    var decoder = ProviderTextStreamDecoder()
    let receiver = WireClockReceiver()
    try await decoder.append(#"{"type":"scene","#, onUnit: { await receiver.unit($0) })
    try await decoder.append(
      "\"nodes\":[]}\n", onUnit: { await receiver.unit($0) },
      onSceneLineDecoded: { await receiver.sample($0) })
    #expect(await receiver.samples.isEmpty)
    try await decoder.append(
      "{\"type\":\"scene\",\"nodes\":[]}\n", onUnit: { await receiver.unit($0) },
      onSceneLineDecoded: { await receiver.sample($0) })
    #expect(await receiver.samples.count == 1)
    #expect(decoder.acceptedUnits == 2)
  }

  @Test func firstHandlerSuccessCannotBeRenamedByALaterSceneFailure() async {
    let receiver = WireClockReceiver()
    let reporter = CodexTimingReporter(onEvent: { await receiver.event($0) })
    #expect(await reporter.beginFirstSceneHandler())
    await reporter.finishFirstSceneHandler(success: true)
    #expect(await reporter.beginFirstSceneHandler() == false)
    await reporter.finishFirstSceneHandler(success: false)
    #expect(
      await receiver.events.map(\.stage) == [
        .firstSceneHandlerStarted, .firstSceneHandlerCompleted,
      ])
  }

  @Test func firstHandlerFailureIsTerminalAndDoesNotEmitAcceptedOrCompleted() async {
    let receiver = WireClockReceiver()
    let reporter = CodexTimingReporter(onEvent: { await receiver.event($0) })
    #expect(await reporter.beginFirstSceneHandler())
    await reporter.finishFirstSceneHandler(success: false)
    await reporter.finishFirstSceneHandler(success: true)
    #expect(
      await receiver.events.map(\.stage) == [
        .firstSceneHandlerStarted, .firstSceneHandlerFailed,
      ])
  }

  @Test func reporterKeepsHistoricalClientLineTimesSeparateFromClassificationTime() async throws {
    let receiver = WireClockReceiver()
    let reporter = CodexTimingReporter(onEvent: { await receiver.event($0) }, startedUptime: 1)
    await reporter.recordSceneLine(
      .init(
        startedUptime: 0, completedUptime: 3, utf8Bytes: 40, termination: .newline))
    await reporter.recordSceneLine(
      .init(
        startedUptime: 2, completedUptime: 3, utf8Bytes: 40, termination: .newline))
    await reporter.recordSceneLine(
      .init(
        startedUptime: 3, completedUptime: 4, utf8Bytes: 50, termination: .newline))
    let events = await receiver.events
    #expect(events.count == 1)
    let event = try #require(events.first)
    #expect(event.stage == .firstSceneLineDecoded)
    #expect(event.lineStartMS == 1_000 && event.lineEndMS == 2_000)
    #expect(event.elapsedMS >= 2_000 && event.lineUTF8Bytes == 40)
    #expect(event.lineTermination == .newline)
  }

  @Test func eventEncodingIsCountsOnlyAndLegacyEventsKeepTheirOriginalKeys() async throws {
    let legacy = CodexTimingEvent(stage: .initialized, elapsedMS: 5)
    let legacyJSON = try #require(
      try JSONSerialization.jsonObject(
        with: JSONEncoder().encode(legacy)) as? [String: Any])
    #expect(Set(legacyJSON.keys) == ["stage", "elapsedMS"])
    let receiver = WireClockReceiver()
    let reporter = CodexTimingReporter(onEvent: { await receiver.event($0) })
    await reporter.recordRequestPayload(
      instructionUTF8Bytes: -1, conversationUTF8Bytes: 8, turnInputUTF8Bytes: 13)
    await reporter.recordRequestPayload(
      instructionUTF8Bytes: 5, conversationUTF8Bytes: 8, turnInputUTF8Bytes: 13)
    await reporter.recordRequestPayload(
      instructionUTF8Bytes: 6, conversationUTF8Bytes: 9, turnInputUTF8Bytes: 14)
    let events = await receiver.events
    #expect(events.count == 1)
    let event = try #require(events.first)
    let json = try #require(
      try JSONSerialization.jsonObject(
        with: JSONEncoder().encode(event)) as? [String: Any])
    #expect(
      Set(json.keys) == [
        "stage", "elapsedMS", "instructionUTF8Bytes", "conversationUTF8Bytes", "turnInputUTF8Bytes",
      ])
    #expect(event.instructionUTF8Bytes == 5 && event.conversationUTF8Bytes == 8)
    #expect(event.turnInputUTF8Bytes == 13)
  }
}

private enum WireClockFailure: Error { case semanticRejected }

private actor WireClockReceiver {
  var samples: [ProviderLineWireSample] = []
  var types: [String] = []
  var order: [String] = []
  var events: [CodexTimingEvent] = []
  var firstHandlerUptime: Double?
  func sample(_ value: ProviderLineWireSample) {
    samples.append(value)
    order.append("decoded")
  }
  func unit(_ unit: ProviderUnit) {
    if firstHandlerUptime == nil { firstHandlerUptime = ProcessInfo.processInfo.systemUptime }
    types.append(unit.type)
    order.append("unit:" + unit.type)
  }
  func event(_ event: CodexTimingEvent) { events.append(event) }
}
