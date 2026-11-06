import Foundation
import Testing

@testable import CompanionStore

struct GuidanceRetentionTests {
  @Test func versionFourMigrationPreservesAllExistingContentAndConversationTombstones() async throws
  {
    let url = databaseURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let originals: [StoredRecord]
    let job: DurableJob
    let routine = Routine(
      id: "retained-routine", title: "Keep", instruction: "Public routine", scope: "local",
      interval: 60, nextRunAt: Date(timeIntervalSince1970: 1_000))
    do {
      let store = try LocalStore(url: url)
      _ = try await store.saveConversation(
        id: "conversation", title: "Keep chat", body: "Public transcript", payload: Data([0, 1]))
      _ = try await store.saveRecord(
        id: "notebook", kind: "notebook", title: "Keep notebook", body: "Public scene",
        payload: Data([2, 3]))
      _ = try await store.saveRecord(
        id: "memory", kind: "memory", title: "Keep memory", body: "Public memory",
        payload: Data([4, 5]))
      try await store.deleteConversation(id: "retired-conversation")
      job = try await store.enqueueJob(instruction: "Keep job", scope: "local")
      try await store.saveRoutine(routine)
      originals = try await store.records()
    }
    do {
      let database = try SQLiteDatabase(url: url)
      try database.execute("DROP TABLE deleted_guidance")
      try database.execute("PRAGMA user_version=4")
    }
    let migrated = try LocalStore(url: url)
    #expect(try await migrated.records() == originals)
    #expect(try await migrated.jobs() == [job])
    #expect(try await migrated.routines() == [routine])
    #expect(
      try await migrated.saveConversation(
        id: "retired-conversation", title: "Late", body: "Must remain deleted") == nil)
    let guide = try await migrated.createGuidance(
      id: "new-guidance", title: "New", body: "New public goal", payload: Data([6]))
    let reopened = try LocalStore(url: url)
    #expect(try await reopened.record(id: guide.id) == guide)
    #expect(try await reopened.records().count == originals.count + 1)
  }

  @Test func twoConnectionsRequireTheExactLatestRecordAndPreserveCreationIdentity() async throws {
    let url = databaseURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let first = try LocalStore(url: url)
    let second = try LocalStore(url: url)
    let original = try await first.createGuidance(
      id: "shared-guide", title: "Public goal", body: "Before", payload: Data([1]))
    let stale = try await second.record(id: original.id)
    let updated = try await first.updateGuidance(
      original, title: "Updated", body: "Observed progress", payload: Data([2]))
    #expect(updated.id == original.id && updated.kind == "guidance")
    #expect(updated.createdAt == original.createdAt && updated.payload == Data([2]))
    await #expect(throws: StoreError.staleRecord) {
      try await second.updateGuidance(
        stale, title: "Stale", body: "Lost update", payload: Data([3]))
    }
    // Equal timestamps alone are not a CAS token: every original field matters.
    let forged = StoredRecord(
      id: updated.id, kind: updated.kind, title: updated.title, body: "Changed snapshot",
      payload: updated.payload, createdAt: updated.createdAt, updatedAt: updated.updatedAt)
    await #expect(throws: StoreError.staleRecord) {
      try await second.updateGuidance(forged, title: "Wrong", body: "Wrong", payload: Data([4]))
    }
    #expect(try await second.record(id: original.id) == updated)
    let latest = try await second.updateGuidance(
      updated, title: "Latest", body: "Second legitimate edit", payload: Data([5]))
    #expect(try await first.records(kind: "guidance") == [latest])
  }

  @Test(arguments: [false, true])
  func eitherDeletionPathRejectsLateUpdatesAndCreatesAcrossReopen(_ generic: Bool) async throws {
    let url = databaseURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let writer = try LocalStore(url: url)
    let deleting = try LocalStore(url: url)
    let original = try await writer.createGuidance(
      id: "deleted-guide", title: "Delete", body: "Private local goal", payload: Data([7]))
    if generic {
      try await deleting.deleteRecord(id: original.id)
    } else {
      try await deleting.deleteGuidance(id: original.id)
    }
    await #expect(throws: StoreError.notFound(original.id)) {
      try await writer.updateGuidance(original, title: "Late", body: "Late", payload: Data([8]))
    }
    let reopened = try LocalStore(url: url)
    await #expect(throws: StoreError.notFound(original.id)) {
      try await reopened.createGuidance(
        id: original.id, title: "Late create", body: "Late", payload: Data([9]))
    }
    for kind in ["memory", "notebook", "conversation", "note"] {
      await #expect(throws: StoreError.notFound(original.id)) {
        try await writer.saveRecord(id: original.id, kind: kind, title: "Bypass", body: "Late")
      }
    }
    #expect(try await reopened.records().isEmpty)
    let data = try await reopened.exportData()
    let exported = try JSONSerialization.jsonObject(with: data)
    let object = try #require(exported as? [String: Any])
    #expect((object["records"] as? [[String: Any]])?.isEmpty == true)
    #expect(object["deleted_guidance"] == nil)
  }

  @Test func deleteBeforeFirstCreateIsDurableAndNeverRetiresAnotherKind() async throws {
    let url = databaseURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let store = try LocalStore(url: url)
    try await store.deleteGuidance(id: "queued-guide")
    let delayed = try LocalStore(url: url)
    await #expect(throws: StoreError.notFound("queued-guide")) {
      try await delayed.createGuidance(
        id: "queued-guide", title: "Queued", body: "Late first save", payload: Data([1]))
    }
    let notebook = try await store.saveRecord(
      id: "independent", kind: "notebook", title: "Keep", body: "Scene", payload: Data([2]))
    await #expect(throws: StoreError.self) {
      try await store.deleteGuidance(id: notebook.id)
    }
    await #expect(throws: StoreError.self) {
      try await store.createGuidance(
        id: notebook.id, title: "Wrong", body: "Wrong", payload: Data([3]))
    }
    await #expect(throws: StoreError.self) {
      try await store.updateGuidance(notebook, title: "Wrong", body: "Wrong", payload: Data([4]))
    }
    #expect(try await store.record(id: notebook.id) == notebook)
    let fresh = try await delayed.createGuidance(
      id: "explicit-new-guide", title: "New", body: "Separate goal", payload: Data([5]))
    #expect(fresh.id == "explicit-new-guide")
  }

  @Test func genericAndDedicatedCreatesCannotReplaceExistingGuidance() async throws {
    let url = databaseURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let store = try LocalStore(url: url)
    let guide = try await store.createGuidance(
      id: "protected", title: "Keep", body: "Existing progress", payload: Data([1]))
    for kind in ["guidance", "notebook", "memory", "conversation", "note"] {
      await #expect(throws: StoreError.self) {
        try await store.saveRecord(id: guide.id, kind: kind, title: "Wrong", body: "Wrong")
      }
    }
    await #expect(throws: StoreError.self) {
      try await store.saveRecord(kind: "guidance", title: "Bypass create", body: "Wrong")
    }
    await #expect(throws: StoreError.self) {
      try await store.createGuidance(
        id: guide.id, title: "Duplicate", body: "Wrong", payload: Data())
    }
    #expect(try await store.record(id: guide.id) == guide)
    #expect(try await store.records().count == 1)
  }

  @Test func guidanceBoundsUseUTF8BytesAndFailuresLeaveThePreviousPayloadUntouched() async throws {
    let url = databaseURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let store = try LocalStore(url: url)
    let maximum = try await store.createGuidance(
      id: "bounded", title: String(repeating: "a", count: 256),
      body: String(repeating: "b", count: 32 * 1_024),
      payload: Data(repeating: 1, count: 128 * 1_024))
    let invalid: [(String, String, Data)] = [
      (String(repeating: "é", count: 129), "Body", Data()),
      ("Title", String(repeating: "b", count: 32 * 1_024 + 1), Data()),
      ("Title", "Body", Data(repeating: 2, count: 128 * 1_024 + 1)),
      (" \n\t", "Body", Data()),
    ]
    for (title, body, payload) in invalid {
      await #expect(throws: StoreError.self) {
        try await store.createGuidance(id: "invalid", title: title, body: body, payload: payload)
      }
      await #expect(throws: StoreError.self) {
        try await store.updateGuidance(maximum, title: title, body: body, payload: payload)
      }
    }
    #expect(try await store.records() == [maximum])
  }

  @Test(arguments: CancelledOperation.allCases)
  func cancelledTasksCannotCreateUpdateOrTombstoneGuidance(_ operation: CancelledOperation)
    async throws
  {
    let url = databaseURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let store = try LocalStore(url: url)
    let original = try await store.createGuidance(
      id: "current", title: "Keep", body: "Current state", payload: Data([1]))
    let barrier = GuidanceSaveBarrier()
    let task = Task {
      await barrier.wait()
      switch operation {
      case .create:
        _ = try await store.createGuidance(
          id: "cancelled", title: "Late", body: "Late", payload: Data())
      case .update:
        _ = try await store.updateGuidance(
          original, title: "Late", body: "Late", payload: Data([2]))
      case .delete:
        try await store.deleteGuidance(id: original.id)
      }
    }
    task.cancel()
    await barrier.release()
    await #expect(throws: CancellationError.self) { try await task.value }
    let reopened = try LocalStore(url: url)
    #expect(try await reopened.records() == [original])
    let updated = try await reopened.updateGuidance(
      original, title: "Explicit", body: "An uncancelled update remains possible",
      payload: Data([3]))
    #expect(updated.payload == Data([3]))
    let fresh = try await reopened.createGuidance(
      id: "cancelled", title: "Explicit", body: "No accidental tombstone", payload: Data([4]))
    #expect(fresh.id == "cancelled")
  }

  enum CancelledOperation: String, CaseIterable, Sendable { case create, update, delete }

  private func databaseURL() -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("OpenCompanionGuidanceRetention-\(UUID().uuidString)")
      .appendingPathComponent("library.sqlite")
  }
}

private actor GuidanceSaveBarrier {
  private var released = false
  private var continuation: CheckedContinuation<Void, Never>?

  func wait() async {
    guard !released else { return }
    await withCheckedContinuation { continuation = $0 }
  }

  func release() {
    released = true
    continuation?.resume()
    continuation = nil
  }
}
