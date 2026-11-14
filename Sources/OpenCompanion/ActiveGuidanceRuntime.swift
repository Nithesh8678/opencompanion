import Foundation

/// Ephemeral capture/reasoning authority, deliberately separate from saved
/// semantic workflow and individual inference generations. Never Codable.
struct ActiveGuidanceRuntime: Sendable, Equatable {
  enum Phase: String, Sendable { case inactive, listening, checking, awaitingUser, settling }
  private(set) var id: UUID?
  private(set) var goal = ""
  private(set) var speakAloud = false
  private(set) var selectedScope: ScreenGuidanceCaptureScope?
  private(set) var phase: Phase = .inactive
  private(set) var sceneEpoch: UInt64 = 0
  private(set) var checkedEpoch: UInt64 = 0
  private(set) var hardEpoch: UInt64 = 0
  private(set) var checkedHardEpoch: UInt64 = 0
  private(set) var firstDirtyAt: TimeInterval?
  private(set) var lastDirtyAt: TimeInterval?
  private(set) var lastEventSequence: UInt64 = 0
  var isActive: Bool { id != nil }
  var isDirty: Bool { sceneEpoch != checkedEpoch }
  var hasHardChange: Bool { hardEpoch != checkedHardEpoch }

  mutating func start(
    id: UUID = UUID(), goal: String, speakAloud: Bool, selectedScope: ScreenGuidanceCaptureScope?
  ) {
    self = Self()
    self.id = id
    self.goal = String(goal.prefix(8_000))
    self.speakAloud = speakAloud
    self.selectedScope = selectedScope
    phase = .checking
  }

  mutating func listen() { if isActive { phase = .listening } }
  mutating func check() {
    guard isActive else { return }
    checkedEpoch = sceneEpoch
    checkedHardEpoch = hardEpoch
    firstDirtyAt = nil
    lastDirtyAt = nil
    phase = .checking
  }
  mutating func wait() { if isActive { phase = isDirty ? .settling : .awaitingUser } }
  mutating func stop() { self = Self() }

  /// A callback from another source/session cannot dirty this runtime. The
  /// caller also authenticates the exact observation scope's lease.
  @discardableResult mutating func change(
    sessionID: UUID, sequence: UInt64, at now: TimeInterval, visualOnly: Bool = false
  ) -> Bool {
    guard id == sessionID, sequence > lastEventSequence, now.isFinite, now >= 0 else {
      return false
    }
    lastEventSequence = sequence
    sceneEpoch &+= 1
    if !visualOnly { hardEpoch &+= 1 }
    firstDirtyAt = firstDirtyAt ?? now
    lastDirtyAt = now
    if phase != .listening { phase = .settling }
    return true
  }

  /// A native target proof covers only the supplied visual epoch. A hard
  /// event or later frame remains dirty; neither can be erased by a late proof.
  @discardableResult mutating func acknowledgeVisual(through epoch: UInt64, hardEpoch: UInt64)
    -> Bool
  {
    guard isActive, self.hardEpoch == hardEpoch, !hasHardChange,
      epoch >= checkedEpoch, epoch <= sceneEpoch
    else { return false }
    checkedEpoch = epoch
    if !isDirty {
      firstDirtyAt = nil
      lastDirtyAt = nil
      phase = .checking
    }
    return true
  }

  /// Bounded settlement, rather than a new queued model request per event.
  func settleDelay(now: TimeInterval, quiet: TimeInterval = 0.25) -> TimeInterval? {
    guard isActive, isDirty, phase != .listening, now.isFinite,
      let firstDirtyAt, let lastDirtyAt, now >= firstDirtyAt,
      quiet.isFinite, quiet >= 0
    else { return nil }
    return max(0, min(lastDirtyAt + min(0.6, quiet), firstDirtyAt + 1.2) - now)
  }
}

/// Bounded topic projection is reference material, never capture authority.
enum GuidanceFollowupContext {
  static func isShortContinuation(_ text: String) -> Bool {
    guard text.utf8.count <= 256 else { return false }
    let words = text.lowercased().split { !$0.isLetter }.joined(separator: " ")
    return [
      "what next", "what is next", "what s next", "where is it", "where is that",
      "show me where", "continue", "please continue", "next", "next step",
      "what should i do now", "what do i do next", "i can t find it", "i cannot find it",
    ].contains(words)
  }

  static func visualHistory(_ messages: [ChatLine], current: String) -> [ChatLine] {
    // Capability denials in assistant prose are not authoritative product
    // state. Keep a small user-owned topic projection on an output-mode change.
    let previous = messages.filter { $0.role == "user" }.suffix(4)
      .map { ChatLine(role: "user", text: String($0.text.prefix(2_000))) }
    return previous + [ChatLine(role: "user", text: current)]
  }
}
