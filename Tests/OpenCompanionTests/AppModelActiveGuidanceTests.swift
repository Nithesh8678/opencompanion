import CompanionCore
import CoreGraphics
import Foundation
import ImageIO
import Testing

@testable import OpenCompanion

/// Host integration with authored acquisition, observation metadata and provider
/// callbacks. These tests perform no capture, OS observation, model, microphone,
/// audio playback, displayed window, or external input.
@Suite @MainActor struct AppModelActiveGuidanceTests {
  @Test(arguments: [false, true])
  func armingRoutesAnOrdinaryQuestionWithFreshEvidenceAndRuntimeOwnership(
    _ authoredPTT: Bool
  ) async throws {
    let probe = ActiveGuidanceProbe()
    let fixture = try makeFixture(probe)
    let model = fixture.model
    defer {
      model.stop()
      probe.releaseAll()
    }
    let question = "Can you help me?"
    #expect(
      ResponsePolicy.resolve(text: question, screenGuidanceEnabled: true).route == .conversation)
    model.selectedContext = "UNRELATED_PUBLIC_FILE"
    model.messages = [.init(role: "assistant", text: "This session has no screen access.")]
    model.setGuidanceModeArmed(true)
    try submit(question, authoredPTT: authoredPTT, fixture: fixture, probe: probe)
    let runtimeID = try #require(model.guidanceRuntime.id)
    #expect(model.activeGuidanceRequest?.prompt == question)
    try await until { probe.inputs.count == 1 && !model.busy }

    let frame = try #require(probe.frames.first)
    let input = try #require(probe.inputs.first)
    let scope = try #require(model.activeGuidanceObservationScope)
    #expect(model.guidanceRuntime.id == runtimeID && model.guidanceRuntime.goal == question)
    #expect(model.guidanceRuntime.phase == .awaitingUser && !model.guidanceRuntime.isDirty)
    #expect(scope.foregroundPID == frame.foregroundPID && scope.displayID == frame.displayID)
    #expect(scope.sourceRect == frame.screenRect && scope.windowID == nil)
    #expect(input.responsePolicy.route == .screenGuidance && input.image == frame.image)
    #expect(input.context.contains(frame.semanticText))
    #expect(input.messages.map(\.text) == [question] && input.scene == nil)
    #expect(!input.context.contains("UNRELATED_PUBLIC_FILE"))
    #expect(ScreenEvidenceIdentity(frame).matches(model.evidence))
    #expect(model.error == nil && model.codex == nil && probe.nativeSpeechCalls == 0)
  }

  @Test func shortFollowupKeepsOriginalGoalWorkflowAndFreshImageWithoutCapabilityDenial()
    async throws
  {
    let probe = ActiveGuidanceProbe()
    let fixture = try makeFixture(probe)
    let model = fixture.model
    defer {
      model.stop()
      probe.releaseAll()
    }
    let goal = "Help me open the profile panel"
    model.setGuidanceModeArmed(true)
    model.input = goal
    model.send()
    try await until { probe.inputs.count == 1 && !model.busy }
    let runtimeID = model.guidanceRuntime.id
    let workflowID = model.guidanceSession.workflow?.id
    let oldFrame = try #require(probe.frames.first)
    model.messages.append(.init(role: "assistant", text: "This session has no screen access."))
    model.messages.append(.init(role: "assistant", text: "Find the public account icon."))
    model.input = "What's next?"
    model.send()
    #expect(model.activeGuidanceRequest?.prompt == goal)
    try await until { probe.inputs.count == 2 && !model.busy }

    let input = probe.inputs[1]
    let fresh = probe.frames[1]
    #expect(model.guidanceRuntime.id == runtimeID && model.guidanceRuntime.goal == goal)
    #expect(model.guidanceSession.workflow?.id == workflowID)
    #expect(model.guidanceSession.workflow?.checks.count == 2)
    #expect(fresh.frameID != oldFrame.frameID && input.image == fresh.image)
    #expect(
      input.context.contains(fresh.semanticText) && !input.context.contains(oldFrame.semanticText))
    #expect(input.messages.last?.text.contains(goal) == true)
    #expect(input.messages.last?.text.contains("What's next?") == true)
    #expect(input.messages.first?.text == "Find the public account icon.")
    #expect(!input.messages.contains { $0.text.contains("no screen access") })
    #expect(input.scene == nil && model.error == nil)
  }

  @Test func scrollAndVisualChangesCoalesceOneFreshCheckAndRejectOldUnit() async throws {
    let probe = ActiveGuidanceProbe()
    probe.blockedCalls = [0]
    let fixture = try makeFixture(probe)
    let model = fixture.model
    defer {
      model.stop()
      probe.releaseAll()
    }
    model.setGuidanceModeArmed(true)
    model.input = "Help me open the profile panel"
    model.send()
    try await until { probe.inputs.count == 1 && probe.gates[0]?.entered == true }
    let oldScope = try #require(model.activeGuidanceObservationScope)
    let runtimeID = try #require(model.guidanceRuntime.id)
    model.receiveGuidanceObservation(
      scope: oldScope, event: event(.scroll, sequence: 1))
    model.receiveGuidanceObservation(
      scope: oldScope, event: event(.visualChange, sequence: 2))
    #expect(model.guidanceRuntime.id == runtimeID && model.guidanceRuntime.isDirty)
    #expect(model.guidanceRuntime.sceneEpoch == 2)
    // Invoke the old host callback from this noncancelled test task, so it must
    // fail on generation/evidence ownership rather than only task cancellation.
    do {
      try await probe.handlers[0](textUnit("OBSOLETE_PUBLIC_INSTRUCTION"))
      Issue.record("An old generation's provider unit must not be admitted")
    } catch { #expect(error is CancellationError) }
    probe.gates[0]?.release()
    try await until { probe.inputs.count == 2 && !model.busy && probe.finishedCalls == 2 }
    try await Task.sleep(for: .milliseconds(350))

    #expect(probe.inputs.count == 2 && probe.frames.count == 2)
    #expect(model.guidanceRuntime.id == runtimeID && !model.guidanceRuntime.isDirty)
    #expect(probe.frames[0].frameID != probe.frames[1].frameID)
    #expect(!model.messages.contains { $0.text == "OBSOLETE_PUBLIC_INSTRUCTION" })
    #expect(model.guidanceSession.workflow?.checks.count == 2 && model.error == nil)
  }

  @Test(arguments: ["stop", "suspend", "off"])
  func revocationRejectsQueuedObservationAndProviderCallbacks(_ reason: String) async throws {
    let probe = ActiveGuidanceProbe()
    probe.blockedCalls = [0]
    let fixture = try makeFixture(probe)
    let model = fixture.model
    defer {
      model.stop()
      probe.releaseAll()
    }
    model.setGuidanceModeArmed(true)
    model.input = "Help me open the profile panel"
    model.send()
    try await until { probe.inputs.count == 1 && probe.gates[0]?.entered == true }
    let scope = try #require(model.activeGuidanceObservationScope)
    let previousGeneration = model.taskGeneration
    switch reason {
    case "suspend": model.suspendGuidance()
    case "off": model.setGuidanceModeArmed(false)
    default: model.stop()
    }
    let generation = model.taskGeneration
    #expect(generation > previousGeneration && !model.guidanceRuntime.isActive)
    #expect(model.activeGuidanceObservationScope == nil && model.activeGuidanceRequest == nil)
    model.receiveGuidanceObservation(scope: scope, event: event(.visualChange, sequence: 99))
    do {
      try await probe.handlers[0](textUnit("REVOKED_PUBLIC_INSTRUCTION"))
      Issue.record("A revoked callback must not be admitted")
    } catch { #expect(error is CancellationError) }
    probe.releaseAll()
    try await until { probe.finishedCalls == 1 }
    try await Task.sleep(for: .milliseconds(350))
    #expect(model.taskGeneration == generation && !model.guidanceRuntime.isActive)
    #expect(probe.frames.count == 1 && probe.inputs.count == 1 && !model.busy)
    #expect(!model.messages.contains { $0.text == "REVOKED_PUBLIC_INSTRUCTION" })
    #expect(reason == "stop" || !model.guidanceModeArmed)
  }

  @Test func repeatedVisualOnlyChangesKeepOneInferenceAndDeferItsUnseenAssessments()
    async throws
  {
    let probe = ActiveGuidanceProbe()
    probe.blockedCalls = [0]
    let fixture = try makeFixture(probe)
    let model = fixture.model
    defer {
      model.stop()
      probe.releaseAll()
    }
    model.setGuidanceModeArmed(true)
    model.input = "Help me open the profile panel"
    model.send()
    try await until { probe.inputs.count == 1 && probe.gates[0]?.entered == true }
    let scope = try #require(model.activeGuidanceObservationScope)
    let generation = model.taskGeneration
    let runtimeID = model.guidanceRuntime.id
    let workflow = model.guidanceSession.workflow
    let request = model.activeGuidanceRequest
    for sequence in 1...40 {
      model.receiveGuidanceObservation(
        scope: scope, event: event(.visualChange, sequence: UInt64(sequence)))
    }
    try await Task.sleep(for: .milliseconds(350))
    #expect(model.taskGeneration == generation && model.busy)
    #expect(model.guidanceRuntime.id == runtimeID && model.guidanceRuntime.isDirty)
    #expect(!model.guidanceRuntime.hasHardChange && model.guidanceRuntime.sceneEpoch == 40)
    #expect(probe.frames.count == 1 && probe.inputs.count == 1)
    #expect(model.activeGuidanceRequest == request)
    #expect(model.guidanceSession.workflow == workflow)
    #expect(model.guidanceSession.workflow?.checks.count == 1)

    // The provider has not seen these changed pixels. Text/completion claims
    // must be deferred even though its one inference is still allowed to run.
    try await probe.handlers[0](textUnit("UNSEEN_VISUAL_STATE"))
    try await probe.handlers[0](
      ProviderUnit(
        type: "guidanceStatus", text: nil, title: nil, nodes: nil, removeIDs: nil, target: nil,
        guidance: .init(status: .complete, summary: "Unseen state claimed complete.")))
    #expect(model.guidanceSession.workflow == workflow)
    #expect(!model.messages.contains { $0.text == "UNSEEN_VISUAL_STATE" })
    #expect(
      model.diagnosticEvents.filter {
        $0["event"] == "guidance.live.visualPending.unitDeferred"
      }.count == 2)

    // Stop before the blocked provider returns; no real or injected refresh is
    // needed to prove that its queued late callback cannot restart a check.
    model.stop()
    let stoppedGeneration = model.taskGeneration
    probe.releaseAll()
    try await until { probe.finishedCalls == 1 }
    #expect(stoppedGeneration > generation && model.taskGeneration == stoppedGeneration)
    #expect(!model.guidanceRuntime.isActive && model.activeGuidanceObservationScope == nil)
    #expect(probe.frames.count == 1 && probe.inputs.count == 1 && !model.busy)
    #expect(model.guidanceSession.workflow?.phase == .paused)
    #expect(model.guidanceSession.workflow?.checks.count == 1)
  }

  @Test func terminalForegroundRoundTripRearmsEvenWhenSourceMetadataReturnsToA() async throws {
    let probe = ActiveGuidanceProbe()
    let fixture = try makeFixture(probe)
    let model = fixture.model
    defer {
      model.stop()
      probe.releaseAll()
    }
    model.setGuidanceModeArmed(true)
    model.input = "Help me open the profile panel"
    model.send()
    try await until { probe.inputs.count == 1 && !model.busy }
    let old = try #require(model.activeGuidanceObservationScope)
    let runtimeID = model.guidanceRuntime.id
    // This terminal metadata represents A→B. Returning the authored foreground
    // reader to A before settlement reproduces the host's same-metadata edge.
    probe.foregroundPID = 555_555
    model.receiveGuidanceObservation(scope: old, event: event(.foregroundChanged, sequence: 1))
    #expect(model.activeGuidanceObservationScope == nil)
    probe.foregroundPID = 424_242
    try await until { probe.inputs.count == 2 && !model.busy }
    let replacement = try #require(model.activeGuidanceObservationScope)
    #expect(replacement.leaseID != old.leaseID)
    #expect(
      replacement.foregroundPID == old.foregroundPID && replacement.sourceRect == old.sourceRect)
    #expect(model.guidanceRuntime.id == runtimeID && !model.guidanceRuntime.isDirty)
    let epoch = model.guidanceRuntime.sceneEpoch
    model.receiveGuidanceObservation(scope: old, event: event(.scroll, sequence: 100))
    #expect(model.guidanceRuntime.sceneEpoch == epoch && !model.guidanceRuntime.isDirty)
    #expect(probe.frames.count == 2 && model.error == nil)
  }

  @Test(arguments: [false, true])
  func short3DFollowupUsesUserTopicAndRequiresAHostAdmitted3DScene(_ emitMesh: Bool) async throws {
    let probe = ActiveGuidanceProbe()
    let fixture = try makeFixture(probe)
    let model = fixture.model
    defer {
      model.stop()
      probe.releaseAll()
    }
    model.setGuidanceModeArmed(true)
    model.input = "Help me open the profile panel"
    model.send()
    try await until { probe.inputs.count == 1 && !model.busy }
    let scope = try #require(model.activeGuidanceObservationScope)
    model.messages = [
      .init(role: "user", text: "Explain how a rocket works"),
      .init(role: "assistant", text: "This session is text-only and has no 3D viewer."),
    ]
    probe.emitMesh = emitMesh
    model.onSceneReady = { [weak model] in
      guard let model, let presentation = model.explanationPresentation else { return }
      // A host submission acknowledgement only; no native renderer is mounted.
      model.acknowledgeExplanationRenderSubmitted(presentation)
    }
    model.input = "Show it in 3D"
    model.send()
    try await until { probe.inputs.count == 2 && !model.busy }
    let input = probe.inputs[1]
    #expect(
      input.responsePolicy.route == .notebook && !input.responsePolicy.includesExistingNotebook)
    #expect(input.messages.map(\.text) == ["Explain how a rocket works", "Show it in 3D"])
    #expect(input.scene == nil && input.image == nil)
    #expect(!model.guidanceRuntime.isActive && model.activeGuidanceObservationScope == nil)
    let generation = model.taskGeneration
    model.receiveGuidanceObservation(scope: scope, event: event(.visualChange, sequence: 99))
    #expect(model.taskGeneration == generation && !model.guidanceRuntime.isActive)
    if emitMesh {
      #expect(model.error == nil)
      #expect(
        model.scene?.nodes.contains { $0.kind == .mesh && $0.spatial3D?.geometry != nil } == true)
      #expect(model.diagnosticEvents.contains { $0["event"] == "visual.accepted" })
    } else {
      #expect(model.error?.contains("without the requested 3D scene") == true)
      #expect(!model.diagnosticEvents.contains { $0["event"] == "visual.accepted" })
    }
    #expect(probe.frames.count == 1 && probe.nativeSpeechCalls == 0)
  }

  private func makeFixture(_ probe: ActiveGuidanceProbe) throws -> ActiveGuidanceFixture {
    let bytes = try jpeg()
    let voice = VoiceService(nativeSpeak: { _ in probe.nativeSpeechCalls += 1 }, nativeStop: {})
    let model = AppModel(
      acceptanceMode: true, voice: voice, observeGuidanceSceneChanges: false,
      guidanceForegroundPID: { probe.foregroundPID }, screenGuidanceEnabled: { true },
      automaticGuidanceCapture: { request, _, _, _ in
        let frameID = UUID()
        let candidate = ScreenGroundingCandidate(
          id: ScreenGrounding.candidateID(frameID: frameID, index: 0), source: .ocr,
          role: "text", label: "Public control", enabled: true, actionable: false,
          x: 0.1, y: 0.1, width: 0.2, height: 0.1)
        let frame = OpenCompanion.ScreenEvidence(
          frameID: frameID, revision: UInt64(probe.frames.count + 1),
          capturedAt: ProcessInfo.processInfo.systemUptime, displayID: 7,
          foregroundPID: probe.foregroundPID, foregroundName: "Authored public application",
          screenRect: .init(x: -800, y: -200, width: 800, height: 600), image: bytes,
          semanticText: "PUBLIC_FRAME_\(probe.frames.count + 1) " + candidate.id,
          groundingCandidates: [candidate], imageWidth: 32, imageHeight: 24)
        probe.requests.append(request)
        probe.frames.append(frame)
        return frame
      },
      responseStream: { input, onUnit, _ in
        let index = probe.inputs.count
        probe.inputs.append(input)
        probe.handlers.append(onUnit)
        defer { probe.finishedCalls += 1 }
        if probe.blockedCalls.contains(index) {
          let gate = ActiveGuidanceGate()
          probe.gates[index] = gate
          await gate.wait()
        }
        if input.responsePolicy.route == .screenGuidance {
          try await onUnit(
            ProviderUnit(
              type: "guidanceStatus", text: nil, title: nil, nodes: nil, removeIDs: nil,
              target: nil,
              guidance: .init(status: .uncertain, summary: "Public fresh frame inspected.")))
        } else if input.responsePolicy.allowsNotebook, probe.emitMesh {
          let scene = try JSONDecoder().decode(
            ProviderUnit.self,
            from: Data(
              ##"{"type":"scene","title":"Public 3D part","nodes":[{"id":"part","kind":"mesh","fill":"#4488CC","spatial3D":{"geometry":{"type":"sphere","radius":1,"segments":12}}}]}"##
                .utf8))
          try await onUnit(scene)
        } else {
          try await onUnit(textUnit("Public text answer without geometry."))
        }
      })
    // The authored responder is the only provider path. In particular, PTT
    // must not prewarm a real managed Codex process during these tests.
    model.providerMode = "OpenAI-compatible"
    model.configuration.speechEnabled = false
    return .init(model: model, voice: voice)
  }

  private func submit(
    _ text: String, authoredPTT: Bool, fixture: ActiveGuidanceFixture, probe: ActiveGuidanceProbe
  ) throws {
    if !authoredPTT {
      fixture.model.input = text
      fixture.model.send()
      return
    }
    let forward = fixture.voice.onInputState
    fixture.voice.onInputState = { snapshot in
      if snapshot.mode == .pushToTalk { probe.voiceID = snapshot.sessionID }
      forward?(snapshot)
    }
    defer { fixture.voice.onInputState = forward }
    fixture.model.beginPushToTalk()
    let id = try #require(probe.voiceID)
    let completion = try #require(fixture.voice.onInputCompletion)
    // Synchronous completion cancels the queued recognizer startup before any
    // suspension; this is callback routing, not actual hotkey/microphone proof.
    completion(.init(sessionID: id, mode: .pushToTalk, transcript: text, isFinal: true))
  }

  private func event(_ reason: GuidanceObservationEvent.Reason, sequence: UInt64)
    -> GuidanceObservationEvent
  {
    .init(reason: reason, timestamp: ProcessInfo.processInfo.systemUptime, sequence: sequence)
  }

  private func textUnit(_ text: String) -> ProviderUnit {
    .init(type: "text", text: text, title: nil, nodes: nil, removeIDs: nil, target: nil)
  }

  private func jpeg() throws -> Data {
    let context = try #require(
      CGContext(
        data: nil, width: 32, height: 24, bitsPerComponent: 8, bytesPerRow: 128,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(CGColor(red: 0.2, green: 0.3, blue: 0.7, alpha: 1))
    context.fill(.init(x: 0, y: 0, width: 32, height: 24))
    let image = try #require(context.makeImage())
    let bytes = NSMutableData()
    let destination = try #require(
      CGImageDestinationCreateWithData(bytes, "public.jpeg" as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, nil)
    #expect(CGImageDestinationFinalize(destination))
    return bytes as Data
  }

  private func until(_ ready: @MainActor () -> Bool) async throws {
    for _ in 0..<500 {
      if ready() { return }
      try await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("Authored active-guidance checkpoint did not settle")
    throw ActiveGuidanceTestFailure.checkpoint
  }
}

@MainActor private struct ActiveGuidanceFixture {
  let model: AppModel
  let voice: VoiceService
}

@MainActor private final class ActiveGuidanceProbe {
  var foregroundPID: pid_t = 424_242
  var frames: [OpenCompanion.ScreenEvidence] = []
  var requests: [ScreenGuidanceRequest] = []
  var inputs: [ReasoningTurnInput] = []
  var handlers: [@Sendable (ProviderUnit) async throws -> Void] = []
  var blockedCalls: Set<Int> = []
  var gates: [Int: ActiveGuidanceGate] = [:]
  var finishedCalls = 0
  var nativeSpeechCalls = 0
  var voiceID: UUID?
  var emitMesh = false
  func releaseAll() { for gate in gates.values { gate.release() } }
}

@MainActor private final class ActiveGuidanceGate {
  private var continuation: CheckedContinuation<Void, Never>?
  private(set) var entered = false
  func wait() async {
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

private enum ActiveGuidanceTestFailure: Error { case checkpoint }
