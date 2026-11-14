import CoreGraphics
import Foundation
import Testing

@testable import OpenCompanion

/// Recorded-event metadata only. These tests do not post events or query a
/// native window server, and do not establish physical click delivery.
@Suite struct SelectedWindowClickHandoffTests {
  @Test func anExactNegativeOriginPairIsConsumedOnlyOnce() {
    var handoff = SelectedWindowClickHandoff()
    let owner = authority()
    #expect(down(&handoff, owner: owner))
    #expect(handoff.hasPendingDown)
    #expect(up(&handoff, owner: owner))
    #expect(!handoff.hasPendingDown)
    #expect(!up(&handoff, owner: owner))
  }

  @Test(arguments: [
    "missingWindow", "zeroWindow", "wrongWindow", "missingPID", "zeroPID", "wrongPID",
    "missingPoint", "outsidePoint", "nonfinitePoint", "nonfiniteTime", "beforeAdmission",
    "expiredTime",
  ])
  func downRequiresTheRecordedHandlingWindowAndPositiveMatchingPID(_ invalid: String) {
    var handoff = SelectedWindowClickHandoff()
    let owner = authority()
    var point: CGPoint? = center
    var pid: pid_t? = owner.foregroundPID
    var windowID: CGWindowID? = owner.windowID
    var timestamp: TimeInterval = 100.1
    switch invalid {
    case "missingWindow": windowID = nil
    case "zeroWindow": windowID = 0
    case "wrongWindow": windowID = 77
    case "missingPID": pid = nil
    case "zeroPID": pid = 0
    case "wrongPID": pid = 555
    case "missingPoint": point = nil
    case "outsidePoint": point = CGPoint(x: 0, y: 0)
    case "nonfinitePoint": point = CGPoint(x: CGFloat.infinity, y: -32)
    case "nonfiniteTime": timestamp = .nan
    case "beforeAdmission": timestamp = 99.9
    case "expiredTime": timestamp = 145
    default: Issue.record("Unknown authored invalid down")
    }
    let accepted = handoff.receiveDown(
      authority: owner, point: point, timestamp: timestamp,
      eventTargetPID: pid, handlingWindowID: windowID)
    #expect(!accepted)
    #expect(!handoff.hasPendingDown && !up(&handoff, owner: owner))
  }

  @Test func anUnknownSecondDownClearsAnEarlierAuthenticatedDown() {
    var handoff = SelectedWindowClickHandoff()
    let owner = authority()
    #expect(down(&handoff, owner: owner))
    let accepted = handoff.receiveDown(
      authority: owner, point: center, timestamp: 100.15,
      eventTargetPID: owner.foregroundPID, handlingWindowID: nil)
    #expect(!accepted)
    #expect(!up(&handoff, owner: owner))
  }

  @Test(arguments: [
    "reversedTime", "nonfiniteTime", "expiredTime", "outsidePoint", "missingPoint", "foreignPID",
    "negativePID",
  ])
  func anInvalidUpConsumesItsDownWithoutAllowingALaterReplay(_ invalid: String) {
    var handoff = SelectedWindowClickHandoff()
    let owner = authority()
    #expect(down(&handoff, owner: owner))
    var point: CGPoint? = center
    var timestamp: TimeInterval = 100.2
    var pid: pid_t? = owner.foregroundPID
    switch invalid {
    case "reversedTime": timestamp = 100.05
    case "nonfiniteTime": timestamp = .infinity
    case "expiredTime": timestamp = 145
    case "outsidePoint": point = .zero
    case "missingPoint": point = nil
    case "foreignPID": pid = 555
    case "negativePID": pid = -1
    default: Issue.record("Unknown authored invalid up")
    }
    let accepted = handoff.receiveUp(
      authority: owner, point: point, timestamp: timestamp, eventTargetPID: pid)
    #expect(!accepted)
    #expect(!handoff.hasPendingDown && !up(&handoff, owner: owner))
  }

  @Test(arguments: [nil, pid_t(0), pid_t(424_242)] as [pid_t?])
  func upMayHaveUnknownPIDAfterAnAuthenticatedDown(_ pid: pid_t?) {
    var handoff = SelectedWindowClickHandoff()
    let owner = authority()
    #expect(down(&handoff, owner: owner))
    let accepted = handoff.receiveUp(
      authority: owner, point: center, timestamp: 100.2, eventTargetPID: pid)
    #expect(accepted)
  }

  @Test func aSecondValidDownReplacesTheTimestampWithinTheSameOwner() {
    var handoff = SelectedWindowClickHandoff()
    let owner = authority()
    #expect(down(&handoff, owner: owner))
    let accepted = handoff.receiveDown(
      authority: owner, point: center, timestamp: 100.3,
      eventTargetPID: owner.foregroundPID, handlingWindowID: owner.windowID)
    #expect(accepted)
    #expect(!up(&handoff, owner: owner))
    #expect(!handoff.hasPendingDown)
  }

  @Test(arguments: ["lease", "frame", "generation", "request", "step"])
  func queuedOldAuthorityCannotConsumeOrReplaceANewerDown(_ field: String) {
    var handoff = SelectedWindowClickHandoff()
    let current = authority()
    let old = authority(
      lease: field == "lease" ? UUID() : current.lease,
      frameID: field == "frame" ? UUID() : current.frameID,
      generation: field == "generation" ? current.generation + 1 : current.generation,
      requestID: field == "request" ? UUID() : current.requestID,
      step: field == "step" ? current.step + 1 : current.step)
    #expect(down(&handoff, owner: current))
    #expect(!down(&handoff, owner: old))
    #expect(!up(&handoff, owner: old))
    #expect(handoff.hasPendingDown && up(&handoff, owner: current))
  }

  @Test func clearPreventsAReleasedLeaseFromBeingResurrected() {
    var handoff = SelectedWindowClickHandoff()
    let old = authority()
    #expect(down(&handoff, owner: old))
    handoff.clear()
    #expect(!up(&handoff, owner: old))
    let current = authority()
    #expect(down(&handoff, owner: current) && up(&handoff, owner: current))
  }

  @Test(arguments: ["negativeWidth", "nonfiniteOrigin", "nonfiniteDeadline", "oversizedDeadline"])
  func malformedAuthorityFailsClosed(_ field: String) {
    let rect: CGRect
    switch field {
    case "negativeWidth": rect = .init(x: -520, y: -44, width: -64, height: 24)
    case "nonfiniteOrigin": rect = .init(x: CGFloat.nan, y: -44, width: 64, height: 24)
    default: rect = .init(x: -520, y: -44, width: 64, height: 24)
    }
    let owner = authority(
      rect: rect,
      deadline: field == "nonfiniteDeadline"
        ? .infinity : (field == "oversizedDeadline" ? 146 : 145))
    var handoff = SelectedWindowClickHandoff()
    #expect(!down(&handoff, owner: owner) && !handoff.hasPendingDown)
  }

  private var center: CGPoint { .init(x: -488, y: -32) }

  private func authority(
    lease: UUID = UUID(), frameID: UUID = UUID(), generation: UInt64 = 7,
    requestID: UUID = UUID(), step: Int = 0,
    rect: CGRect = .init(x: -520, y: -44, width: 64, height: 24), deadline: TimeInterval = 145
  ) -> SelectedWindowClickHandoff.Authority {
    .init(
      lease: lease, frameID: frameID, generation: generation, requestID: requestID, step: step,
      foregroundPID: 424_242, windowID: 42, targetRect: rect, admittedAt: 100, deadline: deadline)
  }

  private func down(
    _ handoff: inout SelectedWindowClickHandoff, owner: SelectedWindowClickHandoff.Authority
  ) -> Bool {
    handoff.receiveDown(
      authority: owner, point: center, timestamp: 100.1,
      eventTargetPID: owner.foregroundPID, handlingWindowID: owner.windowID)
  }

  private func up(
    _ handoff: inout SelectedWindowClickHandoff, owner: SelectedWindowClickHandoff.Authority
  ) -> Bool {
    handoff.receiveUp(
      authority: owner, point: center, timestamp: 100.2, eventTargetPID: owner.foregroundPID)
  }
}

/// Real controller with metadata ingestion and an explicitly injected admission
/// gate. No window server, event monitors, screenshot, provider or input posting.
@Suite @MainActor struct SelectedWindowClickCoordinatorTests {
  @Test func menuWindowAtUpDoesNotRecheckVisibilityOrLoseTheAuthenticatedDown() async throws {
    let fixture = try SelectedWindowMouseFixture()
    let coordinator = fixture.coordinator()
    defer {
      coordinator.shutdown()
      fixture.model.stop()
    }
    fixture.accept(on: coordinator)
    let lease = try #require(coordinator.clickObservationLeaseID)
    #expect(fixture.visibilityReads == 1)
    coordinator.receiveMouseDown(
      at: fixture.point, timestamp: 100.1, eventTargetPID: 424_242,
      handlingWindowID: 42, lease: lease)
    let readsAfterDown = fixture.visibilityReads
    // Admission and the current down each require live window geometry. The
    // authenticated pair then owns the menu/settle handoff without another hit.
    #expect(readsAfterDown == 2 && coordinator.hasInteractionHandoff)
    fixture.visible = false
    coordinator.validateCurrentMark()
    #expect(fixture.visibilityReads == readsAfterDown)
    #expect(coordinator.clickObservationLeaseID == lease)
    coordinator.receiveMouseUp(
      at: fixture.point, timestamp: 100.2, eventTargetPID: 424_242,
      handlingWindowID: 99, lease: lease)
    coordinator.receiveMouseUp(
      at: fixture.point, timestamp: 100.2, eventTargetPID: 424_242,
      handlingWindowID: 99, lease: lease)
    #expect(fixture.visibilityReads == readsAfterDown)
    await drain()
    #expect(fixture.receipts == [.click] && fixture.visibilityReads == readsAfterDown)
    #expect(coordinator.clickObservationLeaseID == nil)
  }

  @Test func upWithoutARecordedDownCannotAdvanceASelectedWindow() async throws {
    let fixture = try SelectedWindowMouseFixture()
    let coordinator = fixture.coordinator()
    defer {
      coordinator.shutdown()
      fixture.model.stop()
    }
    fixture.accept(on: coordinator)
    let lease = try #require(coordinator.clickObservationLeaseID)
    coordinator.receiveMouseUp(
      at: fixture.point, timestamp: 100.2, eventTargetPID: 424_242,
      handlingWindowID: 42, lease: lease)
    await drain()
    #expect(fixture.receipts.isEmpty)
  }

  @Test(arguments: ["missingWindow", "foreignWindow", "missingPID", "foreignPID"])
  func unknownOrConflictingDownCannotAuthorizeASelectedClick(_ field: String) async throws {
    let fixture = try SelectedWindowMouseFixture()
    let coordinator = fixture.coordinator()
    defer {
      coordinator.shutdown()
      fixture.model.stop()
    }
    fixture.accept(on: coordinator)
    let lease = try #require(coordinator.clickObservationLeaseID)
    coordinator.receiveMouseDown(
      at: fixture.point, timestamp: 100.1,
      eventTargetPID: field == "missingPID" ? nil : (field == "foreignPID" ? 555 : 424_242),
      handlingWindowID: field == "missingWindow" ? nil : (field == "foreignWindow" ? 99 : 42),
      lease: lease)
    #expect(fixture.visibilityReads == 2 && !coordinator.hasInteractionHandoff)
    coordinator.receiveMouseUp(
      at: fixture.point, timestamp: 100.2, eventTargetPID: 424_242,
      handlingWindowID: 42, lease: lease)
    await drain()
    // A malformed down grants no handoff, so an up must perform the ordinary
    // waiting-window liveness check and still cannot advance without its down.
    #expect(fixture.receipts.isEmpty && fixture.visibilityReads == 3)
  }

  @Test func aKnownForeignUpConsumesTheDownWithoutQueuingContinuation() async throws {
    let fixture = try SelectedWindowMouseFixture()
    let coordinator = fixture.coordinator()
    defer {
      coordinator.shutdown()
      fixture.model.stop()
    }
    fixture.accept(on: coordinator)
    let lease = try #require(coordinator.clickObservationLeaseID)
    coordinator.receiveMouseDown(
      at: fixture.point, timestamp: 100.1, eventTargetPID: 424_242,
      handlingWindowID: 42, lease: lease)
    coordinator.receiveMouseUp(
      at: fixture.point, timestamp: 100.2, eventTargetPID: 555,
      handlingWindowID: 99, lease: lease)
    coordinator.receiveMouseUp(
      at: fixture.point, timestamp: 100.3, eventTargetPID: 424_242,
      handlingWindowID: 42, lease: lease)
    await drain()
    #expect(fixture.receipts.isEmpty)
  }

  @Test func oldQueuedEdgesCannotConsumeANewLeaseDown() async throws {
    let fixture = try SelectedWindowMouseFixture()
    let coordinator = fixture.coordinator()
    defer {
      coordinator.shutdown()
      fixture.model.stop()
    }
    fixture.accept(on: coordinator)
    let old = try #require(coordinator.clickObservationLeaseID)
    fixture.accept(on: coordinator)
    let current = try #require(coordinator.clickObservationLeaseID)
    #expect(current != old)
    coordinator.receiveMouseDown(
      at: fixture.point, timestamp: 100.1, eventTargetPID: 424_242,
      handlingWindowID: 42, lease: current)
    coordinator.receiveMouseDown(
      at: fixture.point, timestamp: 100.11, eventTargetPID: 555,
      handlingWindowID: nil, lease: old)
    coordinator.receiveMouseUp(
      at: fixture.point, timestamp: 100.2, eventTargetPID: 424_242,
      handlingWindowID: 42, lease: old)
    #expect(fixture.receipts.isEmpty)
    coordinator.receiveMouseUp(
      at: fixture.point, timestamp: 100.3, eventTargetPID: 424_242,
      handlingWindowID: 99, lease: current)
    await drain()
    #expect(fixture.receipts == [.click])
  }

  @Test func visibilityRefusesAdmissionWithoutArmingAClick() throws {
    let fixture = try SelectedWindowMouseFixture()
    let coordinator = fixture.coordinator()
    defer {
      coordinator.shutdown()
      fixture.model.stop()
    }
    fixture.visible = false
    fixture.accept(on: coordinator)
    #expect(coordinator.clickObservationLeaseID == nil && fixture.visibilityReads == 1)
    #expect(fixture.receipts.isEmpty)
  }

  @Test(arguments: [false, true])
  func nonSelectedAndSelectedRegionRequestsKeepMouseUpOnlyBehavior(_ selectedRegion: Bool)
    async throws
  {
    let fixture = try SelectedWindowMouseFixture(windowID: selectedRegion ? nil : 42)
    let coordinator = fixture.coordinator()
    defer {
      coordinator.shutdown()
      fixture.model.stop()
    }
    fixture.visible = false
    fixture.accept(on: coordinator, selected: selectedRegion)
    let lease = try #require(coordinator.clickObservationLeaseID)
    coordinator.receiveMouseUp(
      at: fixture.point, timestamp: .nan, eventTargetPID: nil,
      handlingWindowID: nil, lease: lease)
    await drain()
    #expect(fixture.receipts == [.click] && fixture.visibilityReads == 0)
  }

  @Test(arguments: [false, true])
  func replacedSelectionOrStoppedGenerationCannotUseItsPendingDown(_ replaced: Bool) async throws {
    let fixture = try SelectedWindowMouseFixture()
    let coordinator = fixture.coordinator()
    defer {
      coordinator.shutdown()
      fixture.model.stop()
    }
    fixture.accept(on: coordinator)
    let lease = try #require(coordinator.clickObservationLeaseID)
    coordinator.receiveMouseDown(
      at: fixture.point, timestamp: 100.1, eventTargetPID: 424_242,
      handlingWindowID: 42, lease: lease)
    if replaced {
      let published = fixture.model.publishSelectedCapture(
        fixture.evidence, token: fixture.model.capturePublicationRevision)
      #expect(published)
    } else {
      fixture.model.stop()
    }
    coordinator.receiveMouseUp(
      at: fixture.point, timestamp: 100.2, eventTargetPID: 424_242,
      handlingWindowID: 42, lease: lease)
    await drain()
    #expect(fixture.receipts.isEmpty && coordinator.clickObservationLeaseID == nil)
  }

  private func drain() async {
    await withCheckedContinuation { continuation in
      DispatchQueue.main.async { continuation.resume() }
    }
    await Task.yield()
  }
}

@MainActor private final class SelectedWindowMouseFixture {
  let model: AppModel
  let evidence: OpenCompanion.ScreenEvidence
  let scope: ScreenGuidanceCaptureScope
  let request: ScreenGuidanceRequest
  let point = CGPoint(x: -488, y: -32)
  var visible = true
  var visibilityReads = 0
  var receipts: [ScreenGuidanceContinuationObservation] = []

  init(windowID: CGWindowID? = 42) throws {
    let model = AppModel(acceptanceMode: true, screenGuidanceEnabled: { true })
    let evidence = OpenCompanion.ScreenEvidence(
      frameID: UUID(), revision: 1, capturedAt: 99, displayID: 7, foregroundPID: 424_242,
      foregroundName: "Authored public fixture",
      screenRect: .init(x: -600, y: -200, width: 320, height: 240), windowID: windowID,
      image: Data(), semanticText: "Authored event metadata only")
    guard model.publishSelectedCapture(evidence, token: model.capturePublicationRevision) else {
      throw FixtureFailure.publication
    }
    let scope = try model.currentSelectedGuidanceScope()
    self.model = model
    self.evidence = evidence
    self.scope = scope
    request = .init(
      prompt: "Open the public menu", expires: 280, speakAloud: false, selectedScope: scope)
  }

  func coordinator() -> ScreenGuidanceCoordinator {
    ScreenGuidanceCoordinator(
      model: model, observeInput: false, now: { 100 }, foregroundPID: { 424_242 }, settle: {},
      windowVisibility: { [weak self] _, _ in
        guard let self else { return false }
        visibilityReads += 1
        return visible
      },
      onContinue: { [weak self] _, _, _, observation in self?.receipts.append(observation) })
  }

  func accept(on coordinator: ScreenGuidanceCoordinator, selected: Bool = true) {
    let request = ScreenGuidanceRequest(
      id: request.id, prompt: request.prompt, expires: request.expires, speakAloud: false,
      selectedScope: selected ? scope : nil)
    coordinator.accept(
      target: .init(
        x: 0.25, y: 0.25, width: 0.2, height: 0.1,
        instruction: "Open the public menu.", advanceOn: "click"),
      evidence: evidence, generation: model.taskGeneration, request: request)
  }

  private enum FixtureFailure: Error { case publication }
}
