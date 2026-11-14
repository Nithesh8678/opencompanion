import Foundation
import Testing

@testable import OpenCompanion

@Suite @MainActor struct CursorGuidanceNarrationTests {
  @Test func guidanceRequiresExplicitCaptionEntryAndKeepsRangesBesideFlight() throws {
    let model = AppModel(acceptanceMode: true)
    model.configuration.speechEnabled = false
    let evidence = ScreenEvidence(
      frameID: UUID(), revision: 1,
      capturedAt: ProcessInfo.processInfo.systemUptime, displayID: 1, foregroundPID: 424_242,
      foregroundName: "Public authored fixture",
      screenRect: .init(x: 0, y: 0, width: 800, height: 600),
      image: Data(), semanticText: "")
    model.evidence = evidence
    let cursor = CursorCompanionCoordinator(
      model: model, observePointer: false,
      preferences: .init(), guidanceForegroundPID: { 424_242 })
    defer {
      cursor.shutdown()
      model.stop()
    }
    cursor.beginResponse(generation: model.taskGeneration, isGuidance: true)
    _ = cursor.guide(
      target: .init(
        x: 0.2, y: 0.3, width: 0.2, height: 0.1,
        instruction: "Select the menu", label: "Menu", shape: "ellipse", advanceOn: "click"),
      evidence: evidence, generation: model.taskGeneration)
    let context = VoiceNarrationContext(generation: model.taskGeneration, narrationID: UUID())
    let ordinary = cursor.beginNarration(
      text: "Select the menu", context: context, nativeSpeech: true)
    let accepted = cursor.beginGuidanceNarration(
      text: "Select the menu", context: context, nativeSpeech: true)
    #expect(!ordinary && accepted && cursor.snapshot.text.isEmpty)
    let token = UUID()
    cursor.updateNarration(
      .init(
        token: token, context: context, kind: .started,
        observedUptime: 10, revealedUTF16End: 0))
    cursor.updateNarration(
      .init(
        token: token, context: context, kind: .range,
        observedUptime: 11, revealedUTF16End: 6))
    #expect(cursor.snapshot.text == "Select" && !cursor.snapshot.following)
    cursor.finishNarration(context: context)
    #expect(cursor.snapshot.text == "Select the menu")
    model.stop()
    cursor.cancel(generation: model.taskGeneration)
    cursor.updateNarration(
      .init(
        token: token, context: context, kind: .range,
        observedUptime: 12, revealedUTF16End: 15))
    #expect(cursor.snapshot.text.isEmpty)
  }

  @Test func ordinaryExplanationDoesNotAcquireTheGuidanceCaptionCapability() {
    let model = AppModel(acceptanceMode: true)
    let cursor = CursorCompanionCoordinator(
      model: model, observePointer: false, preferences: .init())
    defer {
      cursor.shutdown()
      model.stop()
    }
    cursor.beginResponse(generation: model.taskGeneration)
    let context = VoiceNarrationContext(generation: model.taskGeneration, narrationID: UUID())
    let guidance = cursor.beginGuidanceNarration(
      text: "Guide", context: context, nativeSpeech: false)
    let ordinary = cursor.beginNarration(text: "Explain", context: context, nativeSpeech: false)
    #expect(!guidance && ordinary)
  }
}
