import CompanionCore
import Foundation

/// A retained presentation snapshot, never a write back to the canonical document.
struct ExplanationPresentation: Equatable, Sendable {
  let beatID: UUID
  let generation: UInt64
  let document: SceneDocument
}

enum ExplanationPlaybackError: Error, Equatable, LocalizedError {
  case inactive, invalidDocument, narrationTooLarge, beatCapacity, nodeCapacity, narrationCapacity

  var errorDescription: String? {
    switch self {
    case .inactive: "This explanation no longer owns a playback generation."
    case .invalidDocument: "The explanation snapshot has an invalid document identity or revision."
    case .narrationTooLarge: "One explanation paragraph exceeds the 32,000-byte limit."
    case .beatCapacity: "The explanation playback queue reached its 64-beat limit."
    case .nodeCapacity: "The explanation playback snapshots reached their node-reference limit."
    case .narrationCapacity: "The explanation playback narration reached its 128 KiB limit."
    }
  }
}

/// Sequential presentation and narration admission. No timer estimates speech progress.
/// The host admits canonical transactions first, then enqueues immutable snapshots.
@MainActor final class ExplanationPlayback {
  static let maximumPendingBeats = 64
  static let maximumNodeReferences = 8_192
  static let maximumNarrationBytes = 128 * 1_024
  static let maximumParagraphBytes = 32_000

  var onPresent: ((ExplanationPresentation) -> Void)?
  var onNarration: ((VoiceNarrationContext, String) -> Void)?
  var onActivityChanged: ((Bool) -> Void)?

  private struct Owner {
    let generation: UInt64
    let id: UUID
  }
  private struct Beat {
    let id: UUID
    let document: SceneDocument?
    let narration: String?
    let context: VoiceNarrationContext?
  }
  private enum Phase { case queued, awaitingRender, readyForNarration, awaitingNarration }

  private var owner: Owner?
  private var watermark: UInt64?
  private var beats: [Beat] = []
  private var phase = Phase.queued
  private var draining = false
  private var reportedActivity = false
  private(set) var currentPresentation: ExplanationPresentation?

  var isActive: Bool { !beats.isEmpty }
  var pendingCount: Int { beats.count }

  init(
    onPresent: ((ExplanationPresentation) -> Void)? = nil,
    onNarration: ((VoiceNarrationContext, String) -> Void)? = nil,
    onActivityChanged: ((Bool) -> Void)? = nil
  ) {
    self.onPresent = onPresent
    self.onNarration = onNarration
    self.onActivityChanged = onActivityChanged
  }

  /// An equal/older generation cannot restart an invalidated owner.
  func begin(generation: UInt64) {
    guard watermark.map({ generation > $0 }) ?? true else { return }
    watermark = generation
    // Revoke all old IDs before invoking any callback, including a reentrant one.
    owner = Owner(generation: generation, id: UUID())
    beats.removeAll(keepingCapacity: true)
    phase = .queued
    currentPresentation = nil
    notifyActivity()
  }

  func invalidate() {
    owner = nil
    beats.removeAll(keepingCapacity: true)
    phase = .queued
    currentPresentation = nil
    notifyActivity()
  }

  /// Side-effect-free preflight. The caller must recheck ownership after any await.
  /// `enqueue` repeats this check; there is no reservation across suspension.
  func checkCapacity(document: SceneDocument?, narration: String?) throws {
    guard owner != nil else { throw ExplanationPlaybackError.inactive }
    let text = try checkedNarration(narration)
    if let document {
      guard !document.id.isEmpty, document.id.utf8.count <= 256, document.revision >= 0 else {
        throw ExplanationPlaybackError.invalidDocument
      }
    }
    guard document != nil || text != nil else { return }
    guard beats.count < Self.maximumPendingBeats else {
      throw ExplanationPlaybackError.beatCapacity
    }
    let addedNodes = document?.nodes.count ?? 0
    guard addedNodes <= Self.maximumNodeReferences - nodeReferences else {
      throw ExplanationPlaybackError.nodeCapacity
    }
    let addedText = text?.utf8.count ?? 0
    guard addedText <= Self.maximumNarrationBytes - narrationBytes else {
      throw ExplanationPlaybackError.narrationCapacity
    }
  }

  func enqueue(document: SceneDocument?, narration: String?) throws {
    try checkCapacity(document: document, narration: narration)
    guard let owner else { throw ExplanationPlaybackError.inactive }
    let text = try checkedNarration(narration)
    guard document != nil || text != nil else { return }
    let id = UUID()
    beats.append(
      Beat(
        id: id, document: document, narration: text,
        context: text.map { _ in
          VoiceNarrationContext(generation: owner.generation, narrationID: id)
        }))
    notifyActivity()
    drain()
  }

  /// Acknowledges this exact submitted native snapshot, not physical display scanout.
  @discardableResult func acknowledgeRenderSubmitted(
    beatID: UUID, generation: UInt64, documentID: String, revision: Int
  ) -> Bool {
    guard let owner, owner.generation == generation, phase == .awaitingRender,
      let beat = beats.first, beat.id == beatID, let document = beat.document,
      document.id == documentID, document.revision == revision,
      currentPresentation?.beatID == beatID
    else { return false }
    phase = .readyForNarration
    drain()
    return true
  }

  /// The host calls this after a real terminal speech event or explicit text fallback.
  @discardableResult func completeNarration(context: VoiceNarrationContext) -> Bool {
    guard let owner, owner.generation == context.generation, phase == .awaitingNarration,
      let beat = beats.first, beat.context == context
    else { return false }
    removeHead()
    drain()
    return true
  }

  private func checkedNarration(_ text: String?) throws -> String? {
    guard let text else { return nil }
    guard text.utf8.count <= Self.maximumParagraphBytes else {
      throw ExplanationPlaybackError.narrationTooLarge
    }
    // Keep the original paragraph; checking blankness must not rewrite visible words.
    return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
  }

  private var narrationBytes: Int {
    var total = 0
    for beat in beats { total += beat.narration?.utf8.count ?? 0 }
    return total
  }

  private var nodeReferences: Int {
    var total = 0
    var presentationIsQueued = false
    for beat in beats {
      total += beat.document?.nodes.count ?? 0
      if beat.id == currentPresentation?.beatID { presentationIsQueued = true }
    }
    // The last completed scene remains retained even through text-only beats.
    if !presentationIsQueued { total += currentPresentation?.document.nodes.count ?? 0 }
    return total
  }

  private func removeHead() {
    beats.removeFirst()
    phase = .queued
    notifyActivity()
  }

  private func notifyActivity() {
    let active = isActive
    guard active != reportedActivity else { return }
    reportedActivity = active
    onActivityChanged?(active)
  }

  /// Callbacks can acknowledge, finish, enqueue, invalidate or begin another turn.
  /// State is advanced before callback entry, and every continuation rechecks its owner.
  private func drain() {
    guard !draining else { return }
    draining = true
    defer { draining = false }
    while let owner, let beat = beats.first {
      switch phase {
      case .queued:
        if let document = beat.document {
          let presentation = ExplanationPresentation(
            beatID: beat.id, generation: owner.generation, document: document)
          currentPresentation = presentation
          phase = Self.hasRenderableContent(document) ? .awaitingRender : .readyForNarration
          onPresent?(presentation)
          guard self.owner?.id == owner.id, beats.first?.id == beat.id else { continue }
        } else {
          phase = .readyForNarration
        }
      case .awaitingRender, .awaitingNarration:
        return
      case .readyForNarration:
        if let text = beat.narration, let context = beat.context {
          phase = .awaitingNarration
          onNarration?(context, text)
          guard self.owner?.id == owner.id, beats.first?.id == beat.id else { continue }
        } else {
          removeHead()
        }
      }
    }
  }

  /// Matches ExplanationOverlay's first-group/anchored-label mounting policy.
  private static func hasRenderableContent(_ document: SceneDocument) -> Bool {
    document.nodes.contains { node in
      switch node.kind {
      case .group: false
      case .mesh: node.spatial3D?.geometry != nil || node.spatial3D == nil
      case .text: node.spatial3D?.labelAnchor == nil && !node.text.isEmpty
      case .path, .line, .arrow:
        node.points.count >= 2 || node.subpaths.contains { $0.count >= 2 }
      case .rectangle, .ellipse: node.width > 0 && node.height > 0
      }
    }
  }
}
