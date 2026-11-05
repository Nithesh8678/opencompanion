import Foundation
import Testing

@testable import CompanionStore

private func fixtureURL() throws -> URL {
  let folder = FileManager.default.temporaryDirectory.appendingPathComponent(
    "OpenCompanionStoreTests-\(UUID().uuidString)")
  try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
  return folder.appendingPathComponent("store.sqlite")
}

@Test func recordsPersistSearchUpdateDeleteAndExport() async throws {
  let url = try fixtureURL()
  defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
  let first = try LocalStore(url: url)
  let original = try await first.saveRecord(
    id: "note", kind: "note", title: "100% local", body: "Keep this", payload: Data())
  _ = try await first.saveRecord(
    id: "other", kind: "document", title: "1000 local", body: "Elsewhere\0Unicode தமிழ்", payload: nil
  )
  let second = try LocalStore(url: url)
  #expect(try await second.records(kind: "document").first?.body == "Elsewhere\0Unicode தமிழ்")
  let saved = try await second.records(kind: "note", query: "%")
  #expect(saved.count == 1)
  #expect(saved.first?.payload == Data())
  let updated = try await second.saveRecord(
    id: "note", kind: "note", title: "Changed", body: "A durable edit", payload: Data([1, 2, 3]))
  #expect(updated.createdAt == original.createdAt)
  #expect(updated.body == "A durable edit")
  let exported = try await second.exportData()
  let object = try #require(JSONSerialization.jsonObject(with: exported) as? [String: Any])
  #expect(object["schemaVersion"] as? Int == LocalStore.schemaVersion)
  #expect((object["records"] as? [[String: Any]])?.count == 2)
  try await second.deleteRecord(id: "note")
  #expect(try await first.records(kind: "note").isEmpty)
}

@Test func migratesVersionOneWithoutLosingContent() async throws {
  let url = try fixtureURL()
  defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
  // Construct a v1 fixture with the real record schema and no later tables.
  do {
    let database = try SQLiteDatabase(url: url)
    try database.execute("DROP TABLE deleted_conversations")
    try database.execute("DROP TABLE routines")
    try database.execute("DROP TABLE action_receipts")
    try database.execute("DROP TABLE jobs")
    try database.execute(
      "INSERT INTO records VALUES('old','memory','Prior note','Survives',NULL,1,1)")
    try database.execute("PRAGMA user_version=1")
  }
  let migrated = try LocalStore(url: url)
  #expect(try await migrated.records().first?.body == "Survives")
  let job = try await migrated.enqueueJob(instruction: "Read selected file", scope: "selected-file")
  #expect(job.status == .queued)
  try await migrated.saveRoutine(
    Routine(
      title: "Review", instruction: "Review notes", scope: "notes", interval: 60, nextRunAt: Date())
  )
  #expect(try await migrated.routines().count == 1)
}

@Test func rejectsFutureSchemaWithoutDowngrading() throws {
  let url = try fixtureURL()
  defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
  do {
    let database = try SQLiteDatabase(url: url)
    try database.execute("PRAGMA user_version=999")
  }
  #expect(throws: StoreError.unsupportedSchema(999)) { _ = try LocalStore(url: url) }
}

@Test func leasesAreExclusiveAcrossConnectionsAndCannotBeStolenEarly() async throws {
  let url = try fixtureURL()
  defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
  let one = try LocalStore(url: url)
  let two = try LocalStore(url: url)
  let start = Date(timeIntervalSince1970: 1_000)
  let job = try await one.enqueueJob(
    instruction: "Summarize", scope: "notes", retryClass: .idempotent, retryBudget: 2, now: start)
  let lease = try await one.acquireLease(jobID: job.id, owner: "one", duration: 60, now: start)
  await #expect(throws: StoreError.leaseUnavailable) {
    _ = try await two.acquireLease(jobID: job.id, owner: "two", now: start)
  }
  #expect(try await two.recoverInterruptedJobs(now: start.addingTimeInterval(59)).isEmpty)
  let renewed = try await one.renewLease(lease, duration: 120, now: start.addingTimeInterval(30))
  #expect(renewed.token == lease.token)
  #expect(try await two.recoverInterruptedJobs(now: start.addingTimeInterval(61)).isEmpty)
  try await one.checkpointJob(
    renewed, checkpoint: Data("step2".utf8), progress: 0.5, now: start.addingTimeInterval(70))
  #expect(try await two.job(id: job.id).progress == 0.5)
}

@Test func interruptedEffectNeedsObservationBeforeRetry() async throws {
  let url = try fixtureURL()
  defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
  let first = try LocalStore(url: url)
  let time = Date(timeIntervalSince1970: 1_000)
  let job = try await first.enqueueJob(
    instruction: "Send a requested message", scope: "approved-recipient",
    retryClass: .requiresReconciliation, retryBudget: 1, now: time)
  let lease = try await first.acquireLease(
    jobID: job.id, owner: "before-crash", duration: 10, now: time)
  _ = try await first.startAction(
    lease, id: "send-1", operation: "send", retryClass: .requiresReconciliation, now: time)
  // New actor models reopening persisted state after a process interruption.
  let relaunched = try LocalStore(url: url)
  let later = time.addingTimeInterval(11)
  let recovered = try await relaunched.recoverInterruptedJobs(now: later)
  #expect(recovered.first?.status == .outcomeUnknown)
  #expect(try await relaunched.actionReceipts(jobID: job.id).first?.status == .outcomeUnknown)
  await #expect(throws: StoreError.reconciliationRequired) {
    _ = try await relaunched.acquireLease(jobID: job.id, owner: "new", now: later)
  }
  await #expect(throws: StoreError.reconciliationRequired) {
    try await relaunched.retryJob(id: job.id, now: later)
  }
  await #expect(throws: StoreError.staleLease) {
    try await first.completeAction(lease, actionID: "send-1", succeeded: true, now: later)
  }
  try await relaunched.reconcileAction(
    id: "send-1", observedSucceeded: true, evidence: Data("Message found in recipient thread".utf8),
    now: later)
  try await relaunched.retryJob(id: job.id, now: later)
  let newLease = try await relaunched.acquireLease(jobID: job.id, owner: "new", now: later)
  await #expect(throws: StoreError.reconciliationRequired) {
    _ = try await relaunched.startAction(newLease, id: "send-1", operation: "send", now: later)
  }
  try await relaunched.finishJob(newLease, succeeded: true, now: later)
  #expect(try await relaunched.job(id: job.id).status == .succeeded)
}

@Test func safeRetryStopsWhenBudgetIsSpent() async throws {
  let url = try fixtureURL()
  defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
  let store = try LocalStore(url: url)
  let now = Date(timeIntervalSince1970: 1_000)
  let job = try await store.enqueueJob(
    instruction: "Read metadata", scope: "file", retryClass: .idempotent, retryBudget: 1, now: now)
  let first = try await store.acquireLease(jobID: job.id, owner: "worker", duration: 1, now: now)
  _ = try await store.startAction(first, operation: "read", retryClass: .idempotent, now: now)
  #expect(
    try await store.recoverInterruptedJobs(now: now.addingTimeInterval(2)).first?.status == .queued)
  _ = try await store.acquireLease(
    jobID: job.id, owner: "worker", duration: 1, now: now.addingTimeInterval(2))
  #expect(
    try await store.recoverInterruptedJobs(now: now.addingTimeInterval(4)).first?.status == .failed)
  #expect(try await store.job(id: job.id).attempts == 2)
}

@Test func cancellationPersistsAndRejectsLateWrites() async throws {
  let url = try fixtureURL()
  defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
  let store = try LocalStore(url: url)
  let job = try await store.enqueueJob(instruction: "Edit selected document", scope: "file")
  let lease = try await store.acquireLease(jobID: job.id, owner: "worker")
  _ = try await store.startAction(lease, operation: "edit")
  try await store.cancelJob(id: job.id)
  let cancelled = try await store.job(id: job.id)
  #expect(cancelled.status == .cancelled)
  #expect(cancelled.cancellationGeneration == lease.cancellationGeneration + 1)
  #expect(try await store.actionReceipts(jobID: job.id).first?.status == .outcomeUnknown)
  await #expect(throws: StoreError.staleLease) {
    try await store.checkpointJob(lease, checkpoint: nil, progress: 0.8)
  }
  #expect(try await store.recoverInterruptedJobs(now: Date().addingTimeInterval(500)).isEmpty)
}

@Test func routinesHaveBoundedMissedRunAndDuplicateSemantics() async throws {
  let url = try fixtureURL()
  defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
  let store = try LocalStore(url: url)
  let now = Date(timeIntervalSince1970: 1_000)
  try await store.saveRoutine(
    Routine(
      id: "skip", title: "Skip", instruction: "Read", scope: "file", interval: 60,
      nextRunAt: now.addingTimeInterval(-600), missedRunPolicy: .skip))
  try await store.saveRoutine(
    Routine(
      id: "catchup", title: "Once", instruction: "Review", scope: "notes", interval: 60,
      nextRunAt: now.addingTimeInterval(-600), missedRunPolicy: .runOnce))
  let due = try await store.enqueueDueRoutines(now: now)
  #expect(due.count == 1)
  #expect(due.first?.instruction == "Review")
  let second = try LocalStore(url: url)
  #expect(try await second.enqueueDueRoutines(now: now).isEmpty)
  #expect(try await second.routines().allSatisfy { $0.nextRunAt > now })
}
