import Foundation
import Testing

@testable import CompanionStore

struct ConversationRetentionTests {
  @Test(arguments: [false, true])
  func cancelledSaveCannotCreateOrOverwriteAConversation(_ alreadySaved: Bool) async throws {
    let url = try databaseURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let store = try LocalStore(url: url)
    let expected: [StoredRecord]
    if alreadySaved {
      let current = try #require(
        try await store.saveConversation(
          id: "cancelled-chat", title: "Current", body: "Keep the newer transcript",
          payload: Data("current-payload".utf8)))
      expected = [current]
    } else {
      expected = []
    }
    let barrier = ConversationSaveBarrier()
    let delayedSave = Task {
      // A cancelled task can still resume from an ordinary continuation and
      // enter another actor. The store must check before touching SQLite.
      await barrier.wait()
      return try await store.saveConversation(
        id: "cancelled-chat", title: "Old", body: "Cancelled old transcript",
        payload: Data("cancelled-payload".utf8))
    }
    delayedSave.cancel()
    await barrier.release()
    await #expect(throws: CancellationError.self) { try await delayedSave.value }
    let reopened = try LocalStore(url: url)
    #expect(try await reopened.records(kind: "conversation") == expected)
    let explicitSave = try await reopened.saveConversation(
      id: "cancelled-chat", title: "Explicit", body: "A later uncancelled save is permitted")
    #expect(explicitSave?.body == "A later uncancelled save is permitted")
  }

  @Test func turnsUpdateOneIdentityAndExportOnlyItsLatestTranscript() async throws {
    let url = try databaseURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let store = try LocalStore(url: url)
    let first = try #require(
      try await store.saveConversation(
        id: "active-chat", title: "Public question", body: "First turn",
        payload: Data("first-payload".utf8)))
    let latest = try #require(
      try await store.saveConversation(
        id: first.id, title: "Public question", body: "First turn\nSecond turn",
        payload: Data("latest-payload".utf8)))

    #expect(latest.id == first.id && latest.createdAt == first.createdAt)
    let reopened = try LocalStore(url: url)
    #expect(try await reopened.records(kind: "conversation") == [latest])
    #expect(try await reopened.record(id: first.id) == latest)
    let exported = try await reopened.exportData()
    let object = try #require(JSONSerialization.jsonObject(with: exported) as? [String: Any])
    let rows = try #require(object["records"] as? [[String: Any]])
    #expect(rows.count == 1 && rows.first?["body"] as? String == latest.body)
  }

  @Test func deletionBlocksLateSavesAcrossConnectionsAndReopen() async throws {
    let url = try databaseURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let writer = try LocalStore(url: url)
    let record = try #require(
      try await writer.saveConversation(
        id: "deleted-chat", title: "Public fixture", body: "Deleted transcript"))
    let deleting = try LocalStore(url: url)
    try await deleting.deleteRecord(id: record.id)

    #expect(
      try await writer.saveConversation(
        id: record.id, title: record.title, body: "Late completion") == nil)
    let reopened = try LocalStore(url: url)
    #expect(
      try await reopened.saveConversation(
        id: record.id, title: record.title, body: "Late after restart") == nil)
    await #expect(throws: StoreError.notFound(record.id)) {
      try await reopened.saveRecord(
        id: record.id, kind: "conversation", title: record.title, body: "Legacy save")
    }
    #expect(try await reopened.records().isEmpty)
    await #expect(throws: StoreError.notFound(record.id)) {
      try await reopened.record(id: record.id)
    }
    let exported = try await reopened.exportData()
    let object = try #require(JSONSerialization.jsonObject(with: exported) as? [String: Any])
    #expect((object["records"] as? [[String: Any]])?.isEmpty == true)
    // This checks logical retention/export, not forensic erasure of SQLite files.
    #expect(object["deleted_conversations"] == nil)
  }

  @Test func deletingBeforeTheFirstSaveAlsoPreventsResurrection() async throws {
    let url = try databaseURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let deleting = try LocalStore(url: url)
    try await deleting.deleteConversation(id: "not-yet-saved")
    let delayedWriter = try LocalStore(url: url)
    #expect(
      try await delayedWriter.saveConversation(
        id: "not-yet-saved", title: "Delayed", body: "Queued first completion") == nil)
    #expect(try await delayedWriter.records().isEmpty)
    let new = try await delayedWriter.saveConversation(
      id: "explicit-new-chat", title: "New", body: "New identity remains writable")
    #expect(new?.id == "explicit-new-chat")
  }

  @Test func conversationOperationsCannotReplaceOrDeleteAnotherRecordKind() async throws {
    let url = try databaseURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let store = try LocalStore(url: url)
    let notebook = try await store.saveRecord(
      id: "independent-notebook", kind: "notebook", title: "Keep", body: "Original",
      payload: Data([1, 2, 3]))
    await #expect(throws: StoreError.self) {
      try await store.saveConversation(id: notebook.id, title: "Wrong kind", body: "Wrong")
    }
    await #expect(throws: StoreError.self) {
      try await store.deleteConversation(id: notebook.id)
    }
    #expect(try await store.record(id: notebook.id) == notebook)
  }

  @Test func versionThreeMigrationPreservesLegacySnapshotsWithoutGuessingDuplicates() async throws {
    let url = try databaseURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let original: [StoredRecord]
    do {
      let store = try LocalStore(url: url)
      _ = try await store.saveRecord(
        id: "legacy-a", kind: "conversation", title: "Same title", body: "Earlier transcript",
        payload: Data([0, 1]))
      _ = try await store.saveRecord(
        id: "legacy-b", kind: "conversation", title: "Same title", body: "Later transcript",
        payload: Data([2, 3]))
      _ = try await store.saveRecord(
        id: "memory", kind: "memory", title: "Keep", body: "Explicit memory")
      original = try await store.records()
    }
    do {
      let database = try SQLiteDatabase(url: url)
      try database.execute("DROP TABLE deleted_guidance")
      try database.execute("DROP TABLE deleted_conversations")
      try database.execute("PRAGMA user_version=3")
    }
    let migrated = try LocalStore(url: url)
    #expect(try await migrated.records() == original)
    try await migrated.deleteConversation(id: "legacy-a")
    #expect(try await migrated.records(kind: "conversation").map(\.id) == ["legacy-b"])
    #expect(try await migrated.record(id: "memory").body == "Explicit memory")
    #expect(
      try await migrated.saveConversation(id: "legacy-a", title: "Late", body: "Late") == nil)
  }

  private func databaseURL() throws -> URL {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(
      "OpenCompanionConversationRetention-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder.appendingPathComponent("library.sqlite")
  }
}

private actor ConversationSaveBarrier {
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
