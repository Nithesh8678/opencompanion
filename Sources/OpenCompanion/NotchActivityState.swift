import Foundation

enum NotchActivityPhase: String, Sendable, Equatable {
  case idle, preparing, listening, thinking, speaking
}

/// Owns only an explicitly begun hotkey voice turn. Model activity by itself
/// cannot open the compact HUD. A recognized utterance must explicitly hand
/// ownership to its provider generation: a typed send has the same observable
/// busy/Thinking state and cannot be distinguished by generation arithmetic.
struct NotchActivityState: Sendable, Equatable {
  private enum Stage: Sendable { case input, response }

  private(set) var phase = NotchActivityPhase.idle
  private(set) var generation: UInt64?
  private var stage: Stage?
  private var latestGeneration: UInt64?
  private var terminalThrough: UInt64?

  /// Call only for a fresh physical hotkey press. Repeated or already terminal
  /// generations cannot restart activity; a newer press replaces the old turn.
  @discardableResult mutating func begin(generation: UInt64) -> Bool {
    guard self.generation != generation,
      latestGeneration.map({ generation >= $0 }) ?? true,
      terminalThrough.map({ generation > $0 }) ?? true
    else { return false }
    observe(generation)
    self.generation = generation
    stage = .input
    phase = .preparing
    return true
  }

  /// Call synchronously for a successfully submitted push-to-talk utterance,
  /// before delivering model snapshots from the response's new generation.
  /// No particular increment is assumed, and response ownership transfers once.
  @discardableResult mutating func handoff(from source: UInt64, to destination: UInt64) -> Bool {
    guard generation == source, stage == .input, destination > source,
      latestGeneration.map({ destination >= $0 }) ?? true
    else { return false }
    observe(destination)
    generation = destination
    stage = .response
    phase = .thinking
    return true
  }

  /// Snapshots must be captured together on the model's actor. `hasPendingSpeech`
  /// means queued OR active output from VoiceService, not a guessed delay. It
  /// keeps a response in Thinking before the real synth didStart callback and
  /// avoids treating a provider's temporary Ready label as audio completion.
  @discardableResult mutating func update(
    generation: UInt64, inputPhase: String, pushToTalkActive: Bool, busy: Bool, state: String,
    hasPendingSpeech: Bool = false, failed: Bool = false
  ) -> NotchActivityPhase {
    observe(generation)
    guard let owner = self.generation else { return .idle }
    guard generation == owner else {
      // An unrelated newer operation supersedes the voice scope. Older queued
      // callbacks are harmless and must not hide a newer hotkey turn.
      if generation > owner { finish(through: generation) }
      return phase
    }
    guard !failed else {
      finish(through: owner)
      return phase
    }
    switch stage {
    case .input:
      switch inputPhase {
      case "Preparing microphone": phase = .preparing
      case "Listening": phase = .listening
      case "Finishing speech", "Release Control+Option to send":
        // Captured speech is being finalized, or is waiting for key release;
        // neither state claims that the microphone is still listening.
        phase = .thinking
      default:
        // A Ready/failed/cancelled input cannot infer provider ownership. Only
        // handoff(from:to:) authorizes that transition.
        if pushToTalkActive && inputPhase == "Ready" {
          phase = .preparing
        } else {
          finish(through: owner)
        }
      }
    case .response:
      if state == "Speaking" && hasPendingSpeech {
        phase = .speaking
      } else if busy || hasPendingSpeech {
        phase = .thinking
      } else {
        finish(through: owner)
      }
    case nil:
      finish(through: owner)
    }
    return phase
  }

  /// Pass the current model generation after Stop/lifecycle cancellation. The
  /// model already advances it; this reducer does not perform overflow-prone
  /// arithmetic or let a stale cancellation hide a newer voice turn.
  mutating func cancel(generation: UInt64) {
    guard latestGeneration.map({ generation >= $0 }) ?? true else { return }
    observe(generation)
    finish(through: generation)
  }

  private mutating func observe(_ generation: UInt64) {
    if latestGeneration.map({ generation > $0 }) ?? true { latestGeneration = generation }
  }

  private mutating func finish(through generation: UInt64) {
    if terminalThrough.map({ generation > $0 }) ?? true { terminalThrough = generation }
    self.generation = nil
    stage = nil
    phase = .idle
  }
}
