import Foundation

/// Content-free, request-local transport clocks. These do not measure rendered
/// pixels, acoustic output, or external task completion.
struct CodexTimingEvent: Codable, Sendable, Equatable {
  enum Stage: String, Codable, Sendable, CaseIterable {
    case requestStarted, sessionStarted, initialized, accountVerified, routingSelected
    case configurationReady, threadReady, turnSubmitted, turnAccepted
    case firstTextDelta, firstUnitAccepted, firstSceneAccepted, responseCompleted
    case finalMessageStarted, finalMessageCompleted, phaseCompatibilityFallback
    case requestPayloadPrepared, firstSceneLineDecoded
    case firstSceneHandlerStarted, firstSceneHandlerCompleted, firstSceneHandlerFailed
  }
  let stage: Stage
  let elapsedMS: Double
  let lineStartMS: Double?
  let lineEndMS: Double?
  let lineUTF8Bytes: Int?
  let lineTermination: ProviderLineWireSample.Termination?
  let instructionUTF8Bytes: Int?
  let conversationUTF8Bytes: Int?
  let turnInputUTF8Bytes: Int?

  init(
    stage: Stage, elapsedMS: Double, lineStartMS: Double? = nil, lineEndMS: Double? = nil,
    lineUTF8Bytes: Int? = nil, lineTermination: ProviderLineWireSample.Termination? = nil,
    instructionUTF8Bytes: Int? = nil, conversationUTF8Bytes: Int? = nil,
    turnInputUTF8Bytes: Int? = nil
  ) {
    self.stage = stage
    self.elapsedMS = elapsedMS
    self.lineStartMS = lineStartMS
    self.lineEndMS = lineEndMS
    self.lineUTF8Bytes = lineUTF8Bytes
    self.lineTermination = lineTermination
    self.instructionUTF8Bytes = instructionUTF8Bytes
    self.conversationUTF8Bytes = conversationUTF8Bytes
    self.turnInputUTF8Bytes = turnInputUTF8Bytes
  }
}

actor CodexTimingReporter {
  private let started: Double
  private let onEvent: (@Sendable (CodexTimingEvent) async -> Void)?
  private var emitted = Set<CodexTimingEvent.Stage>()
  private var firstSceneHandlerStarted = false
  private var firstSceneHandlerFinished = false

  init(
    onEvent: (@Sendable (CodexTimingEvent) async -> Void)?,
    startedUptime: Double = ProcessInfo.processInfo.systemUptime
  ) {
    self.onEvent = onEvent
    started = startedUptime
  }

  func mark(_ stage: CodexTimingEvent.Stage) async {
    guard let onEvent, emitted.insert(stage).inserted else { return }
    let elapsed =
      stage == .requestStarted ? 0 : (ProcessInfo.processInfo.systemUptime - started) * 1_000
    guard elapsed.isFinite, elapsed >= 0 else { return }
    await onEvent(CodexTimingEvent(stage: stage, elapsedMS: elapsed))
  }

  /// Emitted when classification is known, with earlier client wire timestamps.
  /// This is decoded scene framing, not native scene admission or remote timing.
  func recordSceneLine(_ sample: ProviderLineWireSample) async {
    guard let onEvent, !emitted.contains(.firstSceneLineDecoded),
      sample.startedUptime.isFinite, sample.completedUptime.isFinite,
      sample.startedUptime >= started, sample.completedUptime >= sample.startedUptime,
      sample.utf8Bytes > 0, sample.utf8Bytes <= ProviderLineWireClock.maximumLineBytes
    else { return }
    let begin = (sample.startedUptime - started) * 1_000
    let end = (sample.completedUptime - started) * 1_000
    let elapsed = (ProcessInfo.processInfo.systemUptime - started) * 1_000
    guard begin.isFinite, end.isFinite, elapsed.isFinite, elapsed >= end else { return }
    emitted.insert(.firstSceneLineDecoded)
    await onEvent(
      .init(
        stage: .firstSceneLineDecoded, elapsedMS: elapsed,
        lineStartMS: begin, lineEndMS: end, lineUTF8Bytes: sample.utf8Bytes,
        lineTermination: sample.termination))
  }

  func recordRequestPayload(
    instructionUTF8Bytes: Int, conversationUTF8Bytes: Int, turnInputUTF8Bytes: Int
  ) async {
    guard let onEvent, !emitted.contains(.requestPayloadPrepared),
      [instructionUTF8Bytes, conversationUTF8Bytes, turnInputUTF8Bytes].allSatisfy({
        $0 >= 0 && $0 <= Int32.max
      })
    else { return }
    let elapsed = (ProcessInfo.processInfo.systemUptime - started) * 1_000
    guard elapsed.isFinite, elapsed >= 0 else { return }
    emitted.insert(.requestPayloadPrepared)
    await onEvent(
      .init(
        stage: .requestPayloadPrepared, elapsedMS: elapsed,
        instructionUTF8Bytes: instructionUTF8Bytes, conversationUTF8Bytes: conversationUTF8Bytes,
        turnInputUTF8Bytes: turnInputUTF8Bytes))
  }

  /// The caller retains this Bool across its awaited handler and reports an end
  /// only for this first invocation. A later scene failure cannot rename it.
  func beginFirstSceneHandler() async -> Bool {
    guard !firstSceneHandlerStarted else { return false }
    firstSceneHandlerStarted = true
    await mark(.firstSceneHandlerStarted)
    return true
  }

  func finishFirstSceneHandler(success: Bool) async {
    guard firstSceneHandlerStarted, !firstSceneHandlerFinished else { return }
    firstSceneHandlerFinished = true
    await mark(success ? .firstSceneHandlerCompleted : .firstSceneHandlerFailed)
  }
}
