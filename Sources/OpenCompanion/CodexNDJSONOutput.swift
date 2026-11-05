import CompanionCore
import CryptoKit
import Foundation

/// Explicit public-fixture diagnostics only. Ordinals and digests identify no
/// remote items; no prompt, response text, node names or remote IDs are retained.
struct CodexNDJSONAudit: Codable, Sendable, Equatable {
  enum Outcome: String, Codable, Sendable { case completed, failed, cancelled }
  struct Item: Codable, Sendable, Equatable {
    let ordinal: Int
    let phase: String
    let started: Bool
    let deltaEvents: Int
    let deltaUTF8Bytes: Int
    let completedUTF8Bytes: Int?
    let appendedSuffixUTF8Bytes: Int
    let streamedSHA256: String
    let completedSHA256: String?
  }
  let outcome: Outcome
  let items: [Item]
  let acceptedUnits: Int
  let deltaUTF8Bytes: Int
  let completedUTF8Bytes: Int
  let completedOnlyItems: Int
  let duplicateCompletions: Int
  let ignoredScopeEvents: Int
}

/// A turn owns sequential agent-message items. Only an authoritative completed
/// item can close its last NDJSON line. A completed text may extend the exact
/// streamed UTF8 prefix; it never replaces, repairs or replays streamed units.
struct CodexNDJSONOutput: Sendable {
  private enum Phase: String, Sendable {
    case unknown, commentary
    case partialAnswer = "partial_answer"
    case finalAnswer = "final_answer"
  }
  private struct Item: Sendable {
    let ordinal: Int
    let started: Bool
    var phase: Phase
    var bytes = Data()
    var deltaEvents = 0
    var deltaBytes = 0
    var completionBytes: Int?
    var completionDigest: String?
    var completionPhase: Phase?
    var streamedDigest: String?
    var suffixBytes = 0
  }

  private let threadID: String
  private var turnID: String?
  private var items: [String: Item] = [:]
  private var activeID: String?
  private var decoder = ProviderTextStreamDecoder()
  private var deltaBytes = 0
  private var completedBytes = 0
  private var duplicateCompletions = 0
  private var ignoredScopeEvents = 0
  private var terminal = false
  var acceptedUnits: Int { decoder.acceptedUnits }

  init(threadID: String) { self.threadID = threadID }

  mutating func bind(turnID: String) throws {
    guard !turnID.isEmpty, turnID.utf8.count <= 256,
      self.turnID == nil || self.turnID == turnID
    else { throw failure("The NDJSON turn identity changed.") }
    self.turnID = turnID
  }

  func matchesTurn(_ params: JSONValue?) -> Bool {
    guard let turnID else { return false }
    let direct = params?["turnId"]?.string
    let nested = params?["turn"]?["id"]?.string
    guard direct == nil || nested == nil || direct == nested else { return false }
    return params?["threadId"]?.string == threadID
      && (direct ?? nested) == turnID
  }

  mutating func receive(
    method: String, params: JSONValue?,
    onUnit: @Sendable (ProviderUnit) async throws -> Void,
    onText: (@Sendable (ProviderTextPreview) async throws -> Void)? = nil,
    onRejectedLine: (@Sendable (Data) async -> Void)? = nil,
    onSceneLineDecoded: (@Sendable (ProviderLineWireSample) async -> Void)? = nil
  ) async throws {
    do {
      try Task.checkCancellation()
      guard !terminal else { throw failure("The NDJSON stream has already ended.") }
      if method == "turn/started", params?["threadId"]?.string == threadID,
        let id = params?["turn"]?["id"]?.string
      {
        // The RPC response remains authoritative too: a later conflicting bind
        // fails. This handles an owned turn/started notification arriving first.
        if turnID == nil { try bind(turnID: id) }
        return
      }
      guard ["item/started", "item/agentMessage/delta", "item/completed"].contains(method) else {
        return
      }
      guard matchesTurn(params) else {
        ignoredScopeEvents = min(ignoredScopeEvents + 1, 1_000_000)
        return
      }
      switch method {
      case "item/started":
        guard let value = params?["item"] else { throw failure("An NDJSON item has no value.") }
        try rejectTypeChange(value)
        guard value["type"]?.string == "agentMessage" else { return }
        let id = try itemID(value["id"]?.string)
        guard items[id] == nil, items.count < 16, activeID == nil else {
          throw failure("NDJSON messages overlap, restart or exceed the item limit.")
        }
        items[id] = Item(ordinal: items.count, started: true, phase: try phase(value["phase"]))
        activeID = id
      case "item/agentMessage/delta":
        let id = try itemID(params?["itemId"]?.string)
        guard activeID == id, items[id]?.completionDigest == nil, items[id] != nil,
          let delta = params?["delta"]?.string
        else { throw failure("An NDJSON delta has no active owned message.") }
        let count = delta.utf8.count
        guard count <= 2_000_000 - deltaBytes else {
          throw failure("NDJSON deltas exceeded the bounded response budget.")
        }
        // Give the mutable buffer sole ownership before appending; retaining it
        // in the dictionary would copy the accumulated bytes on every delta.
        guard var item = items.removeValue(forKey: id) else {
          throw failure("An NDJSON delta has no active owned message.")
        }
        deltaBytes += count
        item.deltaEvents = min(item.deltaEvents + 1, 1_000_000)
        item.deltaBytes += count
        item.bytes.append(contentsOf: delta.utf8)
        items[id] = item
        try await decoder.append(
          delta, onUnit: onUnit, onText: onText, onRejectedLine: onRejectedLine,
          onSceneLineDecoded: onSceneLineDecoded)
        try Task.checkCancellation()
      case "item/completed":
        guard let value = params?["item"] else { throw failure("An NDJSON item has no value.") }
        try rejectTypeChange(value)
        guard value["type"]?.string == "agentMessage" else { return }
        let id = try itemID(value["id"]?.string)
        let completedPhase = try phase(value["phase"])
        guard let text = value["text"]?.string else {
          throw failure("The completed NDJSON message has no text.")
        }
        let count = text.utf8.count
        guard count <= 2_000_000 - completedBytes else {
          throw failure("Completed NDJSON text exceeded the bounded response budget.")
        }
        completedBytes += count
        let digest = Self.digest(text.utf8)
        if let previous = items[id], let previousDigest = previous.completionDigest {
          guard previousDigest == digest, previous.completionBytes == count,
            previous.completionPhase == completedPhase
          else { throw failure("A completed NDJSON message changed after admission.") }
          duplicateCompletions += 1
          return
        }
        guard activeID == nil || activeID == id, items[id] != nil || items.count < 16 else {
          throw failure("Completed NDJSON messages overlap or exceed the item limit.")
        }
        var item =
          items[id]
          ?? Item(
            ordinal: items.count, started: false, phase: completedPhase)
        guard item.phase == .unknown || completedPhase == .unknown || item.phase == completedPhase
        else { throw failure("An NDJSON message changed its declared phase.") }
        // Compare raw bytes, not Swift's canonically-equivalent String equality.
        guard count >= item.bytes.count,
          text.utf8.prefix(item.bytes.count).elementsEqual(item.bytes)
        else { throw failure("The authoritative NDJSON text differs from its streamed prefix.") }
        if item.phase == .unknown { item.phase = completedPhase }
        let suffix = String(decoding: text.utf8.dropFirst(item.bytes.count), as: UTF8.self)
        item.suffixBytes = count - item.bytes.count
        item.streamedDigest = Self.digest(item.bytes)
        item.completionDigest = digest
        item.completionBytes = count
        item.completionPhase = completedPhase
        item.bytes.removeAll(keepingCapacity: false)
        items[id] = item
        activeID = id
        if !suffix.isEmpty {
          try await decoder.append(
            suffix, onUnit: onUnit, onText: onText, onRejectedLine: onRejectedLine,
            onSceneLineDecoded: onSceneLineDecoded)
          try Task.checkCancellation()
        }
        try await decoder.finish(
          onUnit: onUnit, onText: onText, onRejectedLine: onRejectedLine,
          onSceneLineDecoded: onSceneLineDecoded)
        try Task.checkCancellation()
        activeID = nil
      default: break
      }
    } catch {
      terminal = true
      throw error
    }
  }

  mutating func finishTurn() throws {
    do {
      try Task.checkCancellation()
      guard !terminal, activeID == nil, !items.isEmpty,
        items.values.allSatisfy({ $0.completionDigest != nil }), acceptedUnits > 0
      else {
        throw failure("NDJSON ended without authoritative completion of every response item.")
      }
      terminal = true
    } catch {
      terminal = true
      throw error
    }
  }

  func audit(outcome: CodexNDJSONAudit.Outcome) -> CodexNDJSONAudit {
    .init(
      outcome: outcome,
      items: items.values.sorted { $0.ordinal < $1.ordinal }.map {
        .init(
          ordinal: $0.ordinal, phase: $0.phase.rawValue, started: $0.started,
          deltaEvents: $0.deltaEvents, deltaUTF8Bytes: $0.deltaBytes,
          completedUTF8Bytes: $0.completionBytes, appendedSuffixUTF8Bytes: $0.suffixBytes,
          streamedSHA256: $0.streamedDigest ?? Self.digest($0.bytes),
          completedSHA256: $0.completionDigest)
      },
      acceptedUnits: acceptedUnits, deltaUTF8Bytes: deltaBytes, completedUTF8Bytes: completedBytes,
      completedOnlyItems: items.values.filter { $0.deltaEvents == 0 && $0.completionDigest != nil }
        .count,
      duplicateCompletions: duplicateCompletions, ignoredScopeEvents: ignoredScopeEvents)
  }

  private func rejectTypeChange(_ value: JSONValue) throws {
    if let id = value["id"]?.string, items[id] != nil,
      value["type"]?.string != "agentMessage"
    {
      throw failure("An NDJSON item changed its type.")
    }
  }
  private func itemID(_ value: String?) throws -> String {
    guard let value, !value.isEmpty, value.utf8.count <= 256 else {
      throw failure("An NDJSON message has an invalid item identity.")
    }
    return value
  }
  private func phase(_ value: JSONValue?) throws -> Phase {
    switch value {
    case nil, .null: return .unknown
    case .string(let value):
      guard value != "unknown", let phase = Phase(rawValue: value) else {
        throw failure("An NDJSON message has an unsupported phase.")
      }
      return phase
    default: throw failure("An NDJSON message has an invalid phase.")
    }
  }
  private static func digest<S: Sequence>(_ bytes: S) -> String where S.Element == UInt8 {
    // At most 2 MB, with a fixed 4 KiB hashing buffer rather than retaining a
    // second authoritative message alongside the existing RPC event string.
    var hash = SHA256()
    var chunk = Data()
    chunk.reserveCapacity(4_096)
    for byte in bytes {
      chunk.append(byte)
      if chunk.count == 4_096 {
        hash.update(data: chunk)
        chunk.removeAll(keepingCapacity: true)
      }
    }
    if !chunk.isEmpty { hash.update(data: chunk) }
    return hash.finalize().map { String(format: "%02x", $0) }.joined()
  }
  private func failure(_ message: String) -> ProviderError { .message(message) }
}

extension JSONValue {
  fileprivate subscript(_ key: String) -> JSONValue? {
    if case .object(let value) = self { value[key] } else { nil }
  }
  fileprivate var string: String? { if case .string(let value) = self { value } else { nil } }
}
