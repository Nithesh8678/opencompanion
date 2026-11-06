import CompanionCore
import CoreGraphics
import Foundation
import ImageIO
import Testing

@testable import OpenCompanion

/// Directly call preparation with an injected capture result. No send task,
/// provider, screen capture, window, microphone or desktop input is started.
@Suite @MainActor struct AppModelSelectedGuidanceRefreshTests {
  @Test(arguments: ["file", "memory", "strokes"])
  func aChangedFreshFrameReplacesTheSelectedImageAndPreservesIndependentContext(
    _ contextKind: String
  ) async throws {
    let original = try evidence(color: .init(red: 0.8, green: 0.1, blue: 0.1, alpha: 1))
    let fresh = try refreshed(original, color: .init(red: 0.1, green: 0.3, blue: 0.9, alpha: 1))
    let model = preparedModel()
    defer { model.stop() }
    let notebook = BuiltInLessons.lever()
    model.scene = notebook
    model.section = "Notebook"
    model.input = "Keep this unsent draft"
    model.selectedContext = "Explicitly selected public \(contextKind) content"
    model.contextTitle = "Public \(contextKind) attachment"
    let token = model.capturePublicationRevision
    let published = model.publishSelectedCapture(
      original, token: token, strokes: contextKind == "strokes" ? "[[0.2,0.4],[0.3,0.5]]" : "")
    #expect(published)
    let selectedContext = model.selectedContext
    let contextTitle = model.contextTitle
    let generation = model.taskGeneration
    var preparations = 0
    model.onPrepareScreenGuidance = { actualGeneration, pid in
      #expect(actualGeneration == generation && pid == original.foregroundPID)
      preparations += 1
    }
    var captures = 0
    let result = try await model.prepareSelectedGuidanceEvidence(
      ScreenEvidenceIdentity(original), generation: generation, captureToken: token,
      refresh: { source in
        captures += 1
        #expect(ScreenEvidenceIdentity(source) == ScreenEvidenceIdentity(original))
        #expect(source.image == original.image)
        var captured = fresh
        captured.capturedAt = ProcessInfo.processInfo.systemUptime
        return captured
      })
    #expect(preparations == 1 && captures == 1)
    #expect(result.image != original.image && result.semanticText != original.semanticText)
    #expect(ScreenEvidenceIdentity(result) == ScreenEvidenceIdentity(fresh))
    #expect(ScreenEvidenceIdentity(fresh).matches(model.evidence))
    #expect(
      model.evidence?.image == fresh.image && model.evidence?.semanticText == fresh.semanticText)
    #expect(model.evidence?.groundingCandidates == fresh.groundingCandidates)
    #expect(model.guidanceSceneScope?.sourceRect == original.screenRect)
    #expect(model.guidanceSceneScope?.foregroundPID == original.foregroundPID)
    #expect(model.selectedContext == selectedContext && model.contextTitle == contextTitle)
    #expect(
      model.input == "Keep this unsent draft" && model.scene == notebook
        && model.section == "Notebook")
    #expect(model.taskGeneration == generation && model.capturePublicationRevision == token)
    let plan = ResponseInputPlan.resolve(
      policy: model.responsePolicy, voiceOnly: false, selectedContext: model.selectedContext,
      evidence: result, explicitManualEvidence: ScreenEvidenceIdentity(result))
    #expect(!plan.requiresFreshGuidanceCapture && plan.image == fresh.image)
    #expect(
      plan.context == fresh.semanticText && plan.evidenceIdentity == ScreenEvidenceIdentity(fresh))
    expectNoExternalWork(model)
  }

  @Test(arguments: [false, true])
  func stopOrASceneChangeDuringPreparationPreventsEvenTheInjectedCapture(
    _ sceneChange: Bool
  ) async throws {
    let original = try evidence()
    let fresh = try refreshed(original)
    let model = preparedModel()
    defer { model.stop() }
    let token = model.capturePublicationRevision
    let published = model.publishSelectedCapture(original, token: token)
    #expect(published)
    let generation = model.taskGeneration
    model.onPrepareScreenGuidance = { [weak model] _, _ in
      guard let model else { throw CancellationError() }
      if sceneChange {
        guard let scope = model.guidanceSceneScope else { throw FixtureFailure.missingScope }
        // Simulates a recorded unrelated activation, even if the fixture PID
        // has returned before this async preparation would otherwise finish.
        model.guidanceSceneDidChange(scope: scope, reason: .foregroundChanged)
      } else {
        model.stop()
      }
    }
    var captures = 0
    await #expect(throws: CancellationError.self) {
      try await model.prepareSelectedGuidanceEvidence(
        ScreenEvidenceIdentity(original), generation: generation, captureToken: token,
        refresh: { _ in
          captures += 1
          return fresh
        })
    }
    #expect(captures == 0 && model.guidanceSceneScope == nil && model.taskGeneration > generation)
    if sceneChange {
      #expect(model.evidence == nil)
    } else {
      #expect(ScreenEvidenceIdentity(original).matches(model.evidence))
    }
    expectNoExternalWork(model)
  }

  @Test(arguments: [false, true])
  func stopOrANewSelectionWhileCaptureIsSuspendedPreventsLatePublication(
    _ newSelection: Bool
  ) async throws {
    let original = try evidence()
    let fresh = try refreshed(original)
    let replacement = try evidence(color: .init(red: 0.1, green: 0.7, blue: 0.2, alpha: 1))
    let model = preparedModel()
    defer { model.stop() }
    let token = model.capturePublicationRevision
    let published = model.publishSelectedCapture(original, token: token)
    #expect(published)
    let generation = model.taskGeneration
    let barrier = SelectedRefreshBarrier()
    var captures = 0
    let pending = Task { @MainActor in
      defer { barrier.finishedBeforeEntry() }
      return try await model.prepareSelectedGuidanceEvidence(
        ScreenEvidenceIdentity(original), generation: generation, captureToken: token,
        refresh: { _ in
          captures += 1
          await barrier.suspend()
          return fresh
        })
    }
    guard await barrier.waitForEntry() else {
      Issue.record("Preparation exited before reaching the injected suspended capture.")
      _ = try? await pending.value
      return
    }
    if newSelection {
      model.clearContext()
      let replaced = model.publishSelectedCapture(
        replacement, token: model.capturePublicationRevision)
      #expect(replaced)
    } else {
      model.stop()
    }
    barrier.release()
    await #expect(throws: CancellationError.self) { try await pending.value }
    #expect(captures == 1)
    let expected = newSelection ? replacement : original
    #expect(ScreenEvidenceIdentity(expected).matches(model.evidence))
    #expect(!ScreenEvidenceIdentity(fresh).matches(model.evidence))
    expectNoExternalWork(model)
  }

  @Test(arguments: [false, true])
  func malformedHeaderOrBroadenedScopeCannotReplaceTheSelectedFrame(
    _ invalidHeader: Bool
  ) async throws {
    let original = try evidence()
    var fresh = try refreshed(original)
    if invalidHeader {
      fresh.image = Data([0, 1, 2])
    } else {
      fresh.windowID = nil
    }
    let rejected = fresh
    let model = preparedModel()
    defer { model.stop() }
    model.selectedContext = "Keep explicitly selected public memory"
    let token = model.capturePublicationRevision
    let published = model.publishSelectedCapture(original, token: token)
    #expect(published)
    let generation = model.taskGeneration
    var captures = 0
    await #expect(throws: ProviderError.self) {
      try await model.prepareSelectedGuidanceEvidence(
        ScreenEvidenceIdentity(original), generation: generation, captureToken: token,
        refresh: { _ in
          captures += 1
          return rejected
        })
    }
    #expect(captures == 1 && ScreenEvidenceIdentity(original).matches(model.evidence))
    #expect(model.evidence?.image == original.image)
    #expect(model.selectedContext == "Keep explicitly selected public memory")
    #expect(
      !model.diagnosticEvents.contains {
        $0["event"] == "guidance.selectedCapture.refresh.accepted"
      })
    expectNoExternalWork(model)
  }

  @Test func anOrdinaryConversationPayloadKeepsItsExplicitAttachmentWithoutRequestingRefresh()
    throws
  {
    let original = try evidence()
    let conversation = ResponsePolicy.resolve(
      text: "Summarize the selected image in text only", screenGuidanceEnabled: true)
    #expect(conversation.route == .conversation)
    let plan = ResponseInputPlan.resolve(
      policy: conversation, voiceOnly: false, selectedContext: "Explicit public file\n",
      evidence: original, explicitManualEvidence: ScreenEvidenceIdentity(original))
    // This checks the production payload mapping, not an executed send. A
    // normal attachment question does not enter screen-guidance preparation.
    #expect(!plan.requiresFreshGuidanceCapture && plan.image == original.image)
    #expect(plan.evidenceIdentity == ScreenEvidenceIdentity(original))
    #expect(plan.context == "Explicit public file\n" + original.semanticText)
  }

  private func preparedModel() -> AppModel {
    let model = AppModel(
      acceptanceMode: true, guidanceForegroundPID: { 424_242 }, screenGuidanceEnabled: { true })
    model.configuration.speechEnabled = false
    model.configureResponseOutput(
      .resolve(
        text: "Help with the current screen", screenGuidanceEnabled: true, explicitGuidance: true))
    model.busy = true
    model.onPrepareScreenGuidance = { _, _ in }
    return model
  }

  private func evidence(color: CGColor = .init(red: 0.6, green: 0.2, blue: 0.2, alpha: 1)) throws
    -> OpenCompanion.ScreenEvidence
  {
    .init(
      frameID: UUID(), revision: 7, capturedAt: ProcessInfo.processInfo.systemUptime - 1,
      displayID: 1, foregroundPID: 424_242, foregroundName: "Authored public fixture",
      screenRect: .init(x: -600, y: -200, width: 320, height: 240), windowID: 42,
      image: try jpeg(color), semanticText: "Old authored label",
      groundingCandidates: [], imageWidth: 32, imageHeight: 24)
  }

  private func refreshed(
    _ original: OpenCompanion.ScreenEvidence,
    color: CGColor = .init(red: 0.1, green: 0.2, blue: 0.8, alpha: 1)
  ) throws -> OpenCompanion.ScreenEvidence {
    var fresh = original
    fresh.frameID = UUID()
    fresh.revision += 1
    fresh.capturedAt = ProcessInfo.processInfo.systemUptime
    fresh.image = try jpeg(color)
    fresh.semanticText = "New authored label after screen change"
    fresh.groundingCandidates = [
      .init(
        id: ScreenGrounding.candidateID(frameID: fresh.frameID, index: 0), source: .accessibility,
        role: "AXButton", label: "New public control", enabled: true, actionable: true,
        x: 0.2, y: 0.2, width: 0.1, height: 0.1)
    ]
    return fresh
  }

  private func jpeg(_ color: CGColor) throws -> Data {
    guard
      let context = CGContext(
        data: nil, width: 32, height: 24, bitsPerComponent: 8, bytesPerRow: 32 * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { throw FixtureFailure.image }
    context.setFillColor(color)
    context.fill(.init(x: 0, y: 0, width: 32, height: 24))
    guard let image = context.makeImage() else { throw FixtureFailure.image }
    let data = NSMutableData()
    guard
      let destination = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil)
    else {
      throw FixtureFailure.image
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { throw FixtureFailure.image }
    return data as Data
  }

  private func expectNoExternalWork(_ model: AppModel) {
    #expect(
      !model.diagnosticEvents.contains {
        ["guidance.capture.started", "guidance.capture.accepted", "generation.completed"].contains(
          $0["event"] ?? "")
      })
    #expect(model.messages.isEmpty && !model.voice.hasPendingSpeech)
  }

  private enum FixtureFailure: Error { case image, missingScope }
}

@MainActor private final class SelectedRefreshBarrier {
  private var entered = false
  private var finished = false
  private var capture: CheckedContinuation<Void, Never>?
  private var waitingForEntry: CheckedContinuation<Bool, Never>?

  func suspend() async {
    await withCheckedContinuation { continuation in
      capture = continuation
      entered = true
      waitingForEntry?.resume(returning: true)
      waitingForEntry = nil
    }
  }

  func waitForEntry() async -> Bool {
    if entered { return true }
    if finished { return false }
    return await withCheckedContinuation { waitingForEntry = $0 }
  }

  func finishedBeforeEntry() {
    finished = true
    guard !entered else { return }
    waitingForEntry?.resume(returning: false)
    waitingForEntry = nil
  }

  func release() {
    capture?.resume()
    capture = nil
  }
}
