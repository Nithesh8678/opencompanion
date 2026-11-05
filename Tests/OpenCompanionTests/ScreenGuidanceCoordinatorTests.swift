import Foundation
import Testing

@testable import OpenCompanion

/// These exercise the production controller with an authored evidence identity,
/// a supplied foreground PID/clock, and no desktop observers or real captures.
@Suite @MainActor struct ScreenGuidanceCoordinatorTests {
  @Test func manualActionRetainsItsEvidenceButDoesNotContinueAutomatically() async throws {
    let fixture = ManualGuidanceFixture()
    let coordinator = fixture.coordinator()
    defer { coordinator.shutdown() }
    coordinator.accept(
      target: fixture.manualTarget(), evidence: fixture.evidence,
      generation: fixture.model.taskGeneration, request: fixture.request)

    let step = try #require(coordinator.manualStep)
    #expect(step.label == "Enter a name")
    #expect(step.instruction == "Type the requested name, then request a fresh check.")
    #expect(step.evidence == ScreenEvidenceIdentity(fixture.evidence))
    #expect(step.generation == fixture.model.taskGeneration && step.request == fixture.request)
    #expect(step.targetRect == CGRect(x: -200, y: 390, width: 160, height: 60))
    #expect(step.expiresAt == 145)
    await drainMainQueue()
    #expect(coordinator.manualStep?.id == step.id && fixture.receipts.isEmpty)
    #expect(
      !fixture.model.diagnosticEvents.contains { $0["event"] == "guidance.userClick.observed" })
  }

  @Test(arguments: [nil, false])
  func explanatoryManualMarksNeverOfferContinue(_ awaitUser: Bool?) {
    let fixture = ManualGuidanceFixture()
    let coordinator = fixture.coordinator()
    defer { coordinator.shutdown() }
    var target = fixture.manualTarget()
    target.awaitUser = awaitUser
    coordinator.accept(
      target: target, evidence: fixture.evidence, generation: fixture.model.taskGeneration,
      request: fixture.request)
    #expect(coordinator.manualStep == nil && fixture.receipts.isEmpty)
  }

  @Test func explicitContinueConsumesTheLeaseExactlyOnceAndReportsNoClick() async throws {
    let fixture = ManualGuidanceFixture()
    let gate = SuspendedManualGuidanceSettle()
    let coordinator = fixture.coordinator(settle: { try await gate.wait() })
    defer { coordinator.shutdown() }
    fixture.accept(on: coordinator)
    let step = try #require(coordinator.manualStep)

    coordinator.continueManualStep(id: step.id)
    coordinator.continueManualStep(id: step.id)
    #expect(coordinator.manualStep == nil && fixture.receipts.isEmpty)
    await gate.waitUntilStarted()
    #expect(await gate.count == 1)
    await gate.finish()
    await drainMainQueue()

    let receipt = try #require(fixture.receipts.first)
    #expect(fixture.receipts.count == 1)
    #expect(receipt.observation == .explicitContinue)
    #expect(receipt.request == fixture.request && receipt.evidence == step.evidence)
    #expect(receipt.generation == step.generation)
    coordinator.continueManualStep(id: step.id)
    await drainMainQueue()
    #expect(fixture.receipts.count == 1)
    #expect(
      !fixture.model.diagnosticEvents.contains { $0["event"] == "guidance.userClick.observed" })
  }

  @Test func secondaryMarksPreserveTheOriginalManualLease() throws {
    let fixture = ManualGuidanceFixture()
    let coordinator = fixture.coordinator()
    defer { coordinator.shutdown() }
    fixture.accept(on: coordinator)
    let first = try #require(coordinator.manualStep)
    var secondary = fixture.manualTarget()
    secondary.label = "Unrelated second field"
    secondary.x = 0.6
    coordinator.accept(
      target: secondary, evidence: fixture.evidence, generation: fixture.model.taskGeneration,
      request: fixture.request)
    secondary.awaitUser = false
    coordinator.accept(
      target: secondary, evidence: fixture.evidence, generation: fixture.model.taskGeneration,
      request: fixture.request)
    #expect(coordinator.manualStep == first)
  }

  @Test func secondaryManualActionCannotReplaceAnExistingClickPrimary() throws {
    let fixture = ManualGuidanceFixture()
    let coordinator = fixture.coordinator()
    defer { coordinator.shutdown() }
    fixture.accept(on: coordinator)
    let oldManualID = try #require(coordinator.manualStep?.id)
    var click = fixture.manualTarget()
    click.advanceOn = "click"
    click.awaitUser = nil
    coordinator.accept(
      target: click, evidence: fixture.evidence, generation: fixture.model.taskGeneration,
      request: fixture.request)
    fixture.accept(on: coordinator)
    #expect(coordinator.manualStep == nil)
    coordinator.continueManualStep(id: oldManualID)
    #expect(fixture.receipts.isEmpty)
    #expect(
      fixture.model.diagnosticEvents.filter { $0["event"] == "guidance.clickObservation.armed" }
        .count == 1)
  }

  @Test func staleButtonIDCannotConsumeANewRequestLease() async throws {
    let fixture = ManualGuidanceFixture()
    let coordinator = fixture.coordinator()
    defer { coordinator.shutdown() }
    fixture.accept(on: coordinator)
    let oldID = try #require(coordinator.manualStep?.id)
    fixture.request = ScreenGuidanceRequest(prompt: "A different public task", expires: 280)
    fixture.accept(on: coordinator)
    let currentID = try #require(coordinator.manualStep?.id)
    #expect(currentID != oldID)
    coordinator.continueManualStep(id: oldID)
    #expect(coordinator.manualStep?.id == currentID)
    coordinator.continueManualStep(id: currentID)
    await drainMainQueue()
    #expect(fixture.receipts.count == 1 && fixture.receipts.first?.request == fixture.request)
  }

  @Test(arguments: ["generation", "evidence", "foreground", "deadline", "cancel", "shutdown"])
  func lostOwnershipDuringSettleNeverRequestsAnotherCapture(_ reason: String) async throws {
    let fixture = ManualGuidanceFixture()
    let gate = SuspendedManualGuidanceSettle()
    let coordinator = fixture.coordinator(settle: { try await gate.wait() })
    defer { coordinator.shutdown() }
    fixture.accept(on: coordinator)
    let id = try #require(coordinator.manualStep?.id)
    coordinator.continueManualStep(id: id)
    await gate.waitUntilStarted()
    switch reason {
    case "generation": fixture.model.stop()
    case "evidence": fixture.model.evidence?.frameID = UUID()
    case "foreground": fixture.foregroundPID = 424_243
    case "deadline": fixture.time = 145
    case "cancel": coordinator.cancel()
    case "shutdown": coordinator.shutdown()
    default: Issue.record("Unknown authored invalidation")
    }
    await gate.finish()
    await drainMainQueue()
    #expect(fixture.receipts.isEmpty && coordinator.manualStep == nil)
  }

  @Test func aCancelledOldSettleCannotClearANewerManualLease() async throws {
    let fixture = ManualGuidanceFixture()
    let gate = SuspendedManualGuidanceSettle()
    let coordinator = fixture.coordinator(settle: { try await gate.wait() })
    defer { coordinator.shutdown() }
    fixture.accept(on: coordinator)
    coordinator.continueManualStep(id: try #require(coordinator.manualStep?.id))
    await gate.waitUntilStarted()
    fixture.request = ScreenGuidanceRequest(prompt: "A newer public task", expires: 280)
    fixture.accept(on: coordinator)
    let newerID = try #require(coordinator.manualStep?.id)
    await gate.finish()
    await drainMainQueue()
    #expect(coordinator.manualStep?.id == newerID && fixture.receipts.isEmpty)
  }

  @Test func expiredManualLeaseCannotBeConsumedEvenBeforeItsTimerRuns() throws {
    let fixture = ManualGuidanceFixture()
    let coordinator = fixture.coordinator()
    defer { coordinator.shutdown() }
    fixture.accept(on: coordinator)
    let id = try #require(coordinator.manualStep?.id)
    fixture.time = 145
    coordinator.continueManualStep(id: id)
    #expect(coordinator.manualStep == nil && fixture.receipts.isEmpty)
  }

  @Test(arguments: [-1, 5, 6, Int.max])
  func exhaustedOrInvalidStepBudgetCannotOfferManualContinue(_ step: Int) {
    let fixture = ManualGuidanceFixture()
    let coordinator = fixture.coordinator()
    defer { coordinator.shutdown() }
    fixture.request = ScreenGuidanceRequest(prompt: "Public task", step: step, expires: 280)
    fixture.accept(on: coordinator)
    #expect(coordinator.manualStep == nil)
  }

  @Test func finalContinuableStepAndShorterRequestDeadlineAreRespected() throws {
    let fixture = ManualGuidanceFixture()
    let coordinator = fixture.coordinator()
    defer { coordinator.shutdown() }
    fixture.request = ScreenGuidanceRequest(prompt: "Public task", step: 4, expires: 110)
    fixture.accept(on: coordinator)
    let id = try #require(coordinator.manualStep?.id)
    #expect(coordinator.manualStep?.expiresAt == 110)
    fixture.time = 110
    coordinator.continueManualStep(id: id)
    #expect(coordinator.manualStep == nil && fixture.receipts.isEmpty)
  }

  @Test func voiceHandoffConsumesTheOwnedLeaseWithoutStartingARequest() async throws {
    let fixture = ManualGuidanceFixture()
    let coordinator = fixture.coordinator()
    defer { coordinator.shutdown() }
    fixture.accept(on: coordinator)
    let original = try #require(coordinator.manualStep)
    let taken = try #require(coordinator.takeManualStepForVoice())
    #expect(taken == original && coordinator.manualStep == nil)
    #expect(coordinator.takeManualStepForVoice() == nil)
    coordinator.continueManualStep(id: original.id)
    await drainMainQueue()
    #expect(fixture.receipts.isEmpty)

    // Starting voice input deliberately advances the model generation. Only a
    // value explicitly bound to that new generation can use the retained lease.
    let previousGeneration = fixture.model.taskGeneration
    fixture.model.stop()
    let continuation = ManualGuidanceVoiceContinuation(
      step: taken, inputGeneration: fixture.model.taskGeneration)
    #expect(
      continuation.nextRequest(
        transcript: "Continue.", generation: previousGeneration, evidence: fixture.model.evidence,
        foregroundPID: fixture.foregroundPID, now: 101) == nil)
    #expect(
      continuation.nextRequest(
        transcript: "Continue.", generation: fixture.model.taskGeneration,
        evidence: fixture.model.evidence, foregroundPID: fixture.foregroundPID, now: 101)?.step == 1
    )
  }

  @Test func queuedExplicitContinueCannotAlsoBeTakenForVoice() async throws {
    let fixture = ManualGuidanceFixture()
    let gate = SuspendedManualGuidanceSettle()
    let coordinator = fixture.coordinator(settle: { try await gate.wait() })
    defer { coordinator.shutdown() }
    fixture.accept(on: coordinator)
    coordinator.continueManualStep(id: try #require(coordinator.manualStep?.id))
    #expect(coordinator.takeManualStepForVoice() == nil)
    await gate.waitUntilStarted()
    await gate.finish()
    await drainMainQueue()
    #expect(fixture.receipts.count == 1)
  }

  @Test(arguments: ["generation", "foreground", "deadline", "evidence"])
  func voiceCannotTakeAnUnownedManualLease(_ invalidation: String) {
    let fixture = ManualGuidanceFixture()
    let coordinator = fixture.coordinator()
    defer { coordinator.shutdown() }
    fixture.accept(on: coordinator)
    switch invalidation {
    case "generation": fixture.model.stop()
    case "foreground": fixture.foregroundPID = 1
    case "deadline": fixture.time = 145
    case "evidence": fixture.model.evidence = nil
    default: Issue.record("Unknown authored invalidation")
    }
    #expect(coordinator.takeManualStepForVoice() == nil)
    #expect(coordinator.manualStep == nil && fixture.receipts.isEmpty)
  }

  @Test(arguments: [
    "Continue", "  CONTINUE.  ", "please continue", "Continue please!", "done", "all done",
    "I'm done.", "I’m done!", "I am done", "next step", "the next step", "Next step please?",
    "please continue to the next step",
  ])
  func exactSpokenCommandsPreserveOriginalGoalAndRemainingBudget(_ transcript: String) throws {
    let fixture = ManualGuidanceFixture()
    fixture.request = ScreenGuidanceRequest(
      prompt: "Rename this authored item", step: 3, expires: 230, speakAloud: false)
    let coordinator = fixture.coordinator()
    defer { coordinator.shutdown() }
    fixture.accept(on: coordinator)
    let step = try #require(coordinator.takeManualStepForVoice())
    let continuation = ManualGuidanceVoiceContinuation(step: step, inputGeneration: 42)
    let next = try #require(
      continuation.nextRequest(
        transcript: transcript, generation: 42, evidence: fixture.evidence,
        foregroundPID: fixture.foregroundPID, now: 110))
    #expect(ManualGuidanceVoiceContinuation.isContinueCommand(transcript))
    #expect(next.id == fixture.request.id && next.prompt == fixture.request.prompt)
    #expect(next.step == 4 && next.expires == fixture.request.expires && !next.speakAloud)
  }

  @Test(arguments: [
    "", " ", "do not continue", "don't continue", "not done", "I am not done", "undo",
    "continue explaining", "continue and delete everything", "what does continue mean?",
    "say continue", "\"continue\"", "‘continue’", "`continue`", "done with a different task",
    "next task", "not the next step", "stop, then continue", "继续",
    "next step after changing accounts",
    String(repeating: " ", count: 257) + "continue",
  ])
  func substringsNegationQuotesAndUnboundedInputAreNeverContinuationCommands(_ transcript: String) {
    #expect(!ManualGuidanceVoiceContinuation.isContinueCommand(transcript))
  }

  @Test(arguments: [
    "generation", "missingFrame", "frameID", "revision", "display", "window", "sourceRect",
    "foreground", "noForeground", "zeroForeground", "expired", "futureClock", "nonfiniteClock",
  ])
  func spokenContinuationRequiresTheExactRetainedSourceAndValidClock(_ invalidation: String) throws
  {
    let fixture = ManualGuidanceFixture()
    let coordinator = fixture.coordinator()
    defer { coordinator.shutdown() }
    fixture.accept(on: coordinator)
    let step = try #require(coordinator.takeManualStepForVoice())
    let continuation = ManualGuidanceVoiceContinuation(step: step, inputGeneration: 42)
    var generation: UInt64 = 42
    var evidence: ScreenEvidence? = fixture.evidence
    var foreground = fixture.foregroundPID
    var now: TimeInterval = 101
    switch invalidation {
    case "generation": generation = 43
    case "missingFrame": evidence = nil
    case "frameID": evidence?.frameID = UUID()
    case "revision": evidence?.revision += 1
    case "display": evidence?.displayID = 2
    case "window": evidence?.windowID = 99
    case "sourceRect": evidence?.screenRect.origin.x += 1
    case "foreground": foreground = 1
    case "noForeground": foreground = nil
    case "zeroForeground": foreground = 0
    case "expired": now = 145
    case "futureClock": now = 99
    case "nonfiniteClock": now = .nan
    default: Issue.record("Unknown authored invalidation")
    }
    #expect(
      continuation.nextRequest(
        transcript: "continue", generation: generation, evidence: evidence,
        foregroundPID: foreground, now: now) == nil)
  }

  @Test func copiedHandoffCannotExtendItsLeaseOrSixStepBudget() throws {
    let fixture = ManualGuidanceFixture()
    let coordinator = fixture.coordinator()
    defer { coordinator.shutdown() }
    fixture.accept(on: coordinator)
    let step = try #require(coordinator.takeManualStepForVoice())
    for invalid in [
      (expiresAt: Double.nan, request: fixture.request),
      (expiresAt: 281.0, request: fixture.request),
      (
        expiresAt: 145.0,
        request: ScreenGuidanceRequest(prompt: "Public task", step: 5, expires: 280)
      ),
      (
        expiresAt: 145.0,
        request: ScreenGuidanceRequest(prompt: "Public task", step: 0, expires: 100)
      ),
    ] {
      let copied = ManualGuidanceStep(
        id: step.id, label: step.label, instruction: step.instruction, evidence: step.evidence,
        generation: step.generation, request: invalid.request, targetRect: step.targetRect,
        expiresAt: invalid.expiresAt)
      let continuation = ManualGuidanceVoiceContinuation(step: copied, inputGeneration: 42)
      #expect(
        continuation.nextRequest(
          transcript: "continue", generation: 42, evidence: fixture.evidence,
          foregroundPID: fixture.foregroundPID, now: 101) == nil)
    }
  }

  private func drainMainQueue() async {
    await withCheckedContinuation { continuation in
      DispatchQueue.main.async { continuation.resume() }
    }
    await Task.yield()
  }
}

@MainActor private final class ManualGuidanceFixture {
  struct Receipt {
    let request: ScreenGuidanceRequest
    let evidence: ScreenEvidenceIdentity
    let generation: UInt64
    let observation: ScreenGuidanceContinuationObservation
  }
  var time: TimeInterval = 100
  var foregroundPID: pid_t? = 424_242
  let model = AppModel(acceptanceMode: true)
  var evidence = ScreenEvidence(
    frameID: UUID(), revision: 1, capturedAt: 99, displayID: 1, foregroundPID: 424_242,
    foregroundName: "Authored public fixture",
    screenRect: CGRect(x: -400, y: 0, width: 800, height: 600),
    image: Data(), semanticText: "Public fixture; no pixels captured")
  var request = ScreenGuidanceRequest(prompt: "Rename this item", expires: 280)
  var receipts: [Receipt] = []

  init() { model.evidence = evidence }

  func coordinator(
    settle: @escaping @MainActor () async throws -> Void = {}
  ) -> ScreenGuidanceCoordinator {
    ScreenGuidanceCoordinator(
      model: model, observeInput: false, now: { self.time },
      foregroundPID: { self.foregroundPID }, settle: settle,
      onContinue: { request, evidence, generation, observation in
        self.receipts.append(
          Receipt(
            request: request, evidence: evidence, generation: generation, observation: observation))
      })
  }

  func manualTarget() -> ProviderTarget {
    ProviderTarget(
      x: 0.25, y: 0.25, width: 0.2, height: 0.1,
      instruction: "Type the requested name, then request a fresh check.", label: "Enter a name",
      advanceOn: "manual", awaitUser: true)
  }

  func accept(on coordinator: ScreenGuidanceCoordinator) {
    coordinator.accept(
      target: manualTarget(), evidence: evidence, generation: model.taskGeneration, request: request
    )
  }
}

private actor SuspendedManualGuidanceSettle {
  private var pending: CheckedContinuation<Void, any Error>?
  private var started: [CheckedContinuation<Void, Never>] = []
  private(set) var count = 0

  func wait() async throws {
    try await withCheckedThrowingContinuation { continuation in
      pending = continuation
      count += 1
      for waiter in started { waiter.resume() }
      started.removeAll()
    }
  }

  func waitUntilStarted() async {
    if pending != nil { return }
    await withCheckedContinuation { started.append($0) }
  }

  func finish() {
    pending?.resume()
    pending = nil
  }
}
