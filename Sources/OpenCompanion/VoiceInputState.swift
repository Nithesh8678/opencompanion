import Foundation

enum VoiceInputMode: Sendable, Equatable {
  case manualReview, pushToTalk
  var submitsOnCompletion: Bool { self == .pushToTalk }
}

enum VoiceInputPhase: Sendable, Equatable {
  case idle, preparing, listening, finishing, awaitingRelease, completed, cancelled, failed
  var acceptsRecognition: Bool { self == .listening || self == .finishing }
  var isActive: Bool {
    self == .preparing || self == .listening || self == .finishing || self == .awaitingRelease
  }
  var label: String {
    switch self {
    case .idle, .completed, .cancelled: "Ready"
    case .preparing: "Preparing microphone"
    case .listening: "Listening"
    case .finishing: "Finishing speech"
    case .awaitingRelease: "Release Control+Option to send"
    case .failed: "Voice unavailable"
    }
  }
}

struct VoiceInputSnapshot: Sendable, Equatable {
  var sessionID: UUID?
  var mode: VoiceInputMode?
  var phase: VoiceInputPhase = .idle
  var transcript = ""
  var isHeld = false
  var isFinal = false
}

struct VoiceInputCompletion: Sendable, Equatable {
  let sessionID: UUID
  let mode: VoiceInputMode
  let transcript: String
  let isFinal: Bool
}

enum VoiceInputEffect: Sendable, Equatable {
  case none, finishAudio, cancelledBeforeReady
  case completed(VoiceInputCompletion)
}

/// Permission callbacks, recognizer callbacks, key release, and Stop are separate
/// events. Only the current session can advance; release never starts recording.
struct VoiceInputStateMachine: Sendable {
  private(set) var snapshot = VoiceInputSnapshot()

  mutating func begin(id: UUID, mode: VoiceInputMode) {
    snapshot = VoiceInputSnapshot(
      sessionID: id, mode: mode, phase: .preparing,
      isHeld: mode == .pushToTalk)
  }

  func canStart(id: UUID) -> Bool {
    snapshot.sessionID == id && snapshot.phase == .preparing
      && (snapshot.mode != .pushToTalk || snapshot.isHeld)
  }

  func isActive(id: UUID) -> Bool { snapshot.sessionID == id && snapshot.phase.isActive }

  @discardableResult mutating func microphoneReady(id: UUID) -> Bool {
    guard canStart(id: id) else { return false }
    snapshot.phase = .listening
    return true
  }

  mutating func recognize(id: UUID, text: String, final: Bool) -> VoiceInputEffect {
    guard snapshot.sessionID == id, snapshot.phase.acceptsRecognition else { return .none }
    snapshot.transcript = String(text.prefix(32_000))
    snapshot.isFinal = final
    guard final else { return .none }
    if snapshot.mode == .pushToTalk && snapshot.isHeld {
      snapshot.phase = .awaitingRelease
      return .none
    }
    return complete()
  }

  mutating func finish(id: UUID) -> VoiceInputEffect {
    guard snapshot.sessionID == id, snapshot.phase.isActive else { return .none }
    snapshot.isHeld = false
    switch snapshot.phase {
    case .preparing:
      snapshot.phase = .cancelled
      return .cancelledBeforeReady
    case .listening:
      snapshot.phase = .finishing
      return .finishAudio
    case .awaitingRelease: return complete()
    default: return .none
    }
  }

  mutating func tailDeadline(id: UUID) -> VoiceInputEffect {
    guard snapshot.sessionID == id, snapshot.phase == .finishing else { return .none }
    return complete()
  }

  @discardableResult mutating func fail(id: UUID) -> Bool {
    guard isActive(id: id) else { return false }
    snapshot.phase = .failed
    snapshot.isHeld = false
    return true
  }

  mutating func cancel() {
    // Invalidate the ID before cancelling OS work; queued callbacks then fail closed.
    snapshot = VoiceInputSnapshot(phase: .cancelled)
  }

  private mutating func complete() -> VoiceInputEffect {
    guard let sessionID = snapshot.sessionID, let mode = snapshot.mode else { return .none }
    snapshot.phase = .completed
    snapshot.isHeld = false
    return .completed(
      VoiceInputCompletion(
        sessionID: sessionID, mode: mode,
        transcript: snapshot.transcript.trimmingCharacters(in: .whitespacesAndNewlines),
        isFinal: snapshot.isFinal))
  }
}

/// Manual dictation can replace only the draft it last authored. Push-to-talk
/// never writes the typed draft, including while a late recognized tail arrives.
struct VoiceDraftGuard: Sendable {
  private var expectedDraft: String
  init(draft: String) { expectedDraft = draft }
  mutating func replacement(mode: VoiceInputMode, transcript: String, currentDraft: String)
    -> String?
  {
    guard mode == .manualReview, currentDraft == expectedDraft else { return nil }
    expectedDraft = transcript
    return transcript
  }
}
