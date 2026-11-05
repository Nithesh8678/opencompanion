import CompanionCore
import CompanionStore
import Foundation
import Testing

@testable import OpenCompanion

/// The real persistence/open/delete paths with isolated SQLite files. No turn
/// task, provider, microphone, capture, windows or user library is started.
@Suite @MainActor struct AppModelConversationPersistenceTests {
  @Test func completedTurnsSaveOneStableConversation() async throws {
    let (url, store) = try fixtureStore()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let model = AppModel(acceptanceMode: true, store: store)
    let id = model.conversationID
    model.messages = transcript("First")
    await model.persistConversation()
    let first = try await store.record(id: id)
    model.stop()
    #expect(model.conversationID == id)
    model.messages += transcript("Second")
    await model.persistConversation()

    let records = try await store.records(kind: "conversation")
    #expect(records.count == 1 && records.first?.id == id)
    #expect(records.first?.createdAt == first.createdAt)
    let lines = try decoded(try #require(records.first))
    #expect(lines.map(\.text) == model.messages.map(\.text))
    #expect(lines.count == 4)
  }

  @Test func reopenReadsLatestStoredTranscriptAndRetainsItsIdentity() async throws {
    let (url, store) = try fixtureStore()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let original = transcript("Original")
    let oldLibraryRow = try #require(
      try await store.saveConversation(
        id: "reopened-chat", title: "Original", body: "Original",
        payload: JSONEncoder().encode(original)))
    let latest = original + transcript("Newer saved turn")
    _ = try await store.saveConversation(
      id: oldLibraryRow.id, title: "Original", body: latest.map(\.text).joined(separator: "\n"),
      payload: JSONEncoder().encode(latest))
    let model = AppModel(acceptanceMode: true, store: store)
    model.input = "Previous unsent draft"
    model.selectedContext = "Previous selected context"
    model.contextTitle = "Old attachment"
    model.evidence = screenFrame()
    let opening = try #require(model.openRecord(oldLibraryRow))
    await opening.value

    #expect(model.conversationID == oldLibraryRow.id)
    #expect(model.messages.map(\.text) == latest.map(\.text))
    #expect(model.input.isEmpty && model.selectedContext.isEmpty && model.evidence == nil)
    model.messages += transcript("Follow-up")
    await model.persistConversation()
    #expect(try await store.records(kind: "conversation").count == 1)
    #expect(try decoded(await store.record(id: oldLibraryRow.id)).count == 6)
  }

  @Test func newConversationClearsPrivateContextAndKeepsIndependentNotebookAndHistory() async throws
  {
    let (url, store) = try fixtureStore()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let model = AppModel(acceptanceMode: true, store: store)
    model.messages = transcript("Saved")
    await model.persistConversation()
    let oldID = model.conversationID
    let notebook = BuiltInLessons.lever()
    model.scene = notebook
    model.input = "Old draft"
    model.selectedContext = "Old selected memory"
    model.contextTitle = "Old memory"
    model.evidence = screenFrame()
    model.section = "Notebook"
    let generation = model.taskGeneration
    model.newConversation()

    #expect(model.conversationID != oldID)
    #expect(UUID(uuidString: model.conversationID) != nil)
    #expect(model.taskGeneration > generation)
    #expect(model.messages.isEmpty && model.input.isEmpty)
    #expect(model.selectedContext.isEmpty && model.contextTitle.isEmpty && model.evidence == nil)
    #expect(model.section == "Companion")
    #expect(model.scene?.id == notebook.id && model.scene?.revision == notebook.revision)
    await model.persistConversation()
    #expect(try await store.records(kind: "conversation").count == 1)
    model.messages = transcript("Independent")
    await model.persistConversation()
    #expect(try await store.records(kind: "conversation").count == 2)
    #expect(
      try decoded(await store.record(id: oldID)).map(\.text) == transcript("Saved").map(\.text))
  }

  @Test func deletingActiveChatStopsItAndCannotResaveItsTranscript() async throws {
    let (url, store) = try fixtureStore()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let model = AppModel(acceptanceMode: true, store: store)
    model.messages = transcript("Delete")
    await model.persistConversation()
    let oldID = model.conversationID
    let oldTranscript = try JSONEncoder().encode(model.messages)
    let deletion = try #require(model.deleteRecord(oldID))
    #expect(model.conversationID != oldID && model.messages.isEmpty)
    await deletion.value
    model.stop()
    await model.persistConversation()
    #expect(try await store.records(kind: "conversation").isEmpty)
    #expect(
      try await store.saveConversation(
        id: oldID, title: "Delayed old completion", body: "Old transcript", payload: oldTranscript)
        == nil)
    #expect(try await store.records(kind: "conversation").isEmpty)
  }

  @Test func deletingDifferentHistoryDoesNotResetActiveChatOrDraft() async throws {
    let (url, store) = try fixtureStore()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let other = try #require(
      try await store.saveConversation(
        id: "other-history", title: "Other", body: "Other",
        payload: JSONEncoder().encode(transcript("Other"))))
    let model = AppModel(acceptanceMode: true, store: store)
    model.messages = transcript("Active")
    await model.persistConversation()
    let activeID = model.conversationID
    let generation = model.taskGeneration
    model.input = "Keep this draft"
    let deletion = try #require(model.deleteRecord(other.id))
    await deletion.value
    #expect(model.conversationID == activeID && model.taskGeneration == generation)
    #expect(model.input == "Keep this draft")
    #expect(model.messages.map(\.text) == transcript("Active").map(\.text))
    #expect(try await store.records(kind: "conversation").map(\.id) == [activeID])
  }

  @Test func staleLibraryRowCannotReopenOrResurrectDeletedHistory() async throws {
    let (url, store) = try fixtureStore()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let row = try #require(
      try await store.saveConversation(
        id: "deleted-history", title: "Deleted", body: "Deleted",
        payload: JSONEncoder().encode(transcript("Deleted"))))
    try await store.deleteConversation(id: row.id)
    let model = AppModel(acceptanceMode: true, store: store)
    let opening = try #require(model.openRecord(row))
    await opening.value
    #expect(model.conversationID != row.id && model.messages.isEmpty)
    #expect(model.error != nil)
    await model.persistConversation()
    #expect(try await store.records(kind: "conversation").isEmpty)
  }

  @Test func queuedReopenCannotReplaceAnExplicitNewChat() async throws {
    let (url, store) = try fixtureStore()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let row = try #require(
      try await store.saveConversation(
        id: "queued-history", title: "History", body: "History",
        payload: JSONEncoder().encode(transcript("History"))))
    let model = AppModel(acceptanceMode: true, store: store)
    let opening = try #require(model.openRecord(row))
    model.newConversation()
    let newID = model.conversationID
    await opening.value
    #expect(model.conversationID == newID && model.messages.isEmpty && model.error == nil)
  }

  private func transcript(_ prefix: String) -> [ChatLine] {
    [
      .init(role: "user", text: "\(prefix) question"),
      .init(role: "assistant", text: "\(prefix) answer"),
    ]
  }

  private func decoded(_ record: StoredRecord) throws -> [ChatLine] {
    try JSONDecoder().decode([ChatLine].self, from: #require(record.payload))
  }

  private func fixtureStore() throws -> (URL, LocalStore) {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(
      "OpenCompanionAppConversation-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let url = folder.appendingPathComponent("library.sqlite")
    return (url, try LocalStore(url: url))
  }

  private func screenFrame() -> OpenCompanion.ScreenEvidence {
    .init(
      frameID: UUID(), revision: 1, capturedAt: 1, displayID: 7, foregroundPID: 123,
      foregroundName: "Public fixture", screenRect: .init(x: 0, y: 0, width: 100, height: 100),
      image: Data([0]), semanticText: "Public screen fixture")
  }
}
