import CoreGraphics
import Foundation
import Testing

@testable import OpenCompanion

/// Direct metadata ingestion only. System event observation is disabled: these
/// tests do not capture, inspect apps/windows, post input, or prove native delivery.
@Suite @MainActor struct GuidanceSceneObserverTests {
  @Test func leavingAndReturningToTheSameAppInvalidatesExactlyOnce() throws {
    let fixture = Harness()
    defer { fixture.observer.disarm() }
    let scope = try arm(fixture)

    fixture.observer.receiveActivation(pid: 422)
    fixture.observer.receiveActivation(pid: 421)
    fixture.observer.receiveActivation(pid: 423)

    #expect(fixture.events == [.init(scope: scope, reason: .foregroundChanged)])
  }

  @Test func eventsBeforeArmAndAfterDisarmCannotProduceChanges() throws {
    let fixture = Harness()
    defer { fixture.observer.disarm() }
    fixture.observer.receiveActivation(pid: 422)
    scroll(fixture, at: CGPoint(x: 150, y: 150))
    #expect(fixture.events.isEmpty)
    let old = try arm(fixture)
    fixture.observer.disarm()
    fixture.observer.receiveActivation(pid: 422)
    scroll(fixture, at: CGPoint(x: 150, y: 150))
    fixture.observer.receiveActivation(pid: 422, leaseID: old.leaseID)
    #expect(fixture.events.isEmpty)
  }

  @Test func samePIDNotificationsDoNotConsumeAnArmedScope() throws {
    let fixture = Harness()
    defer { fixture.observer.disarm() }
    let scope = try arm(fixture)
    for _ in 0..<8 { fixture.observer.receiveActivation(pid: scope.foregroundPID) }
    #expect(fixture.events.isEmpty)
    fixture.observer.receiveActivation(pid: 422)
    #expect(fixture.events == [.init(scope: scope, reason: .foregroundChanged)])
  }

  @Test func unavailableForegroundInvalidatesAnArmedScopeOnce() throws {
    let fixture = Harness()
    defer { fixture.observer.disarm() }
    let scope = try arm(fixture)
    fixture.observer.receiveActivation(pid: nil)
    fixture.observer.receiveActivation(pid: nil)
    #expect(fixture.events == [.init(scope: scope, reason: .foregroundChanged)])
  }

  @Test func anInScopeScrollInvalidatesOnceWithoutInterpretingContentMovement() throws {
    let fixture = Harness()
    defer { fixture.observer.disarm() }
    let scope = try arm(fixture)
    scroll(fixture, at: CGPoint(x: 150, y: 150))
    scroll(fixture, at: CGPoint(x: 150, y: 150))
    fixture.observer.receiveActivation(pid: 422)
    #expect(fixture.events == [.init(scope: scope, reason: .scroll)])
  }

  @Test func localOwnWindowScrollingDoesNotInvalidateTheExternalScope() throws {
    let fixture = Harness()
    defer { fixture.observer.disarm() }
    let scope = try arm(fixture)
    fixture.observer.receiveScroll(
      point: CGPoint(x: 150, y: 150), deltaX: 0, deltaY: 10,
      foregroundPID: 421, ownWindow: true)
    #expect(fixture.events.isEmpty)
    scroll(fixture, at: CGPoint(x: 150, y: 150))
    #expect(fixture.events == [.init(scope: scope, reason: .scroll)])
  }

  @Test func unrelatedEmptyAndNonfiniteScrollMetadataIsIgnored() throws {
    let fixture = Harness()
    defer { fixture.observer.disarm() }
    let scope = try arm(fixture)
    let invalid: [(CGPoint?, Double, Double, pid_t?)] = [
      (nil, 0, 10, 421),
      (CGPoint(x: -50, y: -50), 0, 10, 421),
      (CGPoint(x: 150, y: 150), 0, 10, 422),
      (CGPoint(x: 150, y: 150), 0, 10, nil),
      (CGPoint(x: 150, y: 150), 0, 0, 421),
      (CGPoint(x: CGFloat.nan, y: 150), 0, 10, 421),
      (CGPoint(x: 150, y: CGFloat.infinity), 0, 10, 421),
      (CGPoint(x: 150, y: 150), Double.nan, 10, 421),
      (CGPoint(x: 150, y: 150), 0, Double.infinity, 421),
      (CGPoint(x: 150, y: 150), 0, 10, 0),
    ]
    for (point, x, y, pid) in invalid {
      fixture.observer.receiveScroll(
        point: point, deltaX: x, deltaY: y, foregroundPID: pid, ownWindow: false)
      #expect(fixture.events.isEmpty)
    }
    scroll(fixture, at: CGPoint(x: 150, y: 150))
    #expect(fixture.events == [.init(scope: scope, reason: .scroll)])
  }

  @Test func aNegativeOriginScopeUsesGlobalLogicalCoordinates() throws {
    let fixture = Harness()
    defer { fixture.observer.disarm() }
    let rect = CGRect(x: -900, y: -700, width: 800, height: 600)
    let scope = try arm(fixture, sourceRect: rect)
    scroll(fixture, at: CGPoint(x: 500, y: 400))
    #expect(fixture.events.isEmpty)
    scroll(fixture, at: CGPoint(x: -500, y: -400))
    #expect(fixture.events == [.init(scope: scope, reason: .scroll)])
    #expect(scope.sourceRect == rect)
  }

  @Test func replacingALeaseRejectsQueuedActivationAndScrollFromTheOldArm() throws {
    let fixture = Harness()
    defer { fixture.observer.disarm() }
    let old = try arm(fixture)
    let current = try arm(fixture, generation: 2, foregroundPID: 422)
    #expect(old.leaseID != current.leaseID)
    fixture.observer.receiveActivation(pid: 999, leaseID: old.leaseID)
    fixture.observer.receiveScroll(
      point: CGPoint(x: 150, y: 150), deltaX: 0, deltaY: 10,
      foregroundPID: 421, ownWindow: false, leaseID: old.leaseID)
    #expect(fixture.events.isEmpty)
    fixture.observer.receiveScroll(
      point: CGPoint(x: 150, y: 150), deltaX: 0, deltaY: 10,
      foregroundPID: 422, ownWindow: false, leaseID: current.leaseID)
    #expect(fixture.events == [.init(scope: current, reason: .scroll)])
  }

  @Test func cancellingAndRearmingTheSameGenerationStillRequiresANewLease() throws {
    let fixture = Harness()
    defer { fixture.observer.disarm() }
    let old = try arm(fixture)
    fixture.observer.disarm()
    fixture.observer.disarm()
    let current = try arm(fixture)
    #expect(old.generation == current.generation && old.leaseID != current.leaseID)
    fixture.observer.receiveActivation(pid: 999, leaseID: old.leaseID)
    fixture.observer.receiveScroll(
      point: CGPoint(x: 150, y: 150), deltaX: 1, deltaY: 0,
      foregroundPID: 421, ownWindow: false, leaseID: old.leaseID)
    #expect(fixture.events.isEmpty)
    fixture.observer.receiveActivation(pid: 422, leaseID: current.leaseID)
    #expect(fixture.events == [.init(scope: current, reason: .foregroundChanged)])
  }

  @Test func aCallbackCanRearmAfterTheOldScopeHasAlreadyBeenRevoked() throws {
    let fixture = Harness()
    defer { fixture.observer.disarm() }
    let first = try arm(fixture)
    var replacement: GuidanceSceneScope?
    fixture.onChange = { [weak observer = fixture.observer] scope, _ in
      guard scope.generation == 1 else { return }
      replacement = observer?.arm(
        generation: 2, foregroundPID: 422, sourceRect: scope.sourceRect)
    }
    fixture.observer.receiveActivation(pid: 422, leaseID: first.leaseID)
    let current = try #require(replacement)
    fixture.observer.receiveActivation(pid: 999, leaseID: first.leaseID)
    #expect(fixture.events == [.init(scope: first, reason: .foregroundChanged)])
    fixture.observer.receiveScroll(
      point: CGPoint(x: 150, y: 150), deltaX: 1, deltaY: 0,
      foregroundPID: 422, ownWindow: false, leaseID: current.leaseID)
    #expect(
      fixture.events == [
        .init(scope: first, reason: .foregroundChanged), .init(scope: current, reason: .scroll),
      ])
  }

  @Test func malformedRearmDisarmsTheOldScopeInsteadOfRetainingIt() throws {
    for rect in [
      CGRect.zero,
      CGRect(x: 0, y: 0, width: -100, height: 100),
      CGRect(x: 0, y: 0, width: 100, height: -100),
      CGRect(x: CGFloat.nan, y: 0, width: 100, height: 100),
      CGRect(x: 0, y: 0, width: CGFloat.infinity, height: 100),
    ] {
      let fixture = Harness()
      defer { fixture.observer.disarm() }
      let old = try arm(fixture)
      #expect(fixture.observer.arm(generation: 2, foregroundPID: 421, sourceRect: rect) == nil)
      fixture.observer.receiveActivation(pid: 422, leaseID: old.leaseID)
      #expect(fixture.events.isEmpty)
    }
    let fixture = Harness()
    defer { fixture.observer.disarm() }
    #expect(
      fixture.observer.arm(
        generation: 1, foregroundPID: 0, sourceRect: CGRect(x: 0, y: 0, width: 800, height: 600))
        == nil)
  }

  private func arm(
    _ fixture: Harness, generation: UInt64 = 1, foregroundPID: pid_t = 421,
    sourceRect: CGRect = CGRect(x: 100, y: 100, width: 800, height: 600)
  ) throws -> GuidanceSceneScope {
    try #require(
      fixture.observer.arm(
        generation: generation, foregroundPID: foregroundPID, sourceRect: sourceRect))
  }

  private func scroll(_ fixture: Harness, at point: CGPoint) {
    fixture.observer.receiveScroll(
      point: point, deltaX: 0, deltaY: 10, foregroundPID: 421, ownWindow: false)
  }

  private struct Event: Equatable {
    let scope: GuidanceSceneScope
    let reason: GuidanceSceneChange
  }

  @MainActor private final class Harness {
    private(set) var events: [Event] = []
    var onChange: ((GuidanceSceneScope, GuidanceSceneChange) -> Void)?
    private(set) var observer: GuidanceSceneObserver!

    init() {
      observer = GuidanceSceneObserver(observeSystemEvents: false) { [weak self] scope, reason in
        guard let self else { return }
        self.events.append(.init(scope: scope, reason: reason))
        self.onChange?(scope, reason)
      }
    }
  }
}
