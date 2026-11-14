import Foundation
import Testing

@testable import OpenCompanion

struct CodexGuidanceSessionPolicyTests {
  private let policy = CodexGuidanceSessionPolicy()

  @Test func reuseHasSeparateIdleAgeAndTurnBudgets() {
    #expect(policy.permitsReuse(createdAt: 100, lastUsedAt: 250, turnCount: 15, now: 279))
    #expect(!policy.permitsReuse(createdAt: 100, lastUsedAt: 250, turnCount: 15, now: 280))
    #expect(!policy.permitsReuse(createdAt: 100, lastUsedAt: 150, turnCount: 1, now: 180))
    #expect(!policy.permitsReuse(createdAt: 100, lastUsedAt: 101, turnCount: 16, now: 102))
    #expect(!policy.permitsReuse(createdAt: 100, lastUsedAt: 101, turnCount: -1, now: 102))
  }

  @Test func invalidOrBackwardClocksNeverReuseAuthority() {
    for value in [Double.nan, .infinity, -.infinity, -1] {
      #expect(!policy.permitsReuse(createdAt: value, lastUsedAt: 100, turnCount: 0, now: 100))
      #expect(!policy.permitsReuse(createdAt: 0, lastUsedAt: value, turnCount: 0, now: 100))
      #expect(!policy.permitsReuse(createdAt: 0, lastUsedAt: 0, turnCount: 0, now: value))
    }
    #expect(!policy.permitsReuse(createdAt: 100, lastUsedAt: 99, turnCount: 0, now: 101))
    #expect(!policy.permitsReuse(createdAt: 100, lastUsedAt: 102, turnCount: 0, now: 101))
  }

  @Test func metadataExpiresIndependentlyAtThirtySeconds() {
    #expect(policy.permitsMetadata(cachedAt: 100, now: 129.999))
    #expect(!policy.permitsMetadata(cachedAt: 100, now: 130))
    #expect(!policy.permitsMetadata(cachedAt: nil, now: 100))
    #expect(!policy.permitsMetadata(cachedAt: 101, now: 100))
    #expect(!policy.permitsMetadata(cachedAt: -.infinity, now: 100))
    #expect(!policy.permitsMetadata(cachedAt: 100, now: .nan))
  }

  @Test func executableIdentityDetectsReplacementWithoutReadingContents() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let path = directory.appendingPathComponent("public-fixture")
    try Data("#!/bin/sh\nexit 0\n".utf8).write(to: path)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path.path)
    let original = try CodexGuidanceExecutableIdentity.read(path.path)
    #expect(try CodexGuidanceExecutableIdentity.read(path.path) == original)
    try Data("#!/bin/sh\n# replacement\nexit 0\n".utf8).write(to: path)
    #expect(try CodexGuidanceExecutableIdentity.read(path.path) != original)
    #expect(throws: (any Error).self) { try CodexGuidanceExecutableIdentity.read("relative") }
  }
}
