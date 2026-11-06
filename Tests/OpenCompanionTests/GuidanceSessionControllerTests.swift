import CompanionCore
import CompanionStore
import Foundation
import Testing

@testable import OpenCompanion

@MainActor struct GuidanceSessionControllerTests {
  @Test func turnTokensOwnOnlyTheirCurrentCheckAndObservedAction() throws {
    let controller = GuidanceSessionController()
    try controller.start(goal: "Update a public document", speakAloud: false)
    let first = try controller.beginCheck()
    try controller.presentAction(
      token: first, instruction: "Enter the title", label: "Title", kind: .manual)
    try controller.finishTurn(token: first, fallbackSummary: "A field was marked")
    #expect(controller.owns(first) && controller.workflow?.phase == .awaitingUser)
    try controller.observeAction(token: first, kind: .manualContinue)
    #expect(!controller.owns(first) && controller.workflow?.phase == .ready)
    #expect(controller.workflow?.checks.last?.outcome == nil)
    let second = try controller.beginCheck()
    #expect(
      second.workflowID == first.workflowID && second.checkID != first.checkID
        && second.runID != first.runID)
    #expect(throws: GuidanceSessionController.Failure.staleTurn) {
      try controller.assess(token: first, outcome: .goalComplete, summary: "Late result")
    }
    controller.pause()
    #expect(!controller.owns(second) && controller.workflow?.phase == .paused)
    #expect(controller.workflow?.checks.last?.disposition == .interrupted)
    let resumed = try controller.beginCheck()
    #expect(resumed.checkID != second.checkID && controller.owns(resumed))
  }

  @Test func missingStatusFinishesUncertainAndInvalidStartsPreserveTheActiveWorkflow() throws {
    let controller = GuidanceSessionController()
    try controller.start(goal: "Inspect the current public control")
    let token = try controller.beginCheck()
    try controller.finishTurn(token: token, fallbackSummary: String(repeating: "é", count: 2_000))
    #expect(controller.workflow?.phase == .needsAttention)
    #expect(controller.workflow?.checks.last?.outcome == .uncertain)
    #expect(controller.workflow?.checks.last?.summary?.utf8.count == 2_048)
    let original = controller.workflow
    #expect(throws: GuidanceWorkflow.Failure.self) { try controller.start(goal: " \n") }
    #expect(controller.workflow == original && controller.owns(token))
    let next = try controller.beginCheck()
    try controller.presentAction(token: next, instruction: "Open the control", kind: .click)
    let proposed = controller.workflow
    #expect(throws: GuidanceWorkflow.Failure.self) {
      try controller.assess(token: next, outcome: .loading, summary: "Still loading")
    }
    #expect(controller.workflow == proposed)
  }

  @Test func immutableQueuedSnapshotsUseTheLatestFullRecordCAS() async throws {
    let url = databaseURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let store = try LocalStore(url: url)
    let controller = GuidanceSessionController(store: store)
    try controller.start(goal: "Public saved task", speakAloud: false)
    let first = try controller.beginCheck()
    try controller.presentAction(token: first, instruction: "Use the public field", kind: .manual)
    try controller.observeAction(token: first, kind: .manualContinue)
    let second = try controller.beginCheck()
    try controller.assess(
      token: second, outcome: .goalComplete, summary: "The fresh screen looks complete")
    await controller.flushPersistence()
    let workflow = try #require(controller.workflow)
    let record = try await store.record(id: workflow.id.uuidString)
    let payload = try #require(record.payload)
    #expect(try GuidanceWorkflow.decode(payload) == workflow)
    #expect(record.kind == "guidance" && record.body == workflow.goal)
    #expect(try await store.records(kind: "guidance").count == 1)
    #expect(controller.persistenceIssue == nil && workflow.speakAloud == false)
    let reopened = GuidanceSessionController(store: store)
    try await reopened.restore(record: record, stillCurrent: { true })
    #expect(
      reopened.workflow?.phase == .paused
        && reopened.workflow?.checks.last?.outcome == .goalComplete)
    let recheck = try reopened.beginCheck()
    try reopened.assess(
      token: recheck, outcome: .uncertain, summary: "Check again before concluding")
    await reopened.flushPersistence()
    #expect(reopened.persistenceIssue == nil && reopened.workflow?.checks.count == 3)
  }

  @Test func aCASConflictBlocksFurtherWritesUntilExplicitLatestRestore() async throws {
    let url = databaseURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let firstStore = try LocalStore(url: url)
    let secondStore = try LocalStore(url: url)
    let first = GuidanceSessionController(store: firstStore)
    try first.start(goal: "Shared public guide")
    await first.flushPersistence()
    let id = try #require(first.workflow?.id.uuidString)
    let initial = try await firstStore.record(id: id)
    let second = GuidanceSessionController(store: secondStore)
    try await second.restore(record: initial, stillCurrent: { true })
    let secondToken = try second.beginCheck()
    try second.assess(
      token: secondToken, outcome: .progress, summary: "Another owner inspected the fresh page")
    await second.flushPersistence()
    let latest = try await secondStore.record(id: id)
    #expect(latest != initial)
    _ = try first.beginCheck()
    await first.flushPersistence()
    #expect(first.persistenceIssue != nil)
    first.pause()
    await first.flushPersistence()
    #expect(try await secondStore.record(id: id) == latest)
    // The supplied row is deliberately stale. Restore must refetch after its
    // queued writes, rather than publishing or overwriting this old payload.
    try await first.restore(record: initial, stillCurrent: { true })
    await first.flushPersistence()
    #expect(first.persistenceIssue == nil && first.workflow?.phase == .paused)
    #expect(first.workflow?.checks.last?.summary == "Another owner inspected the fresh page")
    #expect(first.workflow?.checks.count == 1)
  }

  @Test func externalDeletionCannotBeRecreatedByDelayedOrLaterSnapshots() async throws {
    let url = databaseURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let store = try LocalStore(url: url)
    let deletingStore = try LocalStore(url: url)
    let controller = GuidanceSessionController(store: store)
    try controller.start(goal: "A guide that is deleted elsewhere")
    await controller.flushPersistence()
    let id = try #require(controller.workflow?.id.uuidString)
    let original = try await store.record(id: id)
    try await deletingStore.deleteGuidance(id: id)
    _ = try controller.beginCheck()
    await controller.flushPersistence()
    #expect(controller.persistenceIssue != nil)
    controller.pause()
    await controller.flushPersistence()
    #expect(try await store.records(kind: "guidance").isEmpty)
    await #expect(throws: StoreError.notFound(id)) {
      try await controller.restore(record: original, stillCurrent: { true })
    }
    #expect(try await store.records(kind: "guidance").isEmpty)
  }

  @Test func ownDeleteRevokesPendingCreateAndTombstonesItsIdentity() async throws {
    let url = databaseURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let store = try LocalStore(url: url)
    let controller = GuidanceSessionController(store: store)
    try controller.start(goal: "Delete before a queued save completes")
    let token = try controller.beginCheck()
    let id = token.workflowID.uuidString
    try await controller.delete(id: id)
    await controller.flushPersistence()
    #expect(controller.workflow == nil && !controller.owns(token))
    #expect(try await store.records(kind: "guidance").isEmpty)
    await #expect(throws: StoreError.notFound(id)) {
      try await store.createGuidance(id: id, title: "Late", body: "Late", payload: Data())
    }
  }

  @Test func restoreStartedDuringDeletionCannotPublishOrReopenTheDeletedGuide() async throws {
    let url = databaseURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let store = try LocalStore(url: url)
    let saved = try GuidanceWorkflow(goal: "Delete this public saved guide")
    let record = try await store.createGuidance(
      id: saved.id.uuidString, title: saved.goal, body: saved.goal,
      payload: JSONEncoder().encode(saved))
    let barrier = GuidanceDeleteBarrier()
    let controller = GuidanceSessionController(
      store: store,
      deleteCheckpoint: { store, id in
        await barrier.pause()
        try await store.deleteGuidance(id: id)
      })
    var persisted = 0
    controller.onPersisted = { persisted += 1 }
    let deletion = Task { try await controller.delete(id: record.id) }
    await barrier.waitUntilEntered()
    // The row still exists and deletion has already revoked ownership. This
    // ordering previously let a newer restore publish before deletion resumed.
    #expect(try await store.record(id: record.id) == record)
    await #expect(throws: GuidanceSessionController.Failure.staleTurn) {
      try await controller.restore(record: record, stillCurrent: { true })
    }
    let remainedDetachedDuringDelete = controller.workflow == nil && persisted == 0
    await barrier.release()
    try await deletion.value
    #expect(remainedDetachedDuringDelete)
    await #expect(throws: GuidanceSessionController.Failure.staleTurn) {
      try await controller.restore(record: record, stillCurrent: { true })
    }
    await controller.flushPersistence()
    #expect(controller.workflow == nil && persisted == 1)
    #expect(try await store.records(kind: "guidance").isEmpty)
  }

  @Test func failedDeletionRevokesOldLeasesButAllowsExplicitLatestRestore() async throws {
    let url = databaseURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let store = try LocalStore(url: url)
    let saved = try GuidanceWorkflow(goal: "Keep the guide when deletion fails")
    let record = try await store.createGuidance(
      id: saved.id.uuidString, title: saved.goal, body: saved.goal,
      payload: JSONEncoder().encode(saved))
    let controller = GuidanceSessionController(
      store: store, deleteCheckpoint: { _, _ in throw GuidanceDeleteFailure.unavailable })
    await #expect(throws: GuidanceDeleteFailure.unavailable) {
      try await controller.delete(id: record.id)
    }
    #expect(controller.persistenceIssue != nil)
    try await controller.restore(record: record, stillCurrent: { true })
    await controller.flushPersistence()
    #expect(controller.workflow?.id == saved.id && controller.workflow?.phase == .paused)
    #expect(controller.persistenceIssue == nil)
    #expect(try await store.records(kind: "guidance").count == 1)
  }

  @Test func staleRestoreCannotReplaceCurrentProgress() async throws {
    let url = databaseURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let store = try LocalStore(url: url)
    let controller = GuidanceSessionController(store: store)
    try controller.start(goal: "Original public guide")
    await controller.flushPersistence()
    let oldID = try #require(controller.workflow?.id.uuidString)
    let original = try await store.record(id: oldID)
    try controller.start(goal: "Keep this new public guide")
    let current = try controller.beginCheck()
    let kept = controller.workflow
    await #expect(throws: GuidanceSessionController.Failure.staleTurn) {
      try await controller.restore(record: original, stillCurrent: { false })
    }
    #expect(controller.workflow == kept && controller.currentToken == current)
    #expect(controller.owns(current))
    let cancelledRestore = Task { @MainActor in
      withUnsafeCurrentTask { $0?.cancel() }
      do {
        try await controller.restore(record: original, stillCurrent: { true })
        return false
      } catch is CancellationError {
        return true
      } catch {
        return false
      }
    }
    let rejectedCancellation = await cancelledRestore.value
    #expect(rejectedCancellation)
    #expect(controller.workflow == kept && controller.currentToken == current)
    #expect(controller.owns(current))
    await controller.flushPersistence()
    #expect(try await store.records(kind: "guidance").count == 2)
  }

  @Test func lateStoreBindingSavesTheCurrentSnapshotAndPlannerContextStaysSemantic() async throws {
    let url = databaseURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let controller = GuidanceSessionController()
    try controller.start(goal: "Public semantic progress only")
    let token = try controller.beginCheck()
    try controller.presentAction(
      token: token, instruction: String(repeating: "a", count: 2_048), kind: .click)
    try controller.assess(
      token: token, outcome: .progress, summary: "A new action is proposed, not verified")
    #expect(controller.persistenceIssue != nil)
    let store = try LocalStore(url: url)
    controller.setStore(store)
    await controller.flushPersistence()
    let id = try #require(controller.workflow?.id.uuidString)
    let row = try await store.record(id: id)
    let payload = try #require(row.payload)
    #expect(try GuidanceWorkflow.decode(payload) == controller.workflow)
    #expect(controller.persistenceIssue == nil)
    let context = controller.plannerContext
    #expect(context.utf8.count < 24 * 1_024)
    #expect(context.contains("nextActionProposed") && context.contains("modelAssessment"))
    #expect(
      !context.contains("frameID") && !context.contains("screenRect")
        && !context.contains("foregroundPID"))
    #expect(!context.contains(String(repeating: "a", count: 161)))
  }

  @Test func detachCheckpointsWithoutDeletingAndPersistenceCallbacksReflectSuccessfulWrites()
    async throws
  {
    let url = databaseURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let store = try LocalStore(url: url)
    let controller = GuidanceSessionController(store: store)
    var persisted = 0
    controller.onPersisted = { persisted += 1 }
    try controller.start(goal: "Leave this public guide resumable")
    let token = try controller.beginCheck()
    try controller.presentAction(token: token, instruction: "Enter the public name", kind: .manual)
    controller.detach()
    #expect(controller.workflow == nil && !controller.owns(token))
    await controller.flushPersistence()
    let saved = try await store.record(id: token.workflowID.uuidString)
    let payload = try #require(saved.payload)
    let detached = try GuidanceWorkflow.decode(payload)
    #expect(
      detached.phase == .paused && detached.actions.count == 1 && detached.pendingCheckID == nil)
    #expect(persisted > 0)
    let beforeDelete = persisted
    try await controller.delete(id: saved.id)
    #expect(persisted == beforeDelete + 1)
    #expect(try await store.records(kind: "guidance").isEmpty)
  }

  private func databaseURL() -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent(
        "OpenCompanion-GuidanceSession-\(UUID().uuidString)", isDirectory: true
      )
      .appendingPathComponent("store.sqlite")
  }
}

private enum GuidanceDeleteFailure: Error, Equatable { case unavailable }

private actor GuidanceDeleteBarrier {
  private var entered = false
  private var released = false
  private var enteredWaiter: CheckedContinuation<Void, Never>?
  private var releaseWaiter: CheckedContinuation<Void, Never>?

  func pause() async {
    entered = true
    enteredWaiter?.resume()
    enteredWaiter = nil
    guard !released else { return }
    await withCheckedContinuation { releaseWaiter = $0 }
  }

  func waitUntilEntered() async {
    guard !entered else { return }
    await withCheckedContinuation { enteredWaiter = $0 }
  }

  func release() {
    released = true
    releaseWaiter?.resume()
    releaseWaiter = nil
  }
}
