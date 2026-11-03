import Foundation
import Testing
@testable import CompanionStore

@Test func selectedTextIsBoundedCitedAndHashRefreshes() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("OpenCompanionFiles-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let url = folder.appendingPathComponent("notes.txt")
    try Data("Alpha\nBeta\nGamma".utf8).write(to: url)
    let reader = FileContextReader()
    let context = try reader.read(url: url, allowedRoot: folder, maximumCharacters: 7)
    #expect(context.kind == "text")
    #expect(context.truncated)
    #expect(context.chunks.map(\.text).joined().count <= 7)
    #expect(context.chunks.first?.citation.contains("notes.txt, line 1") == true)
    #expect(context.excerpts(matching: "Beta", maximumCharacters: 3).map(\.text).joined().count <= 3)
    #expect(try !reader.hasChanged(context, allowedRoot: folder))
    try Data("Delta\nBeta\nGamma".utf8).write(to: url)
    #expect(try reader.hasChanged(context, allowedRoot: folder))
    #expect(throws: FileContextError.tooLarge(limit: 2)) { _ = try reader.read(url: url, maximumBytes: 2) }
}

@Test func fileScopeRejectsSiblingPrefixAndSymlinkEscape() throws {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("OpenCompanionScope-\(UUID().uuidString)")
    let allowed = base.appendingPathComponent("allowed")
    let sibling = base.appendingPathComponent("allowed-other")
    try FileManager.default.createDirectory(at: allowed, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: base) }
    let outside = sibling.appendingPathComponent("secret.txt")
    try Data("External data".utf8).write(to: outside)
    let link = allowed.appendingPathComponent("link.txt")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
    let reader = FileContextReader()
    #expect(throws: FileContextError.outsideScope) { _ = try reader.read(url: outside, allowedRoot: allowed) }
    #expect(throws: FileContextError.outsideScope) { _ = try reader.read(url: link, allowedRoot: allowed) }
}

@Test func credentialIdentifiersAreValidatedBeforeKeychainAccess() throws {
    let store = CredentialStore()
    #expect(throws: CredentialStoreError.invalidIdentifier) { try store.save(Data(), service: "", account: "test") }
    #expect(throws: CredentialStoreError.invalidIdentifier) { _ = try store.load(service: "test", account: "") }
    #expect(throws: CredentialStoreError.invalidIdentifier) { try store.delete(service: "", account: "") }
}
