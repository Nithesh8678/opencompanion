import Foundation
import Testing

@testable import OpenCompanion

/// These tests exercise the pure publication decision without constructing an
/// AppModel, opening a window, capturing a screen, or touching the user's store.
@Suite struct ShellCaptureExpectationTests {
  private let previousFrame = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
  private let freshFrame = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!

  @Test func completionRequiresAnActualPublishedFrame() {
    let expectation = ShellCaptureExpectation(
      taskGeneration: 7, previousFrameID: previousFrame, publicationRevision: 12)

    // A UI/audio transition to Ready supplies no frame and cannot authorize
    // re-expanding or focusing the resident companion.
    #expect(
      expectation.completion(taskGeneration: 7, publicationRevision: 12, frameID: nil)
        == .waiting)
  }

  @Test func retainedEvidenceCannotCompleteANewCapture() {
    let expectation = ShellCaptureExpectation(
      taskGeneration: 7, previousFrameID: previousFrame, publicationRevision: 12)

    #expect(
      expectation.completion(
        taskGeneration: 7, publicationRevision: 12, frameID: previousFrame) == .waiting)
  }

  @Test func freshFrameCompletesOnlyTheExpectedPublication() {
    let expectation = ShellCaptureExpectation(
      taskGeneration: 7, previousFrameID: previousFrame, publicationRevision: 12)

    #expect(
      expectation.completion(taskGeneration: 7, publicationRevision: 12, frameID: freshFrame)
        == .completed)
  }

  @Test func stopInvalidatesEvenAFreshLateFrame() {
    let expectation = ShellCaptureExpectation(
      taskGeneration: 7, previousFrameID: previousFrame, publicationRevision: 12)

    #expect(
      expectation.completion(taskGeneration: 8, publicationRevision: 12, frameID: freshFrame)
        == .invalidated)
    #expect(
      expectation.completion(taskGeneration: 8, publicationRevision: 12, frameID: nil)
        == .invalidated)
  }

  @Test func supersedingContextSelectionInvalidatesTheOldCapture() {
    let expectation = ShellCaptureExpectation(
      taskGeneration: 7, previousFrameID: previousFrame, publicationRevision: 12)

    #expect(
      expectation.completion(taskGeneration: 7, publicationRevision: 13, frameID: freshFrame)
        == .invalidated)
    #expect(
      expectation.completion(taskGeneration: 7, publicationRevision: 13, frameID: nil)
        == .invalidated)
  }

  @Test func regionSelectionWaitsForItsFinalCapturePublication() {
    let expectation = ShellCaptureExpectation(
      taskGeneration: 7, previousFrameID: previousFrame, publicationRevision: 14)

    // Selection's revision 13 precedes the actual capture at revision 14.
    // Even a different frame observed during selection cannot complete it.
    #expect(
      expectation.completion(taskGeneration: 7, publicationRevision: 13, frameID: freshFrame)
        == .waiting)
    #expect(
      expectation.completion(taskGeneration: 7, publicationRevision: 14, frameID: freshFrame)
        == .completed)
  }

  @Test func firstCaptureWorksWithoutAnyPreviousEvidence() {
    let expectation = ShellCaptureExpectation(
      taskGeneration: 0, previousFrameID: nil, publicationRevision: 1)

    #expect(
      expectation.completion(taskGeneration: 0, publicationRevision: 1, frameID: nil)
        == .waiting)
    #expect(
      expectation.completion(taskGeneration: 0, publicationRevision: 1, frameID: freshFrame)
        == .completed)
  }
}
