import AppKit
import CompanionCore
import ImageIO

/// Observes the existing production continuation; never starts a turn or performs input.
@MainActor final class GuidanceFixtureTaskAcceptance {
  struct Receipt: Codable, Sendable {
    let providerFinalTextAccepted: Bool
    let fixturePostconditionVerified: Bool
    let taskComplete: Bool
    let requestID: UUID
    let generation: UInt64
    let finalGuidanceStep: Int
    let finalFrameID: UUID
    let finalEvidenceRevision: UInt64
    let finalCaptureUptime: TimeInterval
    let publicFixturePID: pid_t
    let displayID: CGDirectDisplayID
    let imageWidth: Int
    let imageHeight: Int
    let initialState: GuidanceFixtureStateAcceptance.Snapshot
    let editedState: GuidanceFixtureStateAcceptance.Snapshot
    let beforeFinalCapture: GuidanceFixtureStateAcceptance.Snapshot
    let afterFinalCapture: GuidanceFixtureStateAcceptance.Snapshot
    let manualContinueRequestedCount: Int
    let clickObservedCount: Int
    let captureAcceptedCount: Int
    let clickObservedAtUptime: TimeInterval
    let providerCompletedAtUptime: TimeInterval
    let verifierElapsedMS: Double
  }

  enum Failure: String, Error, LocalizedError, Sendable {
    case requestChanged, generationChanged, deadlineExpired, captureSequenceInvalid
    case initialStateInvalid, editedStateInvalid, checkboxNotOff, stateTimingInvalid
    case continuationCountInvalid, unexpectedFinalTarget, freshEvidenceMissing
    case imageHeaderInvalid, visibleInputMissing, notebookChanged, modelError, traceInvalid
    case finalReplyEmpty
    var errorDescription: String? { "Public guidance task verification: \(rawValue)." }
  }

  private let model: AppModel
  private let pid: pid_t
  private let displayID: CGDirectDisplayID
  private let screenRect: CGRect
  private let traceStart: Int
  private let originalScene: SceneDocument?
  private let started = ProcessInfo.processInfo.systemUptime
  private var firstGeneration: UInt64?
  private var originalRequest: ScreenGuidanceRequest?
  private var readings: [Int: GuidanceFixtureStateAcceptance.Snapshot] = [:]
  private var preparing = false

  init(
    model: AppModel, expectedFixturePID: pid_t, displayID: CGDirectDisplayID,
    screenRect: CGRect, traceStart: Int
  ) {
    self.model = model
    pid = expectedFixturePID
    self.displayID = displayID
    self.screenRect = screenRect
    self.traceStart = traceStart
    originalScene = model.scene
  }

  /// Called after normal preparation, immediately before each existing capture.
  func prepareCapture(generation: UInt64) async throws {
    try Task.checkCancellation()
    guard !preparing, let request = model.activeGuidanceRequest,
      (0...2).contains(request.step), request.step == readings.count,
      generation == model.taskGeneration
    else { throw Failure.captureSequenceInvalid }
    try checkRequest(request)
    if let firstGeneration {
      guard firstGeneration <= UInt64.max - 4,
        generation == firstGeneration + UInt64(request.step) * 2
      else {
        throw Failure.generationChanged
      }
    } else if request.step != 0 || generation > UInt64.max - 4 {
      throw Failure.captureSequenceInvalid
    }
    preparing = true
    defer { preparing = false }
    let state = try await readState()
    try Task.checkCancellation()
    guard generation == model.taskGeneration, model.activeGuidanceRequest == request else {
      throw Failure.generationChanged
    }
    try checkRequest(request)
    switch request.step {
    case 0:
      guard !state.tableNameMatchesReleaseQA, state.protectDataChecked else {
        throw Failure.initialStateInvalid
      }
      firstGeneration = generation
      originalRequest = request
    case 1:
      guard state.tableNameMatchesReleaseQA, state.protectDataChecked else {
        throw Failure.editedStateInvalid
      }
    default:
      guard state.tableNameMatchesReleaseQA, !state.protectDataChecked else {
        throw Failure.checkboxNotOff
      }
    }
    readings[request.step] = state
  }

  func waitForCompletion(
    initialGeneration: UInt64, deadline: TimeInterval,
    expectedPreviousEvidence: ScreenEvidenceIdentity,
    onProgress: @MainActor () -> Void = {}
  ) async throws -> Receipt {
    guard firstGeneration == initialGeneration, let request = originalRequest,
      initialGeneration <= UInt64.max - 4,
      deadline.isFinite, deadline > started, deadline - started <= 120,
      readings.count == 2, model.taskGeneration == initialGeneration + 2,
      model.activeGuidanceRequest?.step == 1,
      let previous = model.evidence, expectedPreviousEvidence.matches(previous),
      count("guidance.userClick.observed") == 0
    else { throw Failure.captureSequenceInvalid }
    try requireSource(previous)
    let finalGeneration = initialGeneration + 4
    while true {
      try Task.checkCancellation()
      try GuidanceFixtureStateAcceptance.verifyEnvironment(
        expectedFixturePID: pid, displayID: displayID, screenRect: screenRect)
      onProgress()
      let now = ProcessInfo.processInfo.systemUptime
      guard now.isFinite, now < deadline, now < request.expires else {
        throw Failure.deadlineExpired
      }
      guard model.error == nil else { throw Failure.modelError }
      guard model.scene == originalScene, count("visual.accepted") == 0 else {
        throw Failure.notebookChanged
      }
      guard
        model.taskGeneration == initialGeneration + 2
          || model.taskGeneration == finalGeneration
      else { throw Failure.generationChanged }
      guard let active = model.activeGuidanceRequest else { throw Failure.requestChanged }
      try checkRequest(active)
      guard active.step == (model.taskGeneration == finalGeneration ? 2 : 1) else {
        throw Failure.requestChanged
      }
      guard count("guidance.manualContinue.requested") == 1,
        count("guidance.userClick.observed") <= 1,
        count("guidance.capture.accepted") <= 3
      else { throw Failure.continuationCountInvalid }
      guard count("guidance.stage.target", generation: finalGeneration) == 0 else {
        throw Failure.unexpectedFinalTarget
      }
      if model.taskGeneration == finalGeneration,
        count("generation.completed", generation: finalGeneration) == 1, !model.busy
      {
        return try await finish(
          generation: finalGeneration, request: active, previous: previous, deadline: deadline)
      }
      try await Task.sleep(for: .milliseconds(100))
    }
  }

  private func finish(
    generation: UInt64, request: ScreenGuidanceRequest, previous: ScreenEvidence,
    deadline: TimeInterval
  ) async throws -> Receipt {
    guard let reply = model.messages.last(where: { $0.role == "assistant" })?.text,
      !reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else { throw Failure.finalReplyEmpty }
    guard count("guidance.manualContinue.requested") == 1,
      count("guidance.userClick.observed") == 1, count("guidance.capture.accepted") == 3,
      count("semantic.text.accepted", generation: generation) > 0,
      let initial = readings[0], let edited = readings[1], let before = readings[2],
      let final = model.evidence
    else { throw Failure.continuationCountInvalid }
    try requireSource(final)
    guard final.frameID != previous.frameID, final.revision > previous.revision,
      final.capturedAt.isFinite, final.capturedAt > previous.capturedAt,
      before.capturedAtUptime <= final.capturedAt
    else { throw Failure.freshEvidenceMissing }
    let dimensions = try imageDimensions(final)
    guard
      final.groundingCandidates.contains(where: {
        $0.source == .ocr
          && $0.label.lowercased().filter { $0.isLetter || $0.isNumber }
            .contains("releaseqa")
      })
    else { throw Failure.visibleInputMissing }
    let identity = ScreenEvidenceIdentity(final)
    let after = try await readState()
    try Task.checkCancellation()
    guard ProcessInfo.processInfo.systemUptime < min(deadline, request.expires) else {
      throw Failure.deadlineExpired
    }
    guard model.taskGeneration == generation, model.activeGuidanceRequest == request,
      identity.matches(model.evidence)
    else { throw Failure.generationChanged }
    guard after.tableNameMatchesReleaseQA, !after.protectDataChecked else {
      throw Failure.checkboxNotOff
    }
    guard after.capturedAtUptime >= final.capturedAt else { throw Failure.stateTimingInvalid }
    guard model.error == nil, !model.busy else { throw Failure.modelError }
    guard model.scene == originalScene, count("visual.accepted") == 0 else {
      throw Failure.notebookChanged
    }
    guard count("guidance.stage.target", generation: generation) == 0,
      count("guidance.userClick.observed") == 1,
      count("guidance.manualContinue.requested") == 1,
      count("guidance.capture.accepted") == 3,
      count("generation.completed", generation: generation) == 1
    else { throw Failure.continuationCountInvalid }
    let clickTime = try eventTime("guidance.userClick.observed")
    let completedTime = try eventTime("generation.completed", generation: generation)
    let elapsedMS = (after.capturedAtUptime - started) * 1_000
    guard clickTime <= before.capturedAtUptime, final.capturedAt > clickTime,
      completedTime >= final.capturedAt, elapsedMS.isFinite, elapsedMS >= 0
    else {
      throw Failure.stateTimingInvalid
    }
    return Receipt(
      providerFinalTextAccepted: true, fixturePostconditionVerified: true, taskComplete: true,
      requestID: request.id, generation: generation, finalGuidanceStep: 2,
      finalFrameID: final.frameID,
      finalEvidenceRevision: final.revision, finalCaptureUptime: final.capturedAt,
      publicFixturePID: pid, displayID: displayID,
      imageWidth: dimensions.0, imageHeight: dimensions.1,
      initialState: initial, editedState: edited, beforeFinalCapture: before,
      afterFinalCapture: after, manualContinueRequestedCount: 1, clickObservedCount: 1,
      captureAcceptedCount: 3, clickObservedAtUptime: clickTime,
      providerCompletedAtUptime: completedTime,
      verifierElapsedMS: elapsedMS)
  }

  private func checkRequest(_ request: ScreenGuidanceRequest) throws {
    let now = ProcessInfo.processInfo.systemUptime
    guard request.expires.isFinite, now.isFinite, now < request.expires,
      request.expires - now <= 180
    else { throw Failure.deadlineExpired }
    if let originalRequest {
      guard request.id == originalRequest.id, request.expires == originalRequest.expires,
        request.prompt == originalRequest.prompt, request.speakAloud == originalRequest.speakAloud
      else { throw Failure.requestChanged }
    }
  }

  private func requireSource(_ evidence: ScreenEvidence) throws {
    guard evidence.foregroundPID == pid, evidence.displayID == displayID,
      evidence.windowID == nil, evidence.screenRect == screenRect,
      evidence.capturedAt.isFinite, evidence.capturedAt >= 0
    else { throw Failure.freshEvidenceMissing }
  }

  private func readState() async throws -> GuidanceFixtureStateAcceptance.Snapshot {
    try await GuidanceFixtureStateAcceptance.snapshot(
      expectedFixturePID: pid, displayID: displayID, screenRect: screenRect)
  }

  private var events: [[String: String]] {
    let trace = model.diagnosticEvents
    guard traceStart >= 0, traceStart <= trace.count else { return [] }
    return Array(trace.dropFirst(traceStart).suffix(2_000))
  }

  private func count(_ name: String, generation: UInt64? = nil) -> Int {
    events.filter {
      guard $0["event"] == name else { return false }
      if let generation { return $0["generation"] == String(generation) }
      return true
    }.count
  }

  private func eventTime(_ name: String, generation: UInt64? = nil) throws -> TimeInterval {
    guard
      let event = events.first(where: {
        guard $0["event"] == name else { return false }
        if let generation { return $0["generation"] == String(generation) }
        return true
      }), let text = event["time"], let value = Double(text), value.isFinite, value >= started
    else {
      throw Failure.traceInvalid
    }
    return value
  }

  private func imageDimensions(_ evidence: ScreenEvidence) throws -> (Int, Int) {
    guard evidence.image.count <= 12 * 1_024 * 1_024,
      let source = CGImageSourceCreateWithData(evidence.image as CFData, nil),
      CGImageSourceGetCount(source) == 1,
      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
      let width = properties[kCGImagePropertyPixelWidth] as? Int,
      let height = properties[kCGImagePropertyPixelHeight] as? Int,
      width > 0, height > 0, width <= 8_192, height <= 8_192,
      width == evidence.imageWidth, height == evidence.imageHeight,
      (properties[kCGImagePropertyOrientation] as? Int ?? 1) == 1
    else { throw Failure.imageHeaderInvalid }
    return (width, height)
  }
}
