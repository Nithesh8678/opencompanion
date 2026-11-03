import AppKit
import Testing

@testable import OpenCompanion

@Suite struct NotchPointerPollingTests {
  @MainActor @Test func stationaryCutoutPointerIsSampledWithoutMouseEventDelivery() throws {
    var point = CGPoint(x: 300, y: 200)
    var samples: [CGPoint] = []
    let polling = NotchPointerPolling(location: { point }, onSample: { samples.append($0) })
    polling.start()
    defer { polling.stop() }
    #expect(polling.isRunning)
    #expect(samples == [point])

    // No NSEvent is created or injected: the pointer source moves and then
    // remains stationary at the real display's physical camera/top edge.
    point = CGPoint(x: 755.5, y: 982)
    RunLoop.main.run(until: Date().addingTimeInterval(0.18))
    #expect(samples.dropFirst().contains(point))

    polling.stop()
    #expect(!polling.isRunning)
    let count = samples.count
    RunLoop.main.run(until: Date().addingTimeInterval(0.10))
    #expect(samples.count == count)
  }
}
