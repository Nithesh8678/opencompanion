import Foundation

/// Content-free, request-local transport clocks. These do not measure rendered
/// pixels, acoustic output, or external task completion.
struct CodexTimingEvent: Codable, Sendable, Equatable {
  enum Stage: String, Codable, Sendable, CaseIterable {
    case requestStarted, sessionStarted, initialized, accountVerified, routingSelected
    case configurationReady, threadReady, turnSubmitted, turnAccepted
    case firstTextDelta, firstUnitAccepted, firstSceneAccepted, responseCompleted
  }
  let stage: Stage
  let elapsedMS: Double
}

actor CodexTimingReporter {
  private let started = ProcessInfo.processInfo.systemUptime
  private let onEvent: (@Sendable (CodexTimingEvent) async -> Void)?
  private var emitted = Set<CodexTimingEvent.Stage>()

  init(onEvent: (@Sendable (CodexTimingEvent) async -> Void)?) {
    self.onEvent = onEvent
  }

  func mark(_ stage: CodexTimingEvent.Stage) async {
    guard let onEvent, emitted.insert(stage).inserted else { return }
    let elapsed =
      stage == .requestStarted ? 0 : (ProcessInfo.processInfo.systemUptime - started) * 1_000
    guard elapsed.isFinite, elapsed >= 0 else { return }
    await onEvent(CodexTimingEvent(stage: stage, elapsedMS: elapsed))
  }
}
