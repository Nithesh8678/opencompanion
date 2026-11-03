import Foundation
import Testing

@testable import CompanionStore

@Suite struct MemoryEditingTests {
  private func fixtureURL() -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("OpenCompanionMemoryEditing-\(UUID().uuidString)")
      .appendingPathComponent("library.sqlite")
  }

  @Test func editingPersistsTheSameMemoryAndPreservesOpaqueMetadata() async throws {
    let url = fixtureURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let first = try LocalStore(url: url)
    let provenance = Data("{\"scope\":\"user-selected\",\"source\":\"manual\"}".utf8)
    let original = try await first.saveRecord(
      id: "chosen-memory", kind: "memory", title: "Original", body: "Before", payload: provenance)

    let updated = try await first.updateMemory(
      original, title: "  Updated title  ", body: "Keep my formatting.\n\nதமிழ் preferences.")
    #expect(updated.id == original.id)
    #expect(updated.kind == original.kind)
    #expect(updated.createdAt == original.createdAt)
    #expect(updated.payload == provenance)
    #expect(updated.title == "Updated title")
    #expect(updated.body == "Keep my formatting.\n\nதமிழ் preferences.")
    #expect(updated.updatedAt >= original.updatedAt)

    let reopened = try LocalStore(url: url)
    let persisted = try await reopened.records(kind: "memory")
    #expect(persisted == [updated])
  }

  @Test func staleEditorCannotOverwriteANewerEdit() async throws {
    let url = fixtureURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let one = try LocalStore(url: url)
    let two = try LocalStore(url: url)
    let original = try await one.saveRecord(kind: "memory", title: "Shared", body: "Original")
    let newer = try await two.updateMemory(original, title: "Newer", body: "Keep this edit")

    await #expect(throws: (any Error).self) {
      _ = try await one.updateMemory(original, title: "Stale", body: "Must not replace it")
    }
    #expect(try await one.records(kind: "memory") == [newer])
  }

  @Test func deletedMemoryIsNotRecreatedByAnOpenEditor() async throws {
    let url = fixtureURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let store = try LocalStore(url: url)
    let original = try await store.saveRecord(kind: "memory", title: "Delete me", body: "Old")
    try await store.deleteRecord(id: original.id)

    await #expect(throws: StoreError.notFound(original.id)) {
      _ = try await store.updateMemory(original, title: "No resurrection", body: "Draft")
    }
    #expect(try await store.records().isEmpty)
  }

  @Test func invalidDraftAndOtherRecordKindsLeaveStoredContentUntouched() async throws {
    let url = fixtureURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let store = try LocalStore(url: url)
    let original = try await store.saveRecord(kind: "memory", title: "Keep", body: "Original")
    let notebook = try await store.saveRecord(kind: "notebook", title: "Notebook", body: "Scene")
    for (title, body) in [(" \n", "Body"), ("Title", " \n\t")] {
      await #expect(throws: (any Error).self) {
        _ = try await store.updateMemory(original, title: title, body: body)
      }
    }
    await #expect(throws: (any Error).self) {
      _ = try await store.updateMemory(notebook, title: "Wrong kind", body: "Do not mutate")
    }
    #expect(try await store.records(kind: "memory") == [original])
    #expect(try await store.records(kind: "notebook") == [notebook])
  }
}
