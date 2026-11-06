import CompanionCore
import CoreGraphics
import Foundation
import ImageIO
import Testing

@testable import OpenCompanion

/// Exercises the real send task and admission callbacks with authored frames
/// and an injected responder. No capture service, provider, window or audio runs.
@Suite @MainActor struct AppModelSelectedGuidanceContinuationTests {
  @Test func typedSelectedGuidanceDeclaresARequestAndWorkflowBeforeTheTaskStarts() throws {
    let probe = SelectedGuidanceTurnProbe()
    let model = makeModel(probe: probe)
    defer { model.stop() }
    let source = try evidence()
    let notebook = BuiltInLessons.lever()
    model.scene = notebook
    let scope = try select(source, on: model)
    model.input = goal

    model.send()

    let request = try #require(model.activeGuidanceRequest)
    let token = try #require(model.guidanceSession.currentToken)
    #expect(request.prompt == goal && request.step == 0 && !request.speakAloud)
    #expect(request.selectedScope == scope)
    #expect(model.guidanceSession.workflow?.id == token.workflowID)
    #expect(model.guidanceSession.workflow?.phase == .checking)
    #expect(model.guidanceSession.workflow?.checks.count == 1)
    #expect(model.responsePolicy.route == .screenGuidance && !model.responsePolicy.allowsNotebook)
    #expect(model.busy && model.scene == notebook && model.input.isEmpty)
    #expect(probe.sources.isEmpty && probe.inputs.isEmpty)
    model.stop()
  }

  @Test func actualSendUsesOnlyTheFreshSelectedImageAndSemanticCandidates() async throws {
    let probe = SelectedGuidanceTurnProbe()
    let model = makeModel(probe: probe)
    defer { model.stop() }
    let source = try evidence()
    let notebook = BuiltInLessons.lever()
    model.scene = notebook
    model.selectedContext = "PUBLIC_FILE_MEMORY_MARKER"
    let published = model.publishSelectedCapture(
      source, token: model.capturePublicationRevision, strokes: "PUBLIC_STROKE_MARKER")
    #expect(published)
    let scope = try model.currentSelectedGuidanceScope()
    let selectedContext = model.selectedContext
    model.input = goal

    model.send()
    try await until { probe.inputs.count == 1 && !model.busy }

    let input = try #require(probe.inputs.first)
    let fresh = try #require(probe.frames.first)
    #expect(probe.sources == [ScreenEvidenceIdentity(source)] && probe.preparations == 1)
    #expect(input.image == fresh.image && input.image != source.image)
    #expect(
      input.context.contains(fresh.semanticText) && !input.context.contains(source.semanticText))
    #expect(input.context.contains(fresh.groundingCandidates[0].id))
    #expect(!input.context.contains(source.groundingCandidates[0].id))
    #expect(!input.context.contains("PUBLIC_FILE_MEMORY_MARKER"))
    #expect(!input.context.contains("PUBLIC_STROKE_MARKER"))
    #expect(input.messages.map(\.text) == [goal])
    #expect(input.scene == nil && input.responsePolicy.route == .screenGuidance)
    #expect(model.evidence?.frameID == fresh.frameID)
    #expect(model.selectedCaptureSelectionID == scope.selectionID)
    #expect(model.activeGuidanceRequest?.selectedScope == scope)
    #expect(model.guidanceSession.workflow?.checks.last?.outcome == .uncertain)
    #expect(model.messages.last?.text == "Public next-step explanation.")
    #expect(model.selectedContext == selectedContext && model.scene == notebook)
    #expect(model.error == nil && !model.voice.hasPendingSpeech)
    expectNoExternalCaptureOrScene(model)
  }

  @Test(arguments: [ScreenGuidanceContinuationObservation.click, .explicitContinue])
  func actualManualAndClickContinuationKeepScopeButSendAnotherFreshFrame(
    _ observation: ScreenGuidanceContinuationObservation
  ) async throws {
    let probe = SelectedGuidanceTurnProbe()
    let model = makeModel(probe: probe)
    defer { model.stop() }
    let scope = try select(evidence(), on: model)
    model.input = goal
    model.send()
    try await until { probe.inputs.count == 1 && !model.busy }
    let request = try #require(model.activeGuidanceRequest)
    let frame = try #require(model.evidence)
    let token = try #require(model.guidanceSession.currentToken)
    let workflowID = token.workflowID
    try model.guidanceSession.presentAction(
      token: token, instruction: "Use the public control, then request a fresh check.",
      label: "Public control", kind: observation == .click ? .click : .manual)
    let generation = model.taskGeneration

    model.continueScreenGuidance(
      request: request, expectedEvidence: ScreenEvidenceIdentity(frame), generation: generation,
      observation: observation)

    let next = try #require(model.activeGuidanceRequest)
    #expect(next.id == request.id && next.step == request.step + 1)
    #expect(next.expires == request.expires && next.speakAloud == request.speakAloud)
    #expect(
      next.selectedScope == scope && model.guidanceSession.currentToken?.workflowID == workflowID)
    #expect(
      model.guidanceSession.workflow?.currentAction?.observation?.kind
        == (observation == .click ? .click : .manualContinue))
    try await until { probe.inputs.count == 2 && !model.busy }

    #expect(probe.sources.count == 2 && probe.sources[1] == ScreenEvidenceIdentity(frame))
    #expect(probe.frames[1].frameID != frame.frameID)
    #expect(probe.inputs[1].image == probe.frames[1].image)
    #expect(probe.inputs[1].context.contains(probe.frames[1].groundingCandidates[0].id))
    #expect(!probe.inputs[1].context.contains(frame.groundingCandidates[0].id))
    #expect(model.selectedCaptureSelectionID == scope.selectionID)
    #expect(model.activeGuidanceRequest?.selectedScope == scope)
    #expect(model.guidanceSession.workflow?.checks.count == 2)
    #expect(model.messages.filter { $0.role == "user" }.map(\.text) == [goal, "Continue"])
    #expect(model.error == nil && !model.voice.hasPendingSpeech)
    expectNoExternalCaptureOrScene(model)
  }

  @Test func recognizedManualContinueRetainsTheSelectedScopeAndSilentPolicy() async throws {
    let probe = SelectedGuidanceTurnProbe()
    let model = makeModel(probe: probe)
    defer { model.stop() }
    let scope = try select(evidence(), on: model)
    model.input = goal
    model.send()
    try await until { probe.inputs.count == 1 && !model.busy }
    let request = try #require(model.activeGuidanceRequest)
    let frame = try #require(model.evidence)
    let token = try #require(model.guidanceSession.currentToken)
    try model.guidanceSession.presentAction(
      token: token, instruction: "Enter the public name, then Continue.", kind: .manual)
    let now = ProcessInfo.processInfo.systemUptime
    let step = ManualGuidanceStep(
      id: UUID(), label: "Public name", instruction: "Enter the public name.",
      evidence: ScreenEvidenceIdentity(frame), generation: model.taskGeneration,
      request: request, targetRect: .init(x: -400, y: 20, width: 100, height: 30),
      expiresAt: min(request.expires, now + 45))
    let continuation = ManualGuidanceVoiceContinuation(
      step: step, inputGeneration: model.taskGeneration)
    model.input = "Keep this unsent draft"

    let handled = model.continueManualGuidanceVoice(
      continuation, transcript: "I'm done!", foregroundPID: frame.foregroundPID, now: now)

    #expect(handled)
    #expect(model.activeGuidanceRequest?.selectedScope == scope)
    #expect(model.activeGuidanceRequest?.id == request.id)
    #expect(model.activeGuidanceRequest?.step == request.step + 1)
    #expect(model.activeGuidanceRequest?.speakAloud == false)
    try await until { probe.inputs.count == 2 && !model.busy }
    #expect(probe.sources.count == 2 && probe.sources[1] == ScreenEvidenceIdentity(frame))
    #expect(model.messages.last(where: { $0.role == "user" })?.text == "I'm done!")
    #expect(model.input == "Keep this unsent draft" && !model.voice.hasPendingSpeech)
    #expect(model.guidanceSession.workflow?.currentAction?.observation?.kind == .manualContinue)
    expectNoExternalCaptureOrScene(model)
  }

  @Test func aLoadingRetryCapturesTheSameSelectionAgainBeforeTheNextAssessment() async throws {
    let probe = SelectedGuidanceTurnProbe()
    probe.firstAssessment = .loading
    let model = makeModel(probe: probe)
    defer { model.stop() }
    let source = try evidence()
    let scope = try select(source, on: model)
    model.input = goal
    model.send()
    let initialRequest = try #require(model.activeGuidanceRequest)
    let workflowID = try #require(model.guidanceSession.workflow?.id)

    // The production 750 ms settle is retained. This is a bounded correctness
    // check of the retry path, with no assertion about scheduling speed.
    try await until { probe.inputs.count == 2 && !model.busy }

    let next = try #require(model.activeGuidanceRequest)
    #expect(next.id == initialRequest.id && next.step == 1)
    #expect(next.selectedScope == scope && next.expires == initialRequest.expires)
    #expect(model.guidanceSession.workflow?.id == workflowID)
    #expect(model.guidanceSession.workflow?.checks.count == 2)
    #expect(model.guidanceSession.workflow?.checks.first?.outcome == .loading)
    #expect(model.guidanceSession.workflow?.checks.last?.outcome == .uncertain)
    #expect(
      probe.sources == [ScreenEvidenceIdentity(source), ScreenEvidenceIdentity(probe.frames[0])])
    #expect(probe.frames[0].frameID != probe.frames[1].frameID)
    #expect(probe.frames.allSatisfy { scope.matches($0) })
    #expect(probe.inputs[0].image == probe.frames[0].image)
    #expect(probe.inputs[1].image == probe.frames[1].image)
    #expect(!probe.inputs[1].context.contains(probe.frames[0].groundingCandidates[0].id))
    #expect(model.selectedCaptureSelectionID == scope.selectionID)
    #expect(model.messages.last(where: { $0.role == "user" })?.text == "Check loading page")
    #expect(model.error == nil)
    expectNoExternalCaptureOrScene(model)
  }

  @Test func pausingAndRawResumeRetainLiveScopeWithANewRequestAndCheck() throws {
    let probe = SelectedGuidanceTurnProbe()
    let model = makeModel(probe: probe)
    defer { model.stop() }
    let scope = try select(evidence(), on: model)
    model.input = goal
    model.send()
    let original = try #require(model.activeGuidanceRequest)
    let token = try #require(model.guidanceSession.currentToken)
    model.pauseGuidance()
    #expect(model.activeGuidanceRequest == nil && model.guidanceCanResume)
    #expect(!model.guidanceRequiresScopeChoice)

    model.resumeGuidance()

    let resumed = try #require(model.activeGuidanceRequest)
    #expect(resumed.id != original.id && resumed.prompt == original.prompt)
    #expect(resumed.selectedScope == scope && resumed.speakAloud == original.speakAloud)
    #expect(model.guidanceSession.currentToken?.workflowID == token.workflowID)
    #expect(model.guidanceSession.currentToken?.checkID != token.checkID)
    #expect(model.guidanceSession.workflow?.checks.count == 2)
    #expect(model.selectedCaptureSelectionID == scope.selectionID)
    #expect(probe.sources.isEmpty && probe.inputs.isEmpty)
    model.stop()
  }

  @Test func replacingASelectionRequiresAnExplicitScopeChoiceForTheSameWorkflow() throws {
    let probe = SelectedGuidanceTurnProbe()
    let model = makeModel(probe: probe)
    defer { model.stop() }
    let oldScope = try select(evidence(), on: model)
    model.input = goal
    model.send()
    let workflowID = try #require(model.guidanceSession.workflow?.id)
    model.pauseGuidance()
    model.clearContext()
    let replacement = try evidence(
      windowID: 88, rect: .init(x: 150, y: -200, width: 420, height: 280))
    let newScope = try select(replacement, on: model)
    #expect(newScope.selectionID != oldScope.selectionID)
    let generation = model.taskGeneration
    let checks = model.guidanceSession.workflow?.checks.count

    model.resumeGuidance()

    #expect(model.activeGuidanceRequest == nil && model.taskGeneration == generation)
    #expect(model.guidanceSession.workflow?.checks.count == checks)
    #expect(model.guidanceRequiresScopeChoice && model.guidanceHasSelectedScope)
    #expect(model.notice?.contains("Choose") == true)
    model.resumeGuidanceWithSelectedContext()
    let request = try #require(model.activeGuidanceRequest)
    #expect(request.selectedScope == newScope)
    #expect(model.guidanceSession.workflow?.id == workflowID)
    #expect(model.guidanceSession.workflow?.checks.count == (checks ?? 0) + 1)
    #expect(!model.guidanceRequiresScopeChoice)
    #expect(probe.sources.isEmpty && probe.inputs.isEmpty)
    model.stop()
  }

  @Test func semanticProgressWithoutALiveBindingRequiresExplicitCurrentScreenChoice() throws {
    let probe = SelectedGuidanceTurnProbe()
    let model = makeModel(probe: probe)
    defer { model.stop() }
    // Represents semantic-only progress: no live AppModel capture binding was
    // created by send, and no saved screenshot/PID is treated as authority.
    try model.guidanceSession.start(goal: goal, speakAloud: false)
    model.guidanceSession.pause()
    let workflowID = try #require(model.guidanceSession.workflow?.id)
    let generation = model.taskGeneration

    model.resumeGuidance()

    #expect(model.activeGuidanceRequest == nil && model.taskGeneration == generation)
    #expect(model.guidanceRequiresScopeChoice)
    model.resumeGuidanceOnCurrentScreen()
    let request = try #require(model.activeGuidanceRequest)
    #expect(request.selectedScope == nil && request.prompt == goal)
    #expect(model.guidanceSession.workflow?.id == workflowID)
    #expect(model.guidanceSession.workflow?.checks.count == 1)
    #expect(probe.sources.isEmpty && probe.inputs.isEmpty)
    // Stop synchronously: this explicit current-screen route must not reach
    // CaptureService in a metadata-only test.
    model.stop()
  }

  @Test(arguments: [SelectedGuidanceInterruption.stop, .newTurn, .newSelection])
  func interruptionDuringRefreshCannotPublishOrDispatchTheOldSelectedTurn(
    _ interruption: SelectedGuidanceInterruption
  ) async throws {
    let probe = SelectedGuidanceTurnProbe()
    let barrier = SelectedGuidanceCaptureBarrier()
    let model = makeModel(probe: probe, barrier: barrier)
    defer {
      model.stop()
      barrier.release()
    }
    let source = try evidence()
    _ = try select(source, on: model)
    model.input = goal
    model.send()
    try await until { barrier.entered }
    let generation = model.taskGeneration
    var expected = source
    switch interruption {
    case .stop:
      model.stop()
    case .newTurn:
      model.input = "Hello"
      model.send()
    case .newSelection:
      model.clearContext()
      expected = try evidence(windowID: 88)
      _ = try select(expected, on: model)
    }
    barrier.release()
    try await until { probe.finishedRefreshes == 1 && !model.busy }

    #expect(model.taskGeneration > generation)
    #expect(ScreenEvidenceIdentity(expected).matches(model.evidence))
    #expect(model.evidence?.frameID != probe.frames.first?.frameID)
    #expect(probe.sources.count == 1)
    #expect(probe.inputs.allSatisfy { $0.responsePolicy.route == .conversation })
    #expect(probe.inputs.count == (interruption == .newTurn ? 1 : 0))
    #expect(model.activeGuidanceRequest == nil)
    #expect(
      !model.diagnosticEvents.contains {
        $0["event"] == "guidance.selectedCapture.refresh.accepted"
      })
    expectNoExternalCaptureOrScene(model)
  }

  private var goal: String { "Help me click this control on the current screen" }

  private func makeModel(
    probe: SelectedGuidanceTurnProbe, barrier: SelectedGuidanceCaptureBarrier? = nil
  ) -> AppModel {
    let model = AppModel(
      acceptanceMode: true, guidanceForegroundPID: { 424_242 },
      screenGuidanceEnabled: { true },
      scopedGuidanceRefresh: { source in
        probe.sources.append(ScreenEvidenceIdentity(source))
        defer { probe.finishedRefreshes += 1 }
        let fresh = try freshEvidence(source, index: probe.sources.count)
        probe.frames.append(fresh)
        if let barrier { await barrier.suspend() }
        return fresh
      },
      responseStream: { input, onUnit, _ in
        probe.inputs.append(input)
        if input.responsePolicy.route == .screenGuidance {
          try await onUnit(
            ProviderUnit(
              type: "guidanceStatus", text: nil, title: nil, nodes: nil, removeIDs: nil,
              target: nil,
              guidance: .init(
                status: probe.inputs.count == 1 ? probe.firstAssessment : .uncertain,
                summary: "A public fresh-screen assessment.")))
        }
        try await onUnit(
          ProviderUnit(
            type: "text", text: "Public next-step explanation.", title: nil, nodes: nil,
            removeIDs: nil, target: nil))
      })
    model.configuration.speechEnabled = false
    model.onPrepareScreenGuidance = { [weak model] _, pid in
      #expect(pid == 424_242)
      #expect(model?.guidanceSceneScope?.foregroundPID == pid)
      probe.preparations += 1
    }
    return model
  }

  private func select(_ frame: OpenCompanion.ScreenEvidence, on model: AppModel) throws
    -> ScreenGuidanceCaptureScope
  {
    let published = model.publishSelectedCapture(frame, token: model.capturePublicationRevision)
    #expect(published)
    return try model.currentSelectedGuidanceScope()
  }

  private func evidence(
    windowID: UInt32? = 42, rect: CGRect = .init(x: -600, y: -200, width: 320, height: 240)
  ) throws -> OpenCompanion.ScreenEvidence {
    let frameID = UUID()
    let candidate = ScreenGroundingCandidate(
      id: ScreenGrounding.candidateID(frameID: frameID, index: 0), source: .accessibility,
      role: "AXButton", label: "Old public control", enabled: true, actionable: true,
      x: 0.1, y: 0.1, width: 0.1, height: 0.1)
    return .init(
      frameID: frameID, revision: 10, capturedAt: ProcessInfo.processInfo.systemUptime - 1,
      displayID: 1, foregroundPID: 424_242, foregroundName: "Authored public fixture",
      screenRect: rect, windowID: windowID,
      image: try jpeg(red: 0.8, green: 0.1, blue: 0.1),
      semanticText: "OLD_PUBLIC_SCREEN " + candidate.id,
      groundingCandidates: [candidate], imageWidth: 32, imageHeight: 24)
  }

  private func freshEvidence(_ source: OpenCompanion.ScreenEvidence, index: Int) throws
    -> OpenCompanion.ScreenEvidence
  {
    var fresh = source
    fresh.frameID = UUID()
    fresh.revision += 1
    fresh.capturedAt = ProcessInfo.processInfo.systemUptime
    fresh.image = try jpeg(red: 0.1, green: Double(index % 3) / 3, blue: 0.8)
    let candidate = ScreenGroundingCandidate(
      id: ScreenGrounding.candidateID(frameID: fresh.frameID, index: 0), source: .accessibility,
      role: "AXButton", label: "Fresh public control", enabled: true, actionable: true,
      x: 0.2, y: 0.2, width: 0.1, height: 0.1)
    fresh.semanticText = "FRESH_PUBLIC_SCREEN_\(index) " + candidate.id
    fresh.groundingCandidates = [candidate]
    return fresh
  }

  private func jpeg(red: Double, green: Double, blue: Double) throws -> Data {
    guard
      let context = CGContext(
        data: nil, width: 32, height: 24, bitsPerComponent: 8, bytesPerRow: 32 * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { throw FixtureFailure.image }
    context.setFillColor(CGColor(red: red, green: green, blue: blue, alpha: 1))
    context.fill(.init(x: 0, y: 0, width: 32, height: 24))
    guard let image = context.makeImage() else { throw FixtureFailure.image }
    let data = NSMutableData()
    guard
      let destination = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil)
    else { throw FixtureFailure.image }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { throw FixtureFailure.image }
    return data as Data
  }

  private func until(_ condition: @MainActor () -> Bool) async throws {
    // A five-second ceiling bounds failures, including the unchanged native
    // loading settle. No elapsed-time or latency claim is made by these tests.
    for _ in 0..<500 {
      if condition() { return }
      try await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("The authored send task did not reach its expected checkpoint.")
    throw FixtureFailure.checkpoint
  }

  private func expectNoExternalCaptureOrScene(_ model: AppModel) {
    #expect(
      !model.diagnosticEvents.contains {
        ["guidance.capture.started", "guidance.capture.accepted", "visual.accepted"].contains(
          $0["event"] ?? "")
      })
    #expect(model.codex == nil && !model.voice.hasPendingSpeech)
    #expect(model.overlay.presentationDiagnostics.isEmpty)
  }

  private enum FixtureFailure: Error { case image, checkpoint }
}

enum SelectedGuidanceInterruption: Sendable, Equatable { case stop, newTurn, newSelection }

@MainActor private final class SelectedGuidanceTurnProbe {
  var sources: [ScreenEvidenceIdentity] = []
  var frames: [OpenCompanion.ScreenEvidence] = []
  var inputs: [ReasoningTurnInput] = []
  var preparations = 0
  var finishedRefreshes = 0
  var firstAssessment: ProviderGuidanceAssessment.Status = .uncertain
}

@MainActor private final class SelectedGuidanceCaptureBarrier {
  private var continuation: CheckedContinuation<Void, Never>?
  private(set) var entered = false

  func suspend() async {
    await withCheckedContinuation { continuation in
      self.continuation = continuation
      entered = true
    }
  }

  func release() {
    continuation?.resume()
    continuation = nil
  }
}
