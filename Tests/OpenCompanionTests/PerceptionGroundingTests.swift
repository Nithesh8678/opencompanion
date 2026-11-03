import Foundation
import Testing

@testable import OpenCompanion

struct PerceptionGroundingTests {
  @Test func exactCaptureMetadataAndRetainedCandidatesMatchTheSerializedContext() throws {
    let frameID = UUID()
    let label = candidate(frameID: frameID, index: 0, label: "Sidebar", actionable: false)
    let button = candidate(frameID: frameID, index: 1, label: "New task", actionable: true)
    let ocrRect = try #require(
      ScreenGrounding.normalizedOCRRect(CGRect(x: 0.2, y: 0.7, width: 0.3, height: 0.05)))
    let context = CaptureGroundingContext.make(
      frameID: frameID, foregroundName: "Public Fixture", imageWidth: 1_379, imageHeight: 821,
      accessibility: .init(candidates: [label, button], status: "Focused window fixture"),
      ocr: [.init(label: "Public OCR label", bounds: ocrRect)])
    let envelope = try decodeEnvelope(context)

    #expect(envelope.frameID == frameID)
    #expect(envelope.coordinateSpace == "capture.normalized.topLeft")
    #expect(envelope.candidates == context.candidates)
    #expect(
      context.candidates.map(\.id) == [
        button.id, label.id,
        ScreenGrounding.candidateID(frameID: frameID, index: 2),
      ])
    #expect(Set(context.candidates.map(\.id)).count == 3)
    let ocr = try #require(context.candidates.last)
    #expect(ocr.source == .ocr && !ocr.actionable)
    #expect(ocr.x == ocrRect.minX && ocr.y == ocrRect.minY)
    #expect(ocr.width == ocrRect.width && ocr.height == ocrRect.height)
    #expect(context.text.contains("Encoded image dimensions: 1379 x 821 pixels."))
    #expect(context.text.contains("OCR is never click-actionable"))
  }

  @Test func usableControlsTakePriorityWhileTheExactEvidenceTableStaysBounded() throws {
    let frameID = UUID()
    var ax = (0..<149).map { index in
      candidate(
        frameID: frameID, index: index,
        label: "Public static \(index) " + String(repeating: "👨‍👩‍👧‍👦", count: 80),
        actionable: false)
    }
    let button = candidate(frameID: frameID, index: 149, label: "New task", actionable: true)
    ax.append(button)
    let ocr = (0..<250).map { index in
      OCRGroundingObservation(
        label: "Public OCR \(index)", bounds: CGRect(x: 0.1, y: 0.2, width: 0.1, height: 0.05))
    }
    let context = CaptureGroundingContext.make(
      frameID: frameID, foregroundName: String(repeating: "Public name ", count: 1_000),
      imageWidth: 1_440, imageHeight: 900,
      accessibility: .init(candidates: ax, status: "Focused window fixture"), ocr: ocr)
    let envelope = try decodeEnvelope(context)
    let json = try #require(context.text.components(separatedBy: "\n").last)

    #expect(context.candidates.first == button)
    #expect(context.candidates.count <= ScreenGrounding.maximumCandidates)
    #expect(json.utf8.count <= ScreenGrounding.maximumContextBytes)
    #expect(context.text.utf8.count <= 48_000)
    #expect(envelope.candidates == context.candidates)
    #expect(Set(context.candidates.map(\.id)).count == context.candidates.count)
  }

  @Test func staleAXObservationsAndInvalidOCRGeometryCannotEnterTheCaptureTable() throws {
    let frameID = UUID()
    let stale = candidate(frameID: UUID(), index: 0, label: "Stale control", actionable: true)
    let context = CaptureGroundingContext.make(
      frameID: frameID, foregroundName: "Public Fixture", imageWidth: 800, imageHeight: 600,
      accessibility: .init(candidates: [stale], status: "Focused window fixture"),
      ocr: [
        .init(label: "Outside the frame", bounds: CGRect(x: 0.9, y: 0.2, width: 0.2, height: 0.1))
      ])

    #expect(context.candidates.isEmpty)
    #expect(try decodeEnvelope(context).candidates.isEmpty)
    #expect(!context.text.contains("Stale control"))
    #expect(!context.text.contains("Outside the frame"))
  }

  @Test func secureAndHiddenSubtreesAreExcludedBeforeReadingTheirChildren() {
    #expect(
      !AccessibilityGroundingPolicy.permitsSubtree(
        role: "AXSecureTextField", subrole: nil, hidden: false))
    #expect(
      !AccessibilityGroundingPolicy.permitsSubtree(
        role: "AXTextField", subrole: "AXSecureTextField", hidden: false))
    #expect(
      !AccessibilityGroundingPolicy.permitsSubtree(
        role: "AXGroup", subrole: nil, hidden: true))
    #expect(
      AccessibilityGroundingPolicy.permitsSubtree(
        role: "AXButton", subrole: nil, hidden: false))
  }

  @Test func disabledAncestorsCannotBeOverriddenByEnabledDescendants() {
    let disabledGroup = AccessibilityGroundingPolicy.enabled(ancestor: true, reported: false)
    let child = AccessibilityGroundingPolicy.enabled(ancestor: disabledGroup, reported: true)
    let grandchild = AccessibilityGroundingPolicy.enabled(ancestor: child, reported: nil)
    #expect(!disabledGroup && !child && !grandchild)
    #expect(
      !AccessibilityGroundingPolicy.actionable(
        role: "AXButton", enabled: child, supportsPress: true))
    #expect(AccessibilityGroundingPolicy.enabled(ancestor: true, reported: nil))
    #expect(
      AccessibilityGroundingPolicy.actionable(
        role: "AXButton", enabled: true, supportsPress: false))
    #expect(
      !AccessibilityGroundingPolicy.actionable(
        role: "AXTextField", enabled: true, supportsPress: false))
    #expect(
      AccessibilityGroundingPolicy.actionable(
        role: "AXGroup", enabled: true, supportsPress: true))
  }

  @Test func windowAndRegionScopesReturnBeforeAnyAccessibilityLookup() async {
    for scope in [CaptureEvidenceScope.window, .region] {
      let snapshot = await AccessibilityService.describe(
        pid: -1, frameID: UUID(), primaryTop: 900,
        sourceRect: CGRect(x: -800, y: 100, width: 600, height: 400), scope: scope)
      #expect(snapshot.candidates.isEmpty)
      #expect(snapshot.status.contains("preserve the selected window or region scope"))
    }
  }

  @Test func oldScreenEvidenceConstructionKeepsCompatibleEmptyGroundingDefaults() {
    let frame = ScreenEvidence(
      frameID: UUID(), revision: 1, capturedAt: 100, displayID: 1,
      foregroundPID: -1, foregroundName: "Public Fixture",
      screenRect: CGRect(x: -600, y: 100, width: 500, height: 400), image: Data(), semanticText: "")
    #expect(frame.groundingCandidates.isEmpty)
    #expect(frame.imageWidth == 0 && frame.imageHeight == 0)
  }

  private func candidate(
    frameID: UUID, index: Int, label: String, actionable: Bool
  ) -> ScreenGroundingCandidate {
    ScreenGroundingCandidate(
      id: ScreenGrounding.candidateID(frameID: frameID, index: index), source: .accessibility,
      role: actionable ? "AXButton" : "AXStaticText", label: label, enabled: true,
      actionable: actionable, x: 0.1, y: 0.2, width: 0.1, height: 0.05)
  }

  private struct Envelope: Decodable {
    let frameID: UUID
    let coordinateSpace: String
    let candidates: [ScreenGroundingCandidate]
  }

  private func decodeEnvelope(_ context: CaptureGroundingContext) throws -> Envelope {
    let json = try #require(context.text.components(separatedBy: "\n").last)
    return try JSONDecoder().decode(Envelope.self, from: Data(json.utf8))
  }
}
