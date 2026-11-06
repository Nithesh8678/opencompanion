import CompanionStore
import CoreGraphics
import Foundation
import ImageIO
import Testing

@testable import OpenCompanion

/// The real AppModel wrapper consumes authored bitmap/evidence identities.
/// No provider turn, screen capture, native target window, input or speech is
/// started. A recorded primary is metadata, not proof of retained native pixels.
@Suite @MainActor struct AppModelGuidanceAssessmentTests {
  @Test func aVerifiedRefreshOmitsOldAssessmentWithoutRebindingOrPublishingIt() async throws {
    let (source, binding) = try await refreshedBinding(presentPrimary: true)
    let model = configuredModel()
    defer { model.stop() }
    model.evidence = binding.current
    let current = ScreenEvidenceIdentity(binding.current)
    let generation = model.taskGeneration
    let publication = model.capturePublicationRevision

    try await model.acceptProviderUnit(
      status(), generation: generation, expectedEvidence: ScreenEvidenceIdentity(source),
      guidanceBinding: binding, captureToken: publication)

    #expect(omittedCount(model) == 1)
    #expect(current.matches(model.evidence) && current.matches(binding.current))
    #expect(binding.didRefresh && binding.hasPresentedPrimary)
    #expect(model.taskGeneration == generation && model.capturePublicationRevision == publication)
    #expect(model.messages.isEmpty && model.scene == nil && model.error == nil)
    #expect(model.guidanceSession.workflow == nil)
    expectNoExternalWork(model)
  }

  @Test func aRefreshedBindingWithoutAPresentedPrimaryRejectsOldAssessment() async throws {
    let (source, binding) = try await refreshedBinding(presentPrimary: false)
    let model = configuredModel()
    defer { model.stop() }
    model.evidence = binding.current
    let current = ScreenEvidenceIdentity(binding.current)

    await #expect(throws: ProviderError.self) {
      try await model.acceptProviderUnit(
        status(), generation: model.taskGeneration,
        expectedEvidence: ScreenEvidenceIdentity(source),
        guidanceBinding: binding, captureToken: model.capturePublicationRevision)
    }

    #expect(omittedCount(model) == 0 && !binding.hasPresentedPrimary)
    #expect(current.matches(model.evidence) && model.messages.isEmpty && model.scene == nil)
    expectNoExternalWork(model)
  }

  @Test func unrelatedPublishedEvidenceCannotUseThePrimaryOmissionPath() async throws {
    let (source, binding) = try await refreshedBinding(presentPrimary: true)
    let model = configuredModel()
    defer { model.stop() }
    let unrelated = try frame(age: 0, revision: 3)
    model.evidence = unrelated

    await #expect(throws: ProviderError.self) {
      try await model.acceptProviderUnit(
        status(), generation: model.taskGeneration,
        expectedEvidence: ScreenEvidenceIdentity(source),
        guidanceBinding: binding, captureToken: model.capturePublicationRevision)
    }

    #expect(omittedCount(model) == 0)
    #expect(ScreenEvidenceIdentity(unrelated).matches(model.evidence))
    #expect(binding.current.frameID != unrelated.frameID)
    expectNoExternalWork(model)
  }

  @Test func aStaleGenerationCannotDiscardOrAdmitAnAssessment() async throws {
    let (source, binding) = try await refreshedBinding(presentPrimary: true)
    let model = configuredModel()
    defer { model.stop() }
    model.evidence = binding.current
    let generation = model.taskGeneration

    await #expect(throws: CancellationError.self) {
      try await model.acceptProviderUnit(
        status(), generation: generation + 1, expectedEvidence: ScreenEvidenceIdentity(source),
        guidanceBinding: binding, captureToken: model.capturePublicationRevision)
    }

    #expect(omittedCount(model) == 0 && model.taskGeneration == generation)
    #expect(ScreenEvidenceIdentity(binding.current).matches(model.evidence))
    expectNoExternalWork(model)
  }

  @Test func anExpiredAssessmentWithoutAPrimaryStillFailsClosed() async throws {
    let source = try frame(age: 30)
    let binding = ScreenGuidanceTurnBinding(source: source)
    let model = configuredModel()
    defer { model.stop() }
    model.evidence = source

    await #expect(throws: ProviderError.self) {
      try await model.acceptProviderUnit(
        status(), generation: model.taskGeneration,
        expectedEvidence: ScreenEvidenceIdentity(source),
        guidanceBinding: binding, captureToken: model.capturePublicationRevision)
    }

    #expect(omittedCount(model) == 0 && !binding.didRefresh && !binding.hasPresentedPrimary)
    #expect(ScreenEvidenceIdentity(source).matches(model.evidence))
    expectNoExternalWork(model)
  }

  @Test func malformedAssessmentsCannotHideBehindTheNonfatalOmission() async throws {
    let (source, binding) = try await refreshedBinding(presentPrimary: true)
    let model = configuredModel()
    defer { model.stop() }
    model.evidence = binding.current
    var missing = status()
    missing.guidance = nil
    let malformed = [
      missing, status(summary: " \n\t"), status(summary: String(repeating: "x", count: 2_049)),
    ]
    for unit in malformed {
      await #expect(throws: ProviderError.self) {
        try await model.acceptProviderUnit(
          unit, generation: model.taskGeneration, expectedEvidence: ScreenEvidenceIdentity(source),
          guidanceBinding: binding, captureToken: model.capturePublicationRevision)
      }
    }
    #expect(omittedCount(model) == 0)
    // Failed malformed payloads must not consume the one valid assessment slot.
    try await model.acceptProviderUnit(
      status(), generation: model.taskGeneration, expectedEvidence: ScreenEvidenceIdentity(source),
      guidanceBinding: binding, captureToken: model.capturePublicationRevision)
    #expect(omittedCount(model) == 1)
    expectNoExternalWork(model)
  }

  @Test func anOmittedAssessmentStillConsumesTheSingleAssessmentSlot() async throws {
    let (source, binding) = try await refreshedBinding(presentPrimary: true)
    let model = configuredModel()
    defer { model.stop() }
    model.evidence = binding.current
    try await model.acceptProviderUnit(
      status(), generation: model.taskGeneration, expectedEvidence: ScreenEvidenceIdentity(source),
      guidanceBinding: binding, captureToken: model.capturePublicationRevision)

    await #expect(throws: ProviderError.self) {
      try await model.acceptProviderUnit(
        status(), generation: model.taskGeneration,
        expectedEvidence: ScreenEvidenceIdentity(source),
        guidanceBinding: binding, captureToken: model.capturePublicationRevision)
    }

    #expect(omittedCount(model) == 1)
    #expect(ScreenEvidenceIdentity(binding.current).matches(model.evidence))
    expectNoExternalWork(model)
  }

  @Test func changedForegroundCannotUseAStillMatchingPrimaryFrame() async throws {
    let (source, binding) = try await refreshedBinding(presentPrimary: true)
    let model = configuredModel(foregroundPID: 422)
    defer { model.stop() }
    model.evidence = binding.current

    await #expect(throws: ProviderError.self) {
      try await model.acceptProviderUnit(
        status(), generation: model.taskGeneration,
        expectedEvidence: ScreenEvidenceIdentity(source),
        guidanceBinding: binding, captureToken: model.capturePublicationRevision)
    }

    #expect(omittedCount(model) == 0)
    #expect(ScreenEvidenceIdentity(binding.current).matches(model.evidence))
    expectNoExternalWork(model)
  }

  @Test func aFreshSameFrameAssessmentStillRequiresItsForeground() throws {
    let model = configuredModel(foregroundPID: 422)
    defer { model.stop() }
    let source = try frame(age: 0)
    model.evidence = source
    let generation = model.taskGeneration

    #expect(throws: ProviderError.self) {
      try model.accept(
        status(), generation: generation, expectedEvidence: ScreenEvidenceIdentity(source))
    }

    #expect(ScreenEvidenceIdentity(source).matches(model.evidence))
    #expect(model.taskGeneration == generation && omittedCount(model) == 0)
    #expect(model.messages.isEmpty && model.scene == nil && model.guidanceSession.workflow == nil)
    expectNoExternalWork(model)
  }

  @Test func malformedDirectAssessmentsDoNotConsumeTheFreshFrameSlot() throws {
    let model = configuredModel()
    defer { model.stop() }
    let source = try frame(age: 0)
    model.evidence = source
    let generation = model.taskGeneration
    let identity = ScreenEvidenceIdentity(source)
    var missing = status()
    missing.guidance = nil
    for unit in [
      missing, status(summary: ""), status(summary: " \n\t"),
      status(summary: String(repeating: "x", count: 2_049)),
    ] {
      #expect(throws: ProviderError.self) {
        try model.accept(unit, generation: generation, expectedEvidence: identity)
      }
    }

    // Native admission must validate direct values too, not depend solely on
    // JSONDecoder having rejected malformed wire assessments earlier.
    try model.accept(status(), generation: generation, expectedEvidence: identity)
    #expect(throws: ProviderError.self) {
      try model.accept(status(), generation: generation, expectedEvidence: identity)
    }
    #expect(identity.matches(model.evidence) && omittedCount(model) == 0)
    #expect(model.messages.isEmpty && model.scene == nil && model.guidanceSession.workflow == nil)
    expectNoExternalWork(model)
  }

  @Test func homeProgressDetailPreservesCurrentErrorsAndLimitNotices() async throws {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("GuidanceAssessmentTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let store = try LocalStore(url: folder.appendingPathComponent("library.sqlite3"))
    let model = AppModel(
      acceptanceMode: true, store: store, guidanceForegroundPID: { 421 },
      screenGuidanceEnabled: { true })
    defer { model.stop() }
    model.guidanceSession.onPersisted = nil
    try model.guidanceSession.start(goal: "Continue the public screen task", speakAloud: false)
    model.pauseGuidance()
    await model.guidanceSession.flushPersistence()
    #expect(model.guidanceProgressTitle?.contains("Paused") == true)
    #expect(model.guidanceSession.persistenceIssue == nil)

    model.notice = "This guide reached its check limit. Start a new guide."
    model.error = "Allow screen recording, then recheck."
    #expect(model.guidanceProgressDetail == model.error)
    model.error = nil
    #expect(model.guidanceProgressDetail == model.notice)
    model.notice = String(repeating: "x", count: 600)
    #expect(model.guidanceProgressDetail == String(repeating: "x", count: 480))
    model.notice = nil
    #expect(model.guidanceProgressDetail == "Continue the public screen task")
    expectNoExternalWork(model)
    model.stop()
    await model.guidanceSession.flushPersistence()
  }

  private func configuredModel(foregroundPID: pid_t = 421) -> AppModel {
    let model = AppModel(
      acceptanceMode: true, guidanceForegroundPID: { foregroundPID },
      screenGuidanceEnabled: { true })
    model.configureResponseOutput(
      .resolve(
        text: "Guide me through the public screen", screenGuidanceEnabled: true,
        explicitGuidance: true))
    return model
  }

  private func refreshedBinding(presentPrimary: Bool) async throws
    -> (OpenCompanion.ScreenEvidence, ScreenGuidanceTurnBinding)
  {
    let source = try frame(age: 30)
    let fresh = try frame(age: 0, revision: 2, image: source.image)
    let binding = ScreenGuidanceTurnBinding(source: source)
    let primary = ProviderTarget(
      x: 0, y: 0, width: 0, height: 0, instruction: "Choose the public control.",
      shape: "ellipse", advanceOn: "click",
      candidateID: ScreenGrounding.candidateID(frameID: source.frameID, index: 0))
    var refreshes = 0
    let prepared = try await binding.prepare(
      primary,
      refresh: {
        refreshes += 1
        return fresh
      }, stillOwned: { true })
    #expect(refreshes == 1 && binding.didRefresh && binding.current.frameID == fresh.frameID)
    #expect(prepared.candidateID == nil)
    if presentPrimary { binding.recordPresentedTarget(prepared) }
    return (source, binding)
  }

  private func frame(age: TimeInterval, revision: UInt64 = 1, image: Data? = nil) throws
    -> OpenCompanion.ScreenEvidence
  {
    let id = UUID()
    return OpenCompanion.ScreenEvidence(
      frameID: id, revision: revision, capturedAt: ProcessInfo.processInfo.systemUptime - age,
      displayID: 1, foregroundPID: 421, foregroundName: "Public authored fixture",
      screenRect: CGRect(x: -320, y: 100, width: 320, height: 200), windowID: 42,
      image: try image ?? bitmapJPEG(), semanticText: "Public fixture only",
      groundingCandidates: [
        .init(
          id: ScreenGrounding.candidateID(frameID: id, index: 0), source: .accessibility,
          role: "AXButton", label: "Public control", enabled: true, actionable: true,
          x: 0.125, y: 0.25, width: 0.25, height: 0.2)
      ], imageWidth: 320, imageHeight: 200)
  }

  private func bitmapJPEG() throws -> Data {
    let context = try #require(
      CGContext(
        data: nil, width: 320, height: 200, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(CGColor(gray: 0.1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 320, height: 200))
    context.setFillColor(CGColor(gray: 0.9, alpha: 1))
    context.fill(CGRect(x: 40, y: 110, width: 80, height: 40))
    let image = try #require(context.makeImage())
    let bytes = NSMutableData()
    let destination = try #require(
      CGImageDestinationCreateWithData(bytes, "public.jpeg" as CFString, 1, nil))
    CGImageDestinationAddImage(
      destination, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
    #expect(CGImageDestinationFinalize(destination))
    return bytes as Data
  }

  private func status(summary: String = "The original public screen appears complete.")
    -> ProviderUnit
  {
    ProviderUnit(
      type: "guidanceStatus", guidance: .init(status: .complete, summary: summary))
  }

  private func omittedCount(_ model: AppModel) -> Int {
    model.diagnosticEvents.filter { $0["event"] == "guidance.assessment.staleOmitted" }.count
  }

  private func expectNoExternalWork(_ model: AppModel) {
    #expect(
      !model.diagnosticEvents.contains {
        ["guidance.capture.started", "guidance.stage.provider", "visual.accepted"].contains(
          $0["event"] ?? "")
      })
    #expect(!model.busy && !model.listening && !model.voice.hasPendingSpeech)
    #expect(model.activeGuidanceRequest == nil)
  }
}
