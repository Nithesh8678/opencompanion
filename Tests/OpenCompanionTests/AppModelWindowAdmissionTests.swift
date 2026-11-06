import CoreGraphics
import Foundation
import Testing

@testable import OpenCompanion

/// Real synchronous target admission, stopped before its queued capture task.
/// No provider, native window query, annotation window, audio or input runs.
@Suite @MainActor struct AppModelWindowAdmissionTests {
  @Test func aRefusedWindowCannotStartCursorFlightOrPublishAnAction() throws {
    var queried: [CGRect] = []
    let model = AppModel(
      acceptanceMode: true, screenGuidanceEnabled: { true },
      selectedWindowVisibility: { frame, rect in
        #expect(frame.windowID == 42 && frame.capturedWindowBounds != nil)
        queried.append(rect)
        return false
      })
    defer { model.stop() }
    model.configuration.speechEnabled = false
    model.beginScreenGuidance("Guide me through the public field", speakAloud: false)
    let frame = evidence()
    model.evidence = frame
    var flights = 0
    var continuations = 0
    model.onCursorTargetAccepted = { _, _, _ in
      flights += 1
      return 0
    }
    model.onScreenGuidanceTargetAccepted = { _, _, _, _ in continuations += 1 }
    let before = model.guidanceSession.workflow

    #expect(throws: ProviderError.self) {
      try model.accept(
        target(), generation: model.taskGeneration, expectedEvidence: ScreenEvidenceIdentity(frame))
    }

    #expect(queried == [CGRect(x: -520, y: -44, width: 64, height: 24)])
    #expect(flights == 0 && continuations == 0)
    #expect(model.guidanceSession.workflow == before)
    #expect(model.guidanceSession.workflow?.actions.isEmpty == true)
    #expect(model.overlay.presentationDiagnostics.isEmpty && !model.voice.hasPendingSpeech)
    #expect(model.messages.count == 1)
  }

  @Test func missingWholeWindowProvenanceRefusesBeforeNativePresentation() throws {
    let model = AppModel(acceptanceMode: true, screenGuidanceEnabled: { true })
    defer { model.stop() }
    model.configuration.speechEnabled = false
    model.beginScreenGuidance("Guide me through this public field", speakAloud: false)
    var frame = evidence()
    frame.capturedWindowBounds = nil
    model.evidence = frame
    var flights = 0
    model.onCursorTargetAccepted = { _, _, _ in
      flights += 1
      return 0
    }
    #expect(throws: ProviderError.self) {
      try model.accept(
        target(), generation: model.taskGeneration, expectedEvidence: ScreenEvidenceIdentity(frame))
    }
    #expect(flights == 0 && model.overlay.presentationDiagnostics.isEmpty)
    #expect(model.guidanceSession.workflow?.actions.isEmpty == true)
  }

  @Test func mutatingWholeWindowBoundsRevokesTheImmutableFrameIdentity() throws {
    var queries = 0
    let model = AppModel(
      acceptanceMode: true, screenGuidanceEnabled: { true },
      selectedWindowVisibility: { _, _ in
        queries += 1
        return false
      })
    defer { model.stop() }
    model.beginScreenGuidance("Guide me through the public field", speakAloud: false)
    let frame = evidence()
    let original = ScreenEvidenceIdentity(frame)
    var changed = frame
    changed.capturedWindowBounds?.origin.x += 1
    model.evidence = changed
    #expect(!original.matches(changed))
    #expect(throws: ProviderError.self) {
      try model.accept(target(), generation: model.taskGeneration, expectedEvidence: original)
    }
    #expect(queries == 0 && model.overlay.presentationDiagnostics.isEmpty)
  }

  private func evidence() -> OpenCompanion.ScreenEvidence {
    .init(
      frameID: UUID(), revision: 1, capturedAt: ProcessInfo.processInfo.systemUptime,
      displayID: 1, foregroundPID: 424_242, foregroundName: "Public authored fixture",
      screenRect: CGRect(x: -600, y: -200, width: 320, height: 240), windowID: 42,
      capturedWindowBounds: CGRect(x: -650, y: -250, width: 500, height: 400),
      image: Data(), semanticText: "Public metadata only")
  }

  private func target() -> ProviderUnit {
    .init(
      type: "target", text: nil, title: nil, nodes: nil, removeIDs: nil,
      target: .init(
        x: 0.25, y: 0.25, width: 0.2, height: 0.1,
        instruction: "Enter a public name, then Continue.", label: "Public name",
        advanceOn: "manual", awaitUser: true))
  }
}
