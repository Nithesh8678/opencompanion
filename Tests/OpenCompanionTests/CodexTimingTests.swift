import Testing

@testable import OpenCompanion

struct CodexTimingTests {
  @Test func repeatedStagesAreBoundedToOneContentFreeEventEach() async {
    let receiver = TimingEventReceiver()
    let reporter = CodexTimingReporter(onEvent: { await receiver.append($0) })
    await reporter.mark(.requestStarted)
    for _ in 0..<1000 { await reporter.mark(.firstUnitAccepted) }
    for stage in CodexTimingEvent.Stage.allCases { await reporter.mark(stage) }
    let events = await receiver.events
    #expect(events.count == CodexTimingEvent.Stage.allCases.count)
    #expect(Set(events.map(\.stage)).count == events.count)
    #expect(events.allSatisfy { $0.elapsedMS.isFinite && $0.elapsedMS >= 0 })
    #expect(events.first?.elapsedMS == 0)
  }
}

private actor TimingEventReceiver {
  var events: [CodexTimingEvent] = []
  func append(_ event: CodexTimingEvent) { events.append(event) }
}
