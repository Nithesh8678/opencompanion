import CoreGraphics
import Foundation
import Testing

@testable import OpenCompanion

/// Pure metadata/request checks. No AppModel, monitors, windows, capture,
/// provider, Accessibility or audio service is constructed.
struct ScreenGuidanceSelectedScopeTests {
  @Test func negativeOriginWindowScopeMatchesOnlyTheExactCaptureExtent() throws {
    let original = evidence()
    let selectionID = UUID()
    let scope = try ScreenGuidanceCaptureScope(evidence: original, selectionID: selectionID)
    #expect(scope.selectionID == selectionID && scope.foregroundPID == original.foregroundPID)
    #expect(scope.displayID == original.displayID && scope.windowID == 42)
    #expect(scope.sourceRect == CGRect(x: -600, y: -200, width: 320, height: 240))
    #expect(scope.matches(original) && !scope.matches(nil))
    for changed in mismatchedEvidence(original) { #expect(!scope.matches(changed)) }
    var resized = original
    resized.screenRect.size.width += 0.000_000_1
    #expect(!scope.matches(resized))
  }

  @Test func selectionIdentityIsDistinctFromFrameIdentityAndPayload() throws {
    let original = evidence()
    let firstSelection = try ScreenGuidanceCaptureScope(evidence: original, selectionID: UUID())
    let secondSelection = try ScreenGuidanceCaptureScope(evidence: original, selectionID: UUID())
    #expect(firstSelection != secondSelection)
    #expect(firstSelection.matches(original) && secondSelection.matches(original))
    var refreshed = original
    refreshed.frameID = UUID()
    refreshed.revision = 17
    refreshed.capturedAt = 101
    refreshed.image = Data([9, 8, 7])
    refreshed.semanticText = "Changed authored text"
    #expect(firstSelection.matches(refreshed))
    let sameSelection = try ScreenGuidanceCaptureScope(
      evidence: refreshed, selectionID: firstSelection.selectionID)
    #expect(sameSelection == firstSelection)
    // A scope descriptor intentionally cannot authenticate a frame's pixels,
    // candidate table, timestamp, revision or the current host selection ID.
    refreshed.capturedAt = .nan
    refreshed.image = Data()
    #expect(
      try ScreenGuidanceCaptureScope(evidence: refreshed, selectionID: firstSelection.selectionID)
        == firstSelection)
  }

  @Test func malformedRawGeometryAndNonpositiveSourceIdentifiersReject() throws {
    let original = evidence()
    var invalids: [OpenCompanion.ScreenEvidence] = []
    for pid: pid_t in [0, -1] {
      var invalid = original
      invalid.foregroundPID = pid
      invalids.append(invalid)
    }
    var display = original
    display.displayID = 0
    invalids.append(display)
    var window = original
    window.windowID = 0
    invalids.append(window)
    for rect in [
      CGRect(x: 0, y: 0, width: -1, height: 20),
      CGRect(x: 0, y: 0, width: 20, height: 0),
      CGRect(x: 0, y: 0, width: 100_001, height: 20),
      CGRect(x: 10_000_001, y: 0, width: 20, height: 20),
      CGRect(x: 0, y: CGFloat.nan, width: 20, height: 20),
      CGRect(x: 0, y: 0, width: CGFloat.infinity, height: 20),
    ] {
      var invalid = original
      invalid.screenRect = rect
      invalids.append(invalid)
    }
    for invalid in invalids {
      #expect(throws: ProviderError.self) {
        try ScreenGuidanceCaptureScope(evidence: invalid, selectionID: UUID())
      }
    }
    var region = original
    region.windowID = nil
    #expect(try ScreenGuidanceCaptureScope(evidence: region, selectionID: UUID()).matches(region))
  }

  @Test func spokenContinuePreservesTheImmutableSelectedScopeAndRequestPolicy() throws {
    let original = evidence()
    let scope = try ScreenGuidanceCaptureScope(evidence: original, selectionID: UUID())
    let request = ScreenGuidanceRequest(
      prompt: "Complete the public selected-window task", step: 2, expires: 280,
      speakAloud: false, selectedScope: scope)
    let continuation = continuation(request: request, frame: original)
    let next = try #require(
      continuation.nextRequest(
        transcript: "Continue.", generation: 77, evidence: original,
        foregroundPID: original.foregroundPID, now: 101))
    #expect(next.id == request.id && next.prompt == request.prompt && next.step == 3)
    #expect(next.expires == request.expires && next.speakAloud == false)
    #expect(next.selectedScope == scope && next.selectedScope?.selectionID == scope.selectionID)
  }

  @Test func aCopiedVoiceLeaseCannotCrossTheRequestsSelectedScope() throws {
    let original = evidence()
    let scope = try ScreenGuidanceCaptureScope(evidence: original, selectionID: UUID())
    let request = ScreenGuidanceRequest(
      prompt: "Public scoped task", expires: 280, selectedScope: scope)
    for changed in mismatchedEvidence(original) {
      // Bind the handoff's ordinary frame identity to the changed frame so the
      // selected-scope comparison is the remaining independent refusal gate.
      let copied = continuation(request: request, frame: changed)
      #expect(
        copied.nextRequest(
          transcript: "Continue", generation: 77, evidence: changed,
          foregroundPID: changed.foregroundPID, now: 101) == nil)
    }
  }

  @Test func scopeMatchingDoesNotReplaceTheExistingVoiceFrameAndGenerationGuards() throws {
    let original = evidence()
    let scope = try ScreenGuidanceCaptureScope(evidence: original, selectionID: UUID())
    let request = ScreenGuidanceRequest(
      prompt: "Public scoped task", expires: 280, selectedScope: scope)
    let voice = continuation(request: request, frame: original)
    var newer = original
    newer.frameID = UUID()
    newer.revision += 1
    #expect(scope.matches(newer))
    #expect(
      voice.nextRequest(
        transcript: "Continue", generation: 77, evidence: newer,
        foregroundPID: newer.foregroundPID, now: 101) == nil)
    #expect(
      voice.nextRequest(
        transcript: "Continue", generation: 78, evidence: original,
        foregroundPID: original.foregroundPID, now: 101) == nil)
    #expect(
      voice.nextRequest(
        transcript: "Continue", generation: 77, evidence: original,
        foregroundPID: original.foregroundPID, now: 145) == nil)
  }

  @Test func anUnselectedRequestKeepsTheExistingDefaultAndVoiceBehavior() throws {
    let original = evidence()
    let request = ScreenGuidanceRequest(prompt: "Public current-screen task", expires: 280)
    #expect(request.selectedScope == nil)
    let next = try #require(
      continuation(request: request, frame: original).nextRequest(
        transcript: "Done", generation: 77, evidence: original,
        foregroundPID: original.foregroundPID, now: 101))
    #expect(next.selectedScope == nil && next.id == request.id && next.expires == request.expires)
  }

  private func continuation(
    request: ScreenGuidanceRequest, frame: OpenCompanion.ScreenEvidence
  ) -> ManualGuidanceVoiceContinuation {
    .init(
      step: .init(
        id: UUID(), label: "Public field", instruction: "Enter the value, then Continue",
        evidence: ScreenEvidenceIdentity(frame), generation: 55, request: request,
        targetRect: .init(x: -550, y: -100, width: 100, height: 30), expiresAt: 145),
      inputGeneration: 77)
  }

  private func evidence() -> OpenCompanion.ScreenEvidence {
    .init(
      frameID: UUID(), revision: 1, capturedAt: 99, displayID: 7, foregroundPID: 424_242,
      foregroundName: "Authored public fixture",
      screenRect: .init(x: -600, y: -200, width: 320, height: 240),
      windowID: 42, image: Data(), semanticText: "No captured pixels")
  }

  private func mismatchedEvidence(_ original: OpenCompanion.ScreenEvidence) -> [OpenCompanion
    .ScreenEvidence]
  {
    var values: [OpenCompanion.ScreenEvidence] = []
    var changed = original
    changed.foregroundPID += 1
    values.append(changed)
    changed = original
    changed.displayID += 1
    values.append(changed)
    changed = original
    changed.windowID = 43
    values.append(changed)
    changed = original
    changed.windowID = nil
    values.append(changed)
    changed = original
    changed.screenRect.origin.x += 1
    values.append(changed)
    changed = original
    changed.screenRect.size.height += 1
    values.append(changed)
    return values
  }
}
