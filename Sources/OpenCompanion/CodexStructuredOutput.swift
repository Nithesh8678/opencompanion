import CompanionCore
import Foundation

/// The schema path is an opt-in experiment for new explanations. It does not
/// alter ordinary conversation, screen guidance, retained edits or model choice.
enum CodexOutputMode: String, Sendable {
  case ndjson, structuredScene, structuredUnifiedScene

  var isStructured: Bool { self != .ndjson }
  var schema: JSONValue? {
    switch self {
    case .ndjson: nil
    case .structuredScene: StructuredSceneOutputSchema.value
    case .structuredUnifiedScene: StructuredSceneOutputSchema.unifiedValue
    }
  }

  func validate(policy: ResponsePolicy, hasImage: Bool, hasScene: Bool) throws {
    guard isStructured else { return }
    guard policy.route == .notebook, policy.allowsNotebook,
      !policy.includesExistingNotebook, !hasImage, !hasScene
    else {
      throw ProviderError.message(
        "Structured scene output currently supports only a new standalone explanation.")
    }
  }
}

/// Keeps schema-constrained final text separate from interim commentary. A
/// matching completed item is authoritative; deltas never imply completion.
/// Unknown-phase legacy output is buffered and admitted only after turn success.
struct CodexStructuredOutput: Sendable {
  private enum Phase: Sendable, Equatable { case unknown, commentary, final }
  private struct Item: Sendable {
    var phase: Phase
    var deltas = ""
    var sawDelta = false
    var completedText: String?
    var completionPhase: Phase?
  }

  private let threadID: String
  private var turnID: String?
  private var items: [String: Item] = [:]
  private var finalID: String?
  private var decoder = StructuredSceneStreamDecoder()
  private var totalDeltaBytes = 0
  private var totalCompletedBytes = 0
  private var terminal = false
  private(set) var finalMessageStarted = false
  private(set) var finalMessageCompleted = false
  private(set) var usedPhaseCompatibilityFallback = false
  var acceptedUnits: Int { decoder.acceptedUnits }

  init(threadID: String) { self.threadID = threadID }

  mutating func bind(turnID: String) throws {
    guard !turnID.isEmpty, turnID.utf8.count <= 256,
      self.turnID == nil || self.turnID == turnID
    else { throw failure("The structured turn identity changed.") }
    self.turnID = turnID
  }

  func matchesTurn(_ params: JSONValue?) -> Bool {
    guard let turnID else { return false }
    return params?["threadId"]?.string == threadID
      && (params?["turnId"]?.string ?? params?["turn"]?["id"]?.string) == turnID
  }

  mutating func receive(
    method: String, params: JSONValue?,
    onUnit: @Sendable (ProviderUnit) async throws -> Void,
    onText: (@Sendable (ProviderTextPreview) async throws -> Void)? = nil
  ) async throws {
    do {
      try Task.checkCancellation()
      guard !terminal else { throw failure("The structured stream has already ended.") }
      if method == "turn/started", params?["threadId"]?.string == threadID,
        let id = params?["turn"]?["id"]?.string
      {
        if turnID == nil { try bind(turnID: id) }
        return
      }
      guard matchesTurn(params) else { return }
      switch method {
      case "item/started":
        if let id = params?["item"]?["id"]?.string, items[id] != nil,
          params?["item"]?["type"]?.string != "agentMessage"
        {
          throw failure("A structured item changed its type.")
        }
        guard let value = params?["item"], value["type"]?.string == "agentMessage" else {
          return
        }
        let id = try itemID(value["id"]?.string)
        guard items[id] == nil, items.count < 16 else {
          throw failure("A structured message was restarted or exceeded the item limit.")
        }
        let phase = try phase(value["phase"])
        items[id] = Item(phase: phase)
        if phase == .final { try selectFinal(id) }
      case "item/agentMessage/delta":
        let id = try itemID(params?["itemId"]?.string)
        guard var item = items.removeValue(forKey: id), item.completedText == nil,
          let delta = params?["delta"]?.string
        else { throw failure("A structured delta has no active message item.") }
        let count = delta.utf8.count
        guard count <= 2_000_000 - totalDeltaBytes else {
          throw failure("Structured output exceeded the bounded response budget.")
        }
        totalDeltaBytes += count
        item.sawDelta = true
        if item.phase != .commentary { item.deltas += delta }
        items[id] = item
        if item.phase == .final {
          try await decoder.append(delta, onUnit: onUnit, onText: onText)
        }
      case "item/completed":
        if let id = params?["item"]?["id"]?.string, items[id] != nil,
          params?["item"]?["type"]?.string != "agentMessage"
        {
          throw failure("A structured item changed its type.")
        }
        guard let value = params?["item"], value["type"]?.string == "agentMessage" else {
          return
        }
        let id = try itemID(value["id"]?.string)
        let completedPhase = try phase(value["phase"])
        guard let text = value["text"]?.string else {
          throw failure("The completed structured message has no text.")
        }
        if let previous = items[id]?.completedText {
          guard previous == text,
            items[id]?.completionPhase == completedPhase
          else {
            throw failure("A completed structured message changed after admission.")
          }
          // Duplicate authoritative delivery is idempotent, never a replay.
          return
        }
        guard text.utf8.count <= 2_000_000 - totalCompletedBytes,
          items[id] != nil || items.count < 16
        else { throw failure("Completed structured output exceeded its bounded budget.") }
        totalCompletedBytes += text.utf8.count
        let streamedAsFinal = items[id]?.phase == .final
        var item = items[id] ?? Item(phase: completedPhase)
        if item.phase != .unknown, completedPhase != .unknown,
          item.phase != completedPhase
        {
          throw failure("A structured message changed its declared phase.")
        }
        if item.phase == .unknown { item.phase = completedPhase }
        if item.phase != .commentary, item.sawDelta, item.deltas != text {
          throw failure("The authoritative structured message differs from its streamed text.")
        }
        item.completedText = text
        item.completionPhase = completedPhase
        items[id] = item
        if item.phase == .final {
          try selectFinal(id)
          // Started final messages were already streamed. Unknown-phase and
          // completed-only messages have not yet admitted any of this text.
          if !item.sawDelta || !streamedAsFinal {
            try await decoder.append(text, onUnit: onUnit, onText: onText)
          }
          try await decoder.finish(onUnit: onUnit, onText: onText)
          finalMessageCompleted = true
        }
      default: break
      }
    } catch {
      terminal = true
      throw error
    }
  }

  mutating func finishTurn(
    onUnit: @Sendable (ProviderUnit) async throws -> Void,
    onText: (@Sendable (ProviderTextPreview) async throws -> Void)? = nil
  ) async throws {
    do {
      try Task.checkCancellation()
      guard !terminal else { throw failure("The structured stream has already ended.") }
      if finalID == nil {
        let unknown = items.filter { $0.value.phase == .unknown }
        guard unknown.count == 1, let entry = unknown.first,
          let text = entry.value.completedText
        else { throw failure("No unambiguous completed structured answer was received.") }
        usedPhaseCompatibilityFallback = true
        try selectFinal(entry.key)
        try await decoder.append(text, onUnit: onUnit, onText: onText)
        try await decoder.finish(onUnit: onUnit, onText: onText)
        finalMessageCompleted = true
      }
      guard finalMessageCompleted, acceptedUnits > 0 else {
        throw failure("The structured answer ended without a complete accepted response.")
      }
      terminal = true
    } catch {
      terminal = true
      throw error
    }
  }

  private mutating func selectFinal(_ id: String) throws {
    guard finalID == nil || finalID == id else {
      throw failure("More than one final structured answer was received.")
    }
    finalID = id
    finalMessageStarted = true
  }

  private func itemID(_ value: String?) throws -> String {
    guard let value, !value.isEmpty, value.utf8.count <= 256 else {
      throw failure("The structured message has an invalid item identity.")
    }
    return value
  }

  private func phase(_ value: JSONValue?) throws -> Phase {
    switch value {
    case nil, .null: return .unknown
    case .string("commentary"): return .commentary
    case .string("final_answer"): return .final
    default: throw failure("The structured message has an unsupported phase.")
    }
  }

  private func failure(_ message: String) -> ProviderError { .message(message) }
}

extension JSONValue {
  fileprivate subscript(_ key: String) -> JSONValue? {
    if case .object(let value) = self { value[key] } else { nil }
  }
  fileprivate var string: String? { if case .string(let value) = self { value } else { nil } }
}
