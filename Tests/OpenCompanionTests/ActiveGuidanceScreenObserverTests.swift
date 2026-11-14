import CoreGraphics
import Foundation
import Testing

@testable import OpenCompanion

/// Deterministic ingestion only: no windows, native capture, AX, monitors,
/// provider, audio, or posted input is involved in these lifecycle tests.
@MainActor struct ActiveGuidanceScreenObserverTests {
  @Test func startsOnlyOnExplicitArmAndStopDropsPixelsAndQueuedOldEvents() async throws {
    let host = Host()
    let owner = try scope()
    #expect(!host.observer.diagnostics.active)
    try await host.observer.start(scope: owner)
    #expect(host.observer.scope == owner)
    #expect(!host.observer.diagnostics.streamStarted)
    #expect(host.observer.diagnostics.accessibilityNotifications == 0)
    host.observer.receiveFrame(try frame(content: 99, received: 100), scope: owner)
    #expect(host.observer.latestFrame?.contentTime == 99)
    host.observer.stop()
    host.observer.receive(reason: .layoutChanged, scope: owner, timestamp: 100)
    host.observer.receiveFrame(try frame(content: 100, received: 100), scope: owner)
    #expect(host.events.isEmpty)
    #expect(host.observer.latestFrame == nil)
  }

  @Test func everyNativeMetadataCategoryIsLeaseStampedAndNonterminalChangesStayArmed() async throws
  {
    let host = Host()
    let owner = try scope()
    try await host.observer.start(scope: owner)
    let reasons: [GuidanceObservationEvent.Reason] = [
      .windowChanged, .focusChanged, .geometryChanged, .menuChanged, .layoutChanged, .typing,
    ]
    for reason in reasons { host.observer.receive(reason: reason, scope: owner, timestamp: 100) }
    #expect(host.events.map(\.event.reason) == reasons)
    #expect(host.events.allSatisfy { $0.scope == owner && $0.event.timestamp == 100 })
    #expect(host.events.map(\.event.sequence) == [1, 2, 3, 4, 5, 6])
    #expect(host.observer.scope == owner)
    host.observer.stop()
  }

  @Test func oldScopeAndInvalidEventClocksCannotChangeReplacement() async throws {
    let host = Host()
    let old = try scope()
    try await host.observer.start(scope: old)
    let fresh = try scope(generation: old.generation + 1)
    try await host.observer.start(scope: fresh)
    host.observer.receive(reason: .unavailable, scope: old, timestamp: 100)
    for time in [Double.nan, Double.infinity, 99, 101] {
      host.observer.receive(reason: .layoutChanged, scope: fresh, timestamp: time)
    }
    host.observer.receiveFrame(try frame(content: 100, received: 100), scope: old)
    #expect(host.events.isEmpty)
    #expect(host.observer.scope == fresh)
    host.observer.receive(reason: .layoutChanged, scope: fresh, timestamp: 100)
    #expect(host.events.count == 1)
    host.observer.stop()
  }

  @Test func activationRoundTripAndSuspendRevokeBeforeDeliveryExactlyOnce() async throws {
    for reason in [GuidanceObservationEvent.Reason.foregroundChanged, .suspended, .unavailable] {
      let host = Host()
      let owner = try scope()
      try await host.observer.start(scope: owner)
      host.observer.receiveActivation(pid: owner.foregroundPID, scope: owner)
      #expect(host.events.isEmpty)
      host.onEvent = { _ in #expect(host.observer.scope == nil) }
      host.observer.receive(reason: reason, scope: owner, timestamp: 100)
      host.observer.receiveActivation(pid: owner.foregroundPID + 1, scope: owner)
      host.observer.receive(reason: .layoutChanged, scope: owner, timestamp: 100)
      #expect(host.events.count == 1)
      #expect(host.events.first?.event.reason == reason)
    }
  }

  @Test func pinnedWindowChangesPauseInsteadOfAcquiringAnotherWindow() async throws {
    for reason in [GuidanceObservationEvent.Reason.windowChanged, .geometryChanged] {
      let host = Host()
      let owner = try scope(windowID: 40)
      try await host.observer.start(scope: owner)
      host.observer.receive(reason: reason, scope: owner, timestamp: 100)
      #expect(host.observer.scope == nil)
      #expect(host.events.count == 1)
      #expect(host.events.first?.scope.windowID == 40)
    }
  }

  @Test func scrollFiltersUnrelatedInputAndPreservesNegativeDisplayOrigins() async throws {
    let host = Host()
    let owner = try scope()
    try await host.observer.start(scope: owner)
    for item in [
      (CGPoint(x: 0, y: 0), 1.0, 0.0, owner.foregroundPID, false),
      (CGPoint(x: -400, y: -100), 0, 0, owner.foregroundPID, false),
      (CGPoint(x: -400, y: -100), 1, 0, owner.foregroundPID + 1, false),
      (CGPoint(x: -400, y: -100), 1, 0, owner.foregroundPID, true),
      (CGPoint(x: -400, y: -100), Double.nan, 0, owner.foregroundPID, false),
    ] {
      host.observer.receiveScroll(
        point: item.0, deltaX: item.1, deltaY: item.2,
        foregroundPID: item.3, ownWindow: item.4, scope: owner, timestamp: 100)
    }
    #expect(host.events.isEmpty)
    host.observer.receiveScroll(
      point: CGPoint(x: -400, y: -100), deltaX: 0, deltaY: -1,
      foregroundPID: owner.foregroundPID, ownWindow: false, scope: owner, timestamp: 100)
    #expect(host.events.map(\.event.reason) == [.scroll])
    #expect(host.observer.scope == owner)
    host.observer.stop()
  }

  @Test func frameChangesAreLatestOnlyAndRepeatedContentDoesNotEmitChanges() async throws {
    let host = Host()
    let owner = try scope()
    try await host.observer.start(scope: owner)
    host.observer.receiveFrame(try frame(content: 99, received: 100), scope: owner)
    host.clock = 101
    host.observer.receiveFrame(try frame(content: 100, received: 101), scope: owner)
    host.observer.receiveFrame(try frame(content: 100, received: 101, color: 200), scope: owner)
    #expect(host.events.isEmpty)
    host.clock = 102
    host.observer.receiveFrame(try frame(content: 101, received: 102, color: 200), scope: owner)
    #expect(host.events.map(\.event.reason) == [.visualChange])
    #expect(host.observer.diagnostics.acceptedFrames == 3)
    #expect(host.observer.diagnostics.changedFrames == 1)
    #expect(host.observer.latestFrame?.contentTime == 101)
    host.observer.stop()
  }

  @Test func scopeRejectsRawInvalidGeometryAndIdentifiersWithoutStandardizingThem() throws {
    let bounds: [CGRect] = [
      .init(x: 0, y: 0, width: -1, height: 1),
      .init(x: 0, y: 0, width: 0, height: 1),
      .init(x: Double.nan, y: 0, width: 1, height: 1),
      .init(x: 0, y: 0, width: Double.infinity, height: 1),
      .init(x: 10_000_001, y: 0, width: 1, height: 1),
    ]
    for rect in bounds {
      #expect(throws: GuidanceObservationFailure.invalidScope) {
        try GuidanceObservationScope(
          generation: 1, foregroundPID: 421,
          displayID: 1, sourceRect: rect)
      }
    }
    for values in [(pid_t(0), UInt32(1), UInt32(40)), (421, 0, 40), (421, 1, 0)] {
      #expect(throws: GuidanceObservationFailure.invalidScope) {
        try GuidanceObservationScope(
          generation: 1, foregroundPID: values.0,
          displayID: values.1, sourceRect: CGRect(x: 0, y: 0, width: 1, height: 1),
          windowID: values.2)
      }
    }
  }

  private func scope(generation: UInt64 = 1, windowID: UInt32? = nil) throws
    -> GuidanceObservationScope
  {
    try .init(
      generation: generation, foregroundPID: 424_242, displayID: 1,
      sourceRect: CGRect(x: -600, y: -300, width: 500, height: 400), windowID: windowID)
  }

  private func frame(content: Double, received: Double, color: UInt8 = 40) throws
    -> GuidanceObservationFrame
  {
    try #require(
      GuidanceObservationFrame(
        width: 8, height: 4,
        contentTime: content, receivedAt: received, pixels: Data(repeating: color, count: 8 * 4 * 4)
      ))
  }

  @MainActor private final class Host {
    struct Received {
      let scope: GuidanceObservationScope
      let event: GuidanceObservationEvent
    }
    var clock = 100.0
    var events: [Received] = []
    var onEvent: ((Received) -> Void)?
    lazy var observer = ActiveGuidanceScreenObserver(
      observeSystemEvents: false,
      now: { [unowned self] in clock }
    ) { [weak self] scope, event in
      guard let self else { return }
      let received = Received(scope: scope, event: event)
      events.append(received)
      onEvent?(received)
    }
  }
}
