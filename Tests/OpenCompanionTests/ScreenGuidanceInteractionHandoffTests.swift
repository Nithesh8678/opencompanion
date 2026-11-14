import Foundation
import Testing

@testable import OpenCompanion

@Suite @MainActor struct ScreenGuidanceInteractionHandoffTests {
  @Test func waitingSelectedMarkRechecksExactWindowVisibility() throws {
    let h = try Harness(selected: true)
    let owner = h.make()
    defer {
      owner.shutdown()
      h.model.stop()
    }
    h.accept(owner)
    #expect(owner.clickObservationLeaseID != nil && !owner.hasInteractionHandoff)
    h.windowLive = false
    owner.validateCurrentMark()
    #expect(owner.clickObservationLeaseID == nil && !owner.hasInteractionHandoff)
  }

  @Test func selectedDownMenuUpAndSettlePreserveOneAuthenticatedLease() async throws {
    let h = try Harness(selected: true)
    let gate = HandoffGate()
    let owner = h.make(settle: { await gate.wait() })
    defer {
      owner.shutdown()
      h.model.stop()
    }
    h.accept(owner)
    let lease = try #require(owner.clickObservationLeaseID)
    owner.receiveMouseDown(
      at: h.point, timestamp: 100, eventTargetPID: 424_242,
      handlingWindowID: 42, lease: lease)
    #expect(owner.hasInteractionHandoff)
    let checks = h.visibilityChecks
    h.windowLive = false
    owner.validateCurrentMark()
    #expect(owner.hasInteractionHandoff && h.visibilityChecks == checks)
    owner.receiveMouseUp(
      at: h.point, timestamp: 100.1, eventTargetPID: 424_242,
      handlingWindowID: 99, lease: lease)
    #expect(owner.hasInteractionHandoff && h.visibilityChecks == checks)
    await gate.untilWaiting()
    await gate.release()
    await drain()
    #expect(h.continuations == 1 && !owner.hasInteractionHandoff)
  }

  @Test func autoDisplayDownNeedsExactPidAndEndsOnInvalidUpOrDeadline() throws {
    let h = try Harness(selected: false)
    let owner = h.make()
    defer {
      owner.shutdown()
      h.model.stop()
    }
    h.accept(owner)
    let lease = try #require(owner.clickObservationLeaseID)
    for pid: Int32? in [nil, 0, 99] {
      owner.receiveMouseDown(
        at: h.point, timestamp: 100, eventTargetPID: pid,
        handlingWindowID: 42, lease: lease)
      #expect(!owner.hasInteractionHandoff)
    }
    owner.receiveMouseDown(
      at: h.point, timestamp: 100, eventTargetPID: 424_242,
      handlingWindowID: 42, lease: lease)
    #expect(owner.hasInteractionHandoff)
    owner.receiveMouseDown(
      at: h.point, timestamp: 100, eventTargetPID: 99,
      handlingWindowID: 42, lease: UUID())
    #expect(owner.hasInteractionHandoff)
    owner.receiveMouseUp(
      at: .init(x: 1_000, y: 1_000), timestamp: 100.1,
      eventTargetPID: 424_242, handlingWindowID: 42, lease: lease)
    #expect(!owner.hasInteractionHandoff && h.continuations == 0)
    owner.receiveMouseDown(
      at: h.point, timestamp: 101, eventTargetPID: 424_242,
      handlingWindowID: 42, lease: lease)
    h.time = 145
    #expect(!owner.hasInteractionHandoff)
  }

  @Test func generationLossDuringSettleRevokesTheHandoff() async throws {
    let h = try Harness(selected: false)
    let gate = HandoffGate()
    let owner = h.make(settle: { await gate.wait() })
    defer {
      owner.shutdown()
      h.model.stop()
    }
    h.accept(owner)
    let lease = try #require(owner.clickObservationLeaseID)
    owner.receiveMouseDown(
      at: h.point, timestamp: 100, eventTargetPID: 424_242,
      handlingWindowID: 42, lease: lease)
    owner.receiveMouseUp(
      at: h.point, timestamp: 100.1, eventTargetPID: 424_242,
      handlingWindowID: 42, lease: lease)
    await gate.untilWaiting()
    #expect(owner.hasInteractionHandoff)
    h.model.stop()
    #expect(!owner.hasInteractionHandoff)
    await gate.release()
    await drain()
    #expect(h.continuations == 0)
  }

  private func drain() async {
    await withCheckedContinuation { continuation in
      DispatchQueue.main.async { continuation.resume() }
    }
    await Task.yield()
  }

  @MainActor private final class Harness {
    let model: AppModel
    let evidence: OpenCompanion.ScreenEvidence
    let request: ScreenGuidanceRequest
    var windowLive = true
    var visibilityChecks = 0
    var time = 100.0
    var continuations = 0
    var point: CGPoint { .init(x: -480, y: -30) }

    init(selected: Bool) throws {
      model = AppModel(
        acceptanceMode: true, guidanceForegroundPID: { 424_242 }, screenGuidanceEnabled: { true })
      evidence = .init(
        frameID: UUID(), revision: 1, capturedAt: 99, displayID: 7,
        foregroundPID: 424_242, foregroundName: "Public fixture",
        screenRect: .init(x: -600, y: -200, width: 320, height: 240),
        windowID: selected ? 42 : nil, image: Data(), semanticText: "")
      if selected {
        guard model.publishSelectedCapture(evidence, token: model.capturePublicationRevision) else {
          throw FixtureFailure.publication
        }
        request = .init(
          prompt: "Public task", expires: 280,
          selectedScope: try model.currentSelectedGuidanceScope())
      } else {
        model.evidence = evidence
        request = .init(prompt: "Public task", expires: 280)
      }
    }
    func make(settle: @escaping @MainActor () async throws -> Void = {})
      -> ScreenGuidanceCoordinator
    {
      .init(
        model: model, observeInput: false, now: { self.time }, foregroundPID: { 424_242 },
        settle: settle,
        windowVisibility: { _, _ in
          self.visibilityChecks += 1
          return self.windowLive
        },
        onContinue: { [weak self] _, _, _, _ in self?.continuations += 1 })
    }
    func accept(_ owner: ScreenGuidanceCoordinator) {
      owner.accept(
        target: .init(
          x: 0.25, y: 0.25, width: 0.2, height: 0.1,
          instruction: "Open this control", advanceOn: "click"), evidence: evidence,
        generation: model.taskGeneration, request: request)
    }
    enum FixtureFailure: Error { case publication }
  }
}

private actor HandoffGate {
  private var continuation: CheckedContinuation<Void, Never>?
  private var waiters: [CheckedContinuation<Void, Never>] = []
  func wait() async {
    await withCheckedContinuation { continuation in
      self.continuation = continuation
      for waiter in waiters { waiter.resume() }
      waiters.removeAll()
    }
  }
  func untilWaiting() async {
    if continuation != nil { return }
    await withCheckedContinuation { waiters.append($0) }
  }
  func release() {
    continuation?.resume()
    continuation = nil
  }
}
