import Foundation
import Testing

@testable import OpenCompanion

@Suite struct TurnContextBindingTests {
  @Test func equalRevisionInDifferentNotebookCannotAcceptTheOldResponse() throws {
    let binding = NotebookTurnBinding(documentID: "original", revision: 2)
    #expect(
      try binding.checkedBase(currentID: "original", currentRevision: 2, proposedBase: 2) == 2)
    #expect(throws: (any Error).self) {
      try binding.checkedBase(currentID: "replacement", currentRevision: 2, proposedBase: 2)
    }
    #expect(throws: (any Error).self) {
      try binding.checkedBase(currentID: "original", currentRevision: 3, proposedBase: 2)
    }
    #expect(throws: (any Error).self) {
      try binding.checkedBase(currentID: "original", currentRevision: 2, proposedBase: 1)
    }
  }

  @Test func initialEmptySurfaceCannotAdoptAUserCreatedNotebook() throws {
    let binding = NotebookTurnBinding(documentID: nil, revision: nil)
    #expect(try binding.checkedBase(currentID: nil, currentRevision: nil, proposedBase: nil) == 0)
    #expect(throws: (any Error).self) {
      try binding.checkedBase(currentID: "new-user-notebook", currentRevision: 0, proposedBase: 0)
    }
  }

  @Test func frameRevisionAndSourceMustAllMatchTheTurnSnapshot() {
    let frame = ScreenEvidence(
      frameID: UUID(), revision: 1, capturedAt: 10, displayID: 1,
      foregroundPID: 42, foregroundName: "Selected app",
      screenRect: CGRect(x: 0, y: 0, width: 800, height: 600),
      windowID: 100, image: Data(), semanticText: "")
    let identity = ScreenEvidenceIdentity(frame)
    #expect(identity.matches(frame))
    #expect(!identity.matches(nil))
    var changed = frame
    changed.frameID = UUID()
    #expect(!identity.matches(changed))
    changed = frame
    changed.revision += 1
    #expect(!identity.matches(changed))
    changed = frame
    changed.windowID = 200
    #expect(!identity.matches(changed))
    changed = frame
    changed.foregroundPID = 99
    #expect(!identity.matches(changed))
    changed = frame
    changed.displayID = 2
    #expect(!identity.matches(changed))
    changed = frame
    changed.screenRect.origin.x = 100
    #expect(!identity.matches(changed))
  }

  @Test func clearedOrSupersededCaptureCannotPublishLate() {
    var gate = CapturePublicationGate()
    let first = gate.generation
    #expect(gate.permits(first, cancelled: false))
    gate.invalidate()
    #expect(!gate.permits(first, cancelled: false))
    let second = gate.generation
    #expect(gate.permits(second, cancelled: false))
    #expect(!gate.permits(second, cancelled: true))
    gate.invalidate()
    #expect(!gate.permits(second, cancelled: false))
  }

  @Test func scopedCapturesNeverIncludeApplicationWideAXText() {
    #expect(CaptureEvidenceScope.display.permitsApplicationAccessibility)
    #expect(!CaptureEvidenceScope.window.permitsApplicationAccessibility)
    #expect(!CaptureEvidenceScope.region.permitsApplicationAccessibility)
  }
}
