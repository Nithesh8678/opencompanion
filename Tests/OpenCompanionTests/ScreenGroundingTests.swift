import CoreGraphics
import Foundation
import ImageIO
import Testing

@testable import OpenCompanion

struct ScreenGroundingTests {
  private let frameID = UUID(uuidString: "A94CA449-D258-46E6-8B09-C232903061A4")!

  @Test func pixelProtocolDecodesWithoutNormalizedCoordinatesAndNativeCodeDividesOnce() throws {
    let data = Data(
      #"{"pixelBounds":{"x":120,"y":80,"width":48,"height":40},"instruction":"Choose the control.","label":"Next","shape":"ellipse","advanceOn":"click"}"#
        .utf8)
    let raw = try JSONDecoder().decode(ProviderTarget.self, from: data)
    #expect(raw.x == 0 && raw.y == 0 && raw.width == 0 && raw.height == 0)
    #expect(raw.pixelBounds == ProviderPixelBounds(x: 120, y: 80, width: 48, height: 40))
    let resolved = try ScreenGrounding.resolve(
      raw, candidates: [], frameID: frameID, imagePixelSize: CGSize(width: 1_200, height: 780))
    #expect(abs(resolved.x - 120.0 / 1_200) < 0.000_000_001)
    #expect(abs(resolved.y - 80.0 / 780) < 0.000_000_001)
    #expect(abs(resolved.width - 48.0 / 1_200) < 0.000_000_001)
    #expect(abs(resolved.height - 40.0 / 780) < 0.000_000_001)
    #expect(resolved.pixelBounds == nil && resolved.candidateID == nil)
    #expect(resolved.instruction == raw.instruction && resolved.label == raw.label)
    #expect(resolved.shape == raw.shape && resolved.advanceOn == raw.advanceOn)
  }

  @Test func ambiguousPixelCoordinateRepresentationsRejectDuringDecoding() {
    let pixels = #""pixelBounds":{"x":120,"y":80,"width":48,"height":40}"#
    for extra in [
      #""candidateID":"another-authority""#, #""candidateID":null"#,
      #""x":0"#, #""y":0"#, #""width":0"#, #""height":null"#,
    ] {
      let json = "{" + pixels + "," + extra + #", "instruction":"Choose the control."}"#
      #expect(throws: (any Error).self) {
        try JSONDecoder().decode(ProviderTarget.self, from: Data(json.utf8))
      }
    }
    #expect(throws: (any Error).self) {
      try JSONDecoder().decode(
        ProviderTarget.self,
        from: Data(#"{"pixelBounds":{"x":1,"y":2,"width":3},"instruction":"Missing height"}"#.utf8))
    }
  }

  @Test func pixelsNeedTrustedBoundedImageDimensionsAndUnmixedCandidateAuthority() {
    let raw = pixelTarget()
    let invalidSizes: [CGSize?] = [
      nil, .zero, CGSize(width: -1, height: 780), CGSize(width: CGFloat.nan, height: 780),
      CGSize(width: 1_200, height: CGFloat.infinity), CGSize(width: 16_385, height: 780),
      CGSize(width: 1_200.5, height: 780),
    ]
    for size in invalidSizes {
      #expect(throws: ProviderError.self) {
        try ScreenGrounding.resolve(raw, candidates: [], frameID: frameID, imagePixelSize: size)
      }
    }
    var mixed = raw
    mixed.candidateID = candidate().id
    #expect(throws: ProviderError.self) {
      try ScreenGrounding.resolve(
        mixed, candidates: [candidate()], frameID: frameID,
        imagePixelSize: CGSize(width: 1_200, height: 780))
    }
    for field in 0..<4 {
      var normalizedAndPixels = raw
      switch field {
      case 0: normalizedAndPixels.x = 0.1
      case 1: normalizedAndPixels.y = 0.1
      case 2: normalizedAndPixels.width = 0.1
      default: normalizedAndPixels.height = 0.1
      }
      #expect(throws: ProviderError.self) {
        try ScreenGrounding.resolve(
          normalizedAndPixels, candidates: [], frameID: frameID,
          imagePixelSize: CGSize(width: 1_200, height: 780))
      }
    }
  }

  @Test func negativeNonfiniteAndOutOfImagePixelBoxesReject() {
    for bounds in [
      ProviderPixelBounds(x: -1, y: 80, width: 48, height: 40),
      ProviderPixelBounds(x: 120, y: -1, width: 48, height: 40),
      ProviderPixelBounds(x: 120, y: 80, width: 0, height: 40),
      ProviderPixelBounds(x: 120, y: 80, width: 48, height: -40),
      ProviderPixelBounds(x: 1_180, y: 80, width: 48, height: 40),
      ProviderPixelBounds(x: 120, y: 770, width: 48, height: 40),
      ProviderPixelBounds(x: .nan, y: 80, width: 48, height: 40),
      ProviderPixelBounds(x: 120, y: 80, width: .infinity, height: 40),
    ] {
      var raw = pixelTarget()
      raw.pixelBounds = bounds
      #expect(throws: ProviderError.self) {
        try ScreenGrounding.resolve(
          raw, candidates: [], frameID: frameID, imagePixelSize: CGSize(width: 1_200, height: 780))
      }
    }
  }

  @Test func actualJpegHeaderOwnsPixelDimensionsAndStoredMetadataMustAgree() throws {
    let jpeg = try encodedImage(width: 1_200, height: 780)
    #expect(
      try ScreenImageGeometry.trustedEncodedPixelSize(jpeg) == CGSize(width: 1_200, height: 780))
    var evidence = imageEvidence(jpeg)
    let resolved = try evidence.resolvingTarget(pixelTarget())
    #expect(abs(resolved.height - 40.0 / 780) < 0.000_000_001)
    evidence.imageWidth = 1_200
    evidence.imageHeight = 780
    #expect(try evidence.resolvingTarget(pixelTarget()).pixelBounds == nil)
    evidence.imageWidth = 1_440
    #expect(throws: ProviderError.self) { try evidence.resolvingTarget(pixelTarget()) }
    evidence.imageWidth = 1_200
    evidence.imageHeight = -1
    #expect(throws: ProviderError.self) { try evidence.resolvingTarget(pixelTarget()) }
  }

  @Test func badUnsupportedOversizeAndRotatedEncodedImagesRejectBeforePixelResolution() throws {
    let invalid = [
      Data(), Data("not an image".utf8), Data(repeating: 0, count: 12_000_001),
      try encodedImage(width: 64, height: 40, type: "public.png"),
      try encodedImage(width: 16_385, height: 1),
      try encodedImage(width: 64, height: 40, orientation: 6),
    ]
    for data in invalid {
      #expect(throws: ProviderError.self) {
        try ScreenImageGeometry.trustedEncodedPixelSize(data)
      }
      #expect(throws: ProviderError.self) { try imageEvidence(data).resolvingTarget(pixelTarget()) }
    }
  }

  @Test func existingNormalizedAndCandidateTargetsNeverReadImageHeaders() throws {
    var evidence = imageEvidence(Data("Intentionally not an image".utf8))
    let normalized = target(id: nil)
    #expect(try evidence.resolvingTarget(normalized).x == normalized.x)
    evidence.groundingCandidates = [candidate()]
    #expect(try evidence.resolvingTarget(target(id: candidate().id)).x == candidate().x)
  }

  private func pixelTarget() -> ProviderTarget {
    ProviderTarget(
      x: 0, y: 0, width: 0, height: 0, instruction: "Choose the control.",
      label: "Next", shape: "ellipse", advanceOn: "click",
      pixelBounds: ProviderPixelBounds(x: 120, y: 80, width: 48, height: 40))
  }

  private func imageEvidence(_ data: Data) -> ScreenEvidence {
    ScreenEvidence(
      frameID: frameID, revision: 1, capturedAt: 10, displayID: 7,
      foregroundPID: 123, foregroundName: "Authored fixture",
      screenRect: CGRect(x: -600, y: 80, width: 1_200, height: 780),
      image: data, semanticText: "Authored public fixture only")
  }

  private func encodedImage(
    width: Int, height: Int, type: String = "public.jpeg", orientation: Int = 1
  ) throws -> Data {
    let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
    let context = try #require(
      CGContext(
        data: nil, width: width, height: height,
        bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
    context.setFillColor(CGColor(gray: 0.2, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let image = try #require(context.makeImage())
    let data = NSMutableData()
    let destination = try #require(CGImageDestinationCreateWithData(data, type as CFString, 1, nil))
    CGImageDestinationAddImage(
      destination, image, [kCGImagePropertyOrientation: orientation] as CFDictionary)
    try #require(CGImageDestinationFinalize(destination))
    return data as Data
  }

  @Test func emptyTitleFallsThroughToTrimmedDescriptionThenHelp() {
    #expect(
      ScreenGrounding.firstNonemptyLabel([nil, "", " \n\t", " New conversation ", "Help"])
        == "New conversation")
    #expect(ScreenGrounding.firstNonemptyLabel(["", nil, "Show navigation"]) == "Show navigation")
    #expect(ScreenGrounding.firstNonemptyLabel(["Title", "Description"]) == "Title")
    #expect(ScreenGrounding.firstNonemptyLabel([nil, " \n"]) == "")
    #expect(ScreenGrounding.firstNonemptyLabel(["Title"], limit: 0) == "")
  }

  @Test func labelsPreserveGraphemesAndBoundEncodedBytes() {
    let family = "👨‍👩‍👧‍👦"
    #expect(ScreenGrounding.firstNonemptyLabel([family + " help"], limit: 1) == family)
    let long = ScreenGrounding.firstNonemptyLabel([String(repeating: family, count: 300)])
    #expect(long.count < 180)
    #expect(long.utf8.count <= 2_048)
    #expect(long.allSatisfy { String($0) == family })
    let oversizedCluster = "a" + String(repeating: "\u{0301}", count: 3_000)
    #expect(ScreenGrounding.firstNonemptyLabel([oversizedCluster, "Useful help"]) == "Useful help")
  }

  @Test func axRectConvertsNegativeOriginDisplayAndCaptureCrop() throws {
    let display = CGRect(x: -1_920, y: -200, width: 1_920, height: 1_080)
    // AppKit rectangle (-1728,664,384,108), converted from AX's primary-top axis.
    let ax = CGRect(x: -1_728, y: 308, width: 384, height: 108)
    let result = try #require(
      ScreenGrounding.normalizedAXRect(ax, primaryTop: 1_080, sourceRect: display))
    expectRect(result, equals: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.1))

    let crop = CGRect(x: -1_800, y: 500, width: 800, height: 400)
    let cropped = try #require(
      ScreenGrounding.normalizedAXRect(ax, primaryTop: 1_080, sourceRect: crop))
    expectRect(cropped, equals: CGRect(x: 0.09, y: 0.32, width: 0.48, height: 0.27))
  }

  @Test func axRectSupportsDisplaysAbovePrimaryAndCompleteEdgeTargets() throws {
    let source = CGRect(x: 100, y: 1_080, width: 1_600, height: 900)
    let entire = try #require(
      ScreenGrounding.normalizedAXRect(
        CGRect(x: 100, y: -900, width: 1_600, height: 900), primaryTop: 1_080, sourceRect: source))
    #expect(entire == CGRect(x: 0, y: 0, width: 1, height: 1))
  }

  @Test func partiallyOutsideAndInvalidAxGeometryIsRejected() {
    let source = CGRect(x: 0, y: 0, width: 1_000, height: 800)
    let invalid: [CGRect] = [
      CGRect(x: -1, y: 20, width: 30, height: 30),
      CGRect(x: 990, y: 20, width: 30, height: 30),
      CGRect(x: 0, y: -1, width: 30, height: 30),
      CGRect(x: 0, y: 790, width: 30, height: 30),
      CGRect(x: 20, y: 20, width: -30, height: 30),
      CGRect(x: 20, y: 20, width: 30, height: 0),
      CGRect(x: Double.nan, y: 20, width: 30, height: 30),
      CGRect(x: 20, y: Double.infinity, width: 30, height: 30),
    ]
    for rect in invalid {
      #expect(ScreenGrounding.normalizedAXRect(rect, primaryTop: 800, sourceRect: source) == nil)
    }
    #expect(ScreenGrounding.normalizedAXRect(source, primaryTop: .nan, sourceRect: source) == nil)
    #expect(
      ScreenGrounding.normalizedAXRect(
        source, primaryTop: 800, sourceRect: CGRect(x: 0, y: 0, width: -1, height: 800)) == nil)
  }

  @Test func ocrRectFlipsVisionAxisAndRejectsPartialOrNonfiniteBoxes() throws {
    let result = try #require(
      ScreenGrounding.normalizedOCRRect(CGRect(x: 0.2, y: 0.65, width: 0.3, height: 0.15)))
    expectRect(result, equals: CGRect(x: 0.2, y: 0.2, width: 0.3, height: 0.15))
    #expect(
      ScreenGrounding.normalizedOCRRect(CGRect(x: 0, y: 0, width: 1, height: 1))
        == CGRect(x: 0, y: 0, width: 1, height: 1))
    for rect in [
      CGRect(x: -0.01, y: 0, width: 0.2, height: 0.2),
      CGRect(x: 0.9, y: 0, width: 0.2, height: 0.2),
      CGRect(x: 0, y: 0, width: 0.2, height: -0.2),
      CGRect(x: Double.infinity, y: 0, width: 0.2, height: 0.2),
    ] {
      #expect(ScreenGrounding.normalizedOCRRect(rect) == nil)
    }
  }

  @Test func idsAreDeterministicAndFrameScoped() {
    let id = ScreenGrounding.candidateID(frameID: frameID, index: 0)
    #expect(id == ScreenGrounding.candidateID(frameID: frameID, index: 0))
    #expect(id != ScreenGrounding.candidateID(frameID: UUID(), index: 0))
    #expect(id != ScreenGrounding.candidateID(frameID: frameID, index: 1))
    #expect(id.utf8.count <= 100)
  }

  @Test func selectionUsesNativeGeometryAndPreservesInstructionAndPresentation() throws {
    let native = candidate()
    var guessed = target(id: native.id)
    guessed.x = .nan
    guessed.y = -99
    guessed.width = 8
    guessed.height = .infinity
    let resolved = try ScreenGrounding.resolve(guessed, candidates: [native], frameID: frameID)
    #expect(resolved.x == native.x && resolved.y == native.y)
    #expect(resolved.width == native.width && resolved.height == native.height)
    #expect(resolved.instruction == guessed.instruction)
    #expect(resolved.label == guessed.label && resolved.shape == guessed.shape)
    #expect(resolved.advanceOn == guessed.advanceOn && resolved.candidateID == native.id)
  }

  @Test func visualFallbackWithoutCandidateIdRemainsForExistingValidation() throws {
    var original = target(id: nil)
    original.x = .nan
    let result = try ScreenGrounding.resolve(original, candidates: [], frameID: frameID)
    #expect(result.x.isNaN)
    #expect(result.instruction == original.instruction && result.candidateID == nil)
  }

  @Test func unknownStaleMalformedAndDuplicateSelectionsReject() {
    let native = candidate()
    for id in [
      ScreenGrounding.candidateID(frameID: frameID, index: 999),
      ScreenGrounding.candidateID(frameID: UUID(), index: 0),
      "", String(repeating: "x", count: 101),
      ScreenGrounding.candidateID(frameID: frameID, index: -1),
      native.id + "suffix",
    ] {
      #expect(throws: ProviderError.self) {
        try ScreenGrounding.resolve(target(id: id), candidates: [native], frameID: frameID)
      }
    }
    #expect(throws: ProviderError.self) {
      try ScreenGrounding.resolve(
        target(id: native.id), candidates: [native, native], frameID: frameID)
    }
  }

  @Test(arguments: [nil, "click"] as [String?])
  func clicksNeedEnabledActionableAccessibility(_ advanceOn: String?) {
    for native in [
      candidate(enabled: false), candidate(actionable: false), candidate(source: .ocr),
    ] {
      #expect(throws: ProviderError.self) {
        try ScreenGrounding.resolve(
          target(id: native.id, advanceOn: advanceOn), candidates: [native], frameID: frameID)
      }
    }
  }

  @Test func manualMarksExplainNonactionableAndDisabledElementsWithoutClickAuthority() throws {
    for native in [
      candidate(actionable: false), candidate(source: .ocr, actionable: false),
      candidate(enabled: false, actionable: false),
    ] {
      let result = try ScreenGrounding.resolve(
        target(id: native.id, advanceOn: "manual"), candidates: [native], frameID: frameID)
      #expect(result.x == native.x && result.width == native.width)
    }
    #expect(throws: ProviderError.self) {
      try ScreenGrounding.resolve(
        target(id: candidate().id, advanceOn: "hover"), candidates: [candidate()], frameID: frameID)
    }
  }

  @Test func malformedCandidateGeometryCannotBecomeAuthority() {
    for box in [
      CGRect(x: 0.9, y: 0.2, width: 0.2, height: 0.1),
      CGRect(x: 0.1, y: 0.2, width: -0.2, height: 0.1),
      CGRect(x: Double.nan, y: 0.2, width: 0.2, height: 0.1),
    ] {
      let invalid = candidate(box: box)
      #expect(throws: ProviderError.self) {
        try ScreenGrounding.resolve(target(id: invalid.id), candidates: [invalid], frameID: frameID)
      }
    }
  }

  @Test func candidateEnvelopeRoundTripsUnderBothBudgets() throws {
    let input = (0..<200).map { candidate(index: $0, label: "Control \($0)") }
    let retained = ScreenGrounding.boundedCandidates(input, frameID: frameID)
    #expect(retained.count == ScreenGrounding.maximumCandidates)
    #expect(retained.map(\.id) == input.prefix(120).map(\.id))
    let context = ScreenGrounding.evidenceContext(candidates: retained, frameID: frameID)
    #expect(context.utf8.count <= ScreenGrounding.maximumContextBytes)
    let decoded = try JSONDecoder().decode(Envelope.self, from: Data(context.utf8))
    #expect(decoded.frameID == frameID)
    #expect(decoded.coordinateSpace == "capture.normalized.topLeft")
    #expect(decoded.candidates == retained)
  }

  @Test func unicodeAndEscapedLabelsRespectActualJsonByteBudget() throws {
    let input = (0..<150).map {
      candidate(index: $0, label: String(repeating: "👨‍👩‍👧‍👦\n\"", count: 100))
    }
    let retained = ScreenGrounding.boundedCandidates(input, frameID: frameID)
    #expect(!retained.isEmpty && retained.count < 120)
    #expect(retained.allSatisfy { $0.label.count <= 180 && $0.label.utf8.count <= 2_048 })
    let context = ScreenGrounding.evidenceContext(candidates: retained, frameID: frameID)
    #expect(context.utf8.count <= 24_000)
    let decoded = try JSONDecoder().decode(Envelope.self, from: Data(context.utf8))
    #expect(decoded.candidates == retained)
  }

  @Test func boundedTableOmitsStaleDuplicateAndOffscopeCandidatesWithoutReassigningIds() {
    let good = candidate(index: 4)
    let duplicate = candidate(index: 0)
    let stale = ScreenGroundingCandidate(
      id: ScreenGrounding.candidateID(frameID: UUID(), index: 2), source: .accessibility,
      role: "AXButton", label: "Stale", enabled: true, actionable: true, x: 0, y: 0, width: 0.2,
      height: 0.1)
    let bad = candidate(index: 3, box: CGRect(x: -0.1, y: 0, width: 0.2, height: 0.1))
    let retained = ScreenGrounding.boundedCandidates(
      [duplicate, stale, duplicate, bad, good], frameID: frameID)
    #expect(retained == [good])
  }

  private struct Envelope: Decodable {
    let frameID: UUID
    let coordinateSpace: String
    let candidates: [ScreenGroundingCandidate]
  }

  private func candidate(
    index: Int = 0, source: ScreenGroundingCandidate.Source = .accessibility,
    enabled: Bool = true, actionable: Bool = true, label: String = "New conversation",
    box: CGRect = CGRect(x: 0.1, y: 0.2, width: 0.05, height: 0.04)
  ) -> ScreenGroundingCandidate {
    ScreenGroundingCandidate(
      id: ScreenGrounding.candidateID(frameID: frameID, index: index), source: source,
      role: "AXButton", label: label, enabled: enabled, actionable: actionable,
      x: box.origin.x, y: box.origin.y, width: box.size.width, height: box.size.height)
  }

  private func target(id: String?, advanceOn: String? = "click") -> ProviderTarget {
    ProviderTarget(
      x: 0.8, y: 0.7, width: 0.1, height: 0.2, instruction: "Select the named control.",
      label: "New item", shape: "ellipse", advanceOn: advanceOn, candidateID: id)
  }

  private func expectRect(_ actual: CGRect, equals expected: CGRect) {
    #expect(abs(actual.origin.x - expected.origin.x) < 0.000_001)
    #expect(abs(actual.origin.y - expected.origin.y) < 0.000_001)
    #expect(abs(actual.size.width - expected.size.width) < 0.000_001)
    #expect(abs(actual.size.height - expected.size.height) < 0.000_001)
  }
}
