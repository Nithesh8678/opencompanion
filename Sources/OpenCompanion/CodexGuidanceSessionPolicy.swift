import Foundation

/// Host-authored resource limits for an explicitly owned live guidance session.
/// They bound process/metadata reuse, never screen or conversation authority.
struct CodexGuidanceSessionPolicy: Sendable {
  let metadataLifetime: TimeInterval = 30
  let idleLifetime: TimeInterval = 30
  let maximumLifetime: TimeInterval = 180
  let maximumTurns = 16

  func permitsReuse(
    createdAt: TimeInterval, lastUsedAt: TimeInterval, turnCount: Int,
    now: TimeInterval
  ) -> Bool {
    createdAt.isFinite && lastUsedAt.isFinite && now.isFinite && createdAt >= 0
      && lastUsedAt >= createdAt && now >= lastUsedAt && now - createdAt < maximumLifetime
      && now - lastUsedAt < idleLifetime && turnCount >= 0 && turnCount < maximumTurns
  }

  func permitsMetadata(cachedAt: TimeInterval?, now: TimeInterval) -> Bool {
    guard let cachedAt, cachedAt.isFinite, now.isFinite, cachedAt >= 0, now >= cachedAt else {
      return false
    }
    return now - cachedAt < metadataLifetime
  }
}

/// Stat-only executable identity. No binary, credential, prompt or screenshot
/// contents are read or retained to decide whether a connection can be reused.
struct CodexGuidanceExecutableIdentity: Equatable, Sendable {
  let path: String
  let device: UInt64
  let inode: UInt64
  let byteCount: UInt64
  let modificationTime: TimeInterval

  static func read(_ path: String) throws -> Self {
    guard path.hasPrefix("/"), path.utf8.count <= 8_192,
      FileManager.default.isExecutableFile(atPath: path)
    else { throw ProviderError.message("Choose an absolute installed Codex executable path.") }
    let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    let attributes = try FileManager.default.attributesOfItem(atPath: resolved)
    guard attributes[.type] as? FileAttributeType == .typeRegular,
      let device = attributes[.systemNumber] as? NSNumber,
      let inode = attributes[.systemFileNumber] as? NSNumber,
      let size = attributes[.size] as? NSNumber,
      let modified = attributes[.modificationDate] as? Date,
      modified.timeIntervalSince1970.isFinite
    else { throw ProviderError.message("The selected Codex executable identity is unavailable.") }
    return .init(
      path: resolved, device: device.uint64Value, inode: inode.uint64Value,
      byteCount: size.uint64Value, modificationTime: modified.timeIntervalSince1970)
  }
}
