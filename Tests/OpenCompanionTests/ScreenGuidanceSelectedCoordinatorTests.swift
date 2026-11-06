import CoreGraphics
import Foundation
import Testing

@testable import OpenCompanion

/// Production coordinator and selection publication, with authored metadata,
/// an injected clock/PID, and no input observers, capture, provider or windows.
@Suite @MainActor struct ScreenGuidanceSelectedCoordinatorTests {
  @Test func anOwnedSelectedManualLeaseContinuesExactlyOnceWithItsScope() async throws {
    let fixture = try SelectedCoordinatorFixture()
    let coordinator = fixture.coordinator()
    defer {
      coordinator.shutdown()
      fixture.model.stop()
    }
    fixture.accept(on: coordinator)
    let step = try #require(coordinator.manualStep)
    #expect(step.request.selectedScope == fixture.scope)
    #expect(step.evidence == ScreenEvidenceIdentity(fixture.evidence))
    #expect(step.generation == fixture.model.taskGeneration && step.expiresAt == 145)
    #expect(step.targetRect == CGRect(x: -520, y: -44, width: 64, height: 24))
    await drainMainQueue()
    #expect(coordinator.manualStep == step && fixture.receipts.isEmpty)

    coordinator.continueManualStep(id: step.id)
    coordinator.continueManualStep(id: step.id)
    #expect(coordinator.manualStep == nil)
    await drainMainQueue()
    let receipt = try #require(fixture.receipts.first)
    #expect(fixture.receipts.count == 1)
    #expect(receipt.request == fixture.request && receipt.request.selectedScope == fixture.scope)
    #expect(receipt.evidence == step.evidence && receipt.generation == step.generation)
    #expect(receipt.observation == .explicitContinue)
    coordinator.continueManualStep(id: step.id)
    await drainMainQueue()
    #expect(fixture.receipts.count == 1)
    #expect(
      !fixture.model.diagnosticEvents.contains { $0["event"] == "guidance.userClick.observed" })
  }

  @Test func anotherSelectionIDCannotAdmitAnOtherwiseIdenticalFrame() throws {
    let fixture = try SelectedCoordinatorFixture()
    let coordinator = fixture.coordinator()
    defer {
      coordinator.shutdown()
      fixture.model.stop()
    }
    let otherScope = try ScreenGuidanceCaptureScope(
      evidence: fixture.evidence, selectionID: UUID())
    #expect(otherScope.matches(fixture.evidence) && otherScope != fixture.scope)
    fixture.accept(on: coordinator, scope: otherScope)
    #expect(coordinator.manualStep == nil && fixture.receipts.isEmpty)
    #expect(
      !fixture.model.diagnosticEvents.contains {
        $0["event"] == "guidance.manualContinuation.armed"
      })
  }

  @Test(arguments: ["foreground", "display", "window", "origin", "extent"])
  func aRequestCannotAdmitATargetOutsideItsSelectedSource(_ mismatch: String) throws {
    let fixture = try SelectedCoordinatorFixture()
    let coordinator = fixture.coordinator()
    defer {
      coordinator.shutdown()
      fixture.model.stop()
    }
    var otherSource = fixture.evidence
    switch mismatch {
    case "foreground": otherSource.foregroundPID += 1
    case "display": otherSource.displayID += 1
    case "window": otherSource.windowID = nil
    case "origin": otherSource.screenRect.origin.x += 1
    case "extent": otherSource.screenRect.size.width += 1
    default: Issue.record("Unknown authored scope mismatch")
    }
    let otherScope = try ScreenGuidanceCaptureScope(
      evidence: otherSource, selectionID: fixture.scope.selectionID)
    #expect(!otherScope.matches(fixture.evidence))
    fixture.accept(on: coordinator, scope: otherScope)
    #expect(coordinator.manualStep == nil && fixture.receipts.isEmpty)
  }

  @Test func explicitReselectionOfTheSameFrameRevokesTheOldContinueImmediately() async throws {
    let fixture = try SelectedCoordinatorFixture()
    let coordinator = fixture.coordinator()
    defer {
      coordinator.shutdown()
      fixture.model.stop()
    }
    fixture.accept(on: coordinator)
    let previousStep = try #require(coordinator.manualStep)
    let generation = fixture.model.taskGeneration
    let identity = ScreenEvidenceIdentity(fixture.evidence)

    // Reusing every frame field still represents an explicit new selection.
    // Exercise owns() before scheduled objectWillChange validation can run.
    let published = fixture.model.publishSelectedCapture(
      fixture.evidence, token: fixture.model.capturePublicationRevision)
    #expect(published)
    let currentScope = try fixture.model.currentSelectedGuidanceScope()
    #expect(identity.matches(fixture.model.evidence))
    #expect(currentScope.matches(fixture.evidence))
    #expect(currentScope.selectionID != fixture.scope.selectionID)
    #expect(fixture.model.taskGeneration == generation)
    coordinator.continueManualStep(id: previousStep.id)
    #expect(coordinator.manualStep == nil && fixture.receipts.isEmpty)
    #expect(
      !fixture.model.diagnosticEvents.contains {
        $0["event"] == "guidance.manualContinue.requested"
      })
    await drainMainQueue()
    #expect(fixture.receipts.isEmpty)

    // The revoked request cannot rearm, but the current explicit selection can.
    fixture.accept(on: coordinator)
    #expect(coordinator.manualStep == nil)
    fixture.accept(on: coordinator, scope: currentScope)
    let currentStep = try #require(coordinator.manualStep)
    #expect(currentStep.id != previousStep.id)
    #expect(currentStep.request.selectedScope == currentScope)
    coordinator.continueManualStep(id: previousStep.id)
    #expect(coordinator.manualStep?.id == currentStep.id)
    coordinator.continueManualStep(id: currentStep.id)
    await drainMainQueue()
    #expect(fixture.receipts.count == 1)
    #expect(fixture.receipts.first?.request.selectedScope == currentScope)
  }

  private func drainMainQueue() async {
    await withCheckedContinuation { continuation in
      DispatchQueue.main.async { continuation.resume() }
    }
    await Task.yield()
  }
}

@MainActor private final class SelectedCoordinatorFixture {
  struct Receipt {
    let request: ScreenGuidanceRequest
    let evidence: ScreenEvidenceIdentity
    let generation: UInt64
    let observation: ScreenGuidanceContinuationObservation
  }

  let model: AppModel
  let evidence: OpenCompanion.ScreenEvidence
  let scope: ScreenGuidanceCaptureScope
  let request: ScreenGuidanceRequest
  var receipts: [Receipt] = []

  init() throws {
    let model = AppModel(
      acceptanceMode: true, guidanceForegroundPID: { 424_242 }, screenGuidanceEnabled: { true })
    let evidence = OpenCompanion.ScreenEvidence(
      frameID: UUID(), revision: 1, capturedAt: 99, displayID: 7, foregroundPID: 424_242,
      foregroundName: "Authored public fixture",
      screenRect: CGRect(x: -600, y: -200, width: 320, height: 240), windowID: 42,
      image: Data(), semanticText: "Authored metadata; no pixels captured")
    guard model.publishSelectedCapture(evidence, token: model.capturePublicationRevision) else {
      throw FixtureFailure.publicationRefused
    }
    let scope = try model.currentSelectedGuidanceScope()
    self.model = model
    self.evidence = evidence
    self.scope = scope
    request = ScreenGuidanceRequest(
      prompt: "Complete the public selected-window task", expires: 280, speakAloud: false,
      selectedScope: scope)
  }

  func coordinator() -> ScreenGuidanceCoordinator {
    ScreenGuidanceCoordinator(
      model: model, observeInput: false, now: { 100 }, foregroundPID: { 424_242 }, settle: {},
      windowVisibility: { _, _ in true },
      onContinue: { [weak self] request, evidence, generation, observation in
        self?.receipts.append(
          Receipt(
            request: request, evidence: evidence, generation: generation,
            observation: observation))
      })
  }

  func accept(on coordinator: ScreenGuidanceCoordinator, scope: ScreenGuidanceCaptureScope? = nil) {
    let scopedRequest = ScreenGuidanceRequest(
      id: request.id, prompt: request.prompt, step: request.step, expires: request.expires,
      speakAloud: request.speakAloud, selectedScope: scope ?? self.scope)
    coordinator.accept(
      target: .init(
        x: 0.25, y: 0.25, width: 0.2, height: 0.1,
        instruction: "Enter the requested public value, then Continue.", label: "Public field",
        advanceOn: "manual", awaitUser: true),
      evidence: evidence, generation: model.taskGeneration, request: scopedRequest)
  }

  private enum FixtureFailure: Error { case publicationRefused }
}
