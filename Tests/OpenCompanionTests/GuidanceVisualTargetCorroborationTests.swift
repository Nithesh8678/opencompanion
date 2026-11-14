import CoreGraphics
import Foundation
import ImageIO
import Testing

@testable import OpenCompanion

/// Authored images/native tables only. These checks neither capture the desktop
/// nor establish persistent AX identity, model correctness or task completion.
struct GuidanceVisualTargetCorroborationTests {
  @Test func unrelatedAnimationCanKeepAnExactlyCorroboratedCurrentNativeControl() async throws {
    let original = try evidence(image: image(), revision: 1, age: 2)
    let current = try evidence(image: image(outsideChange: true), revision: 2)
    let proposed = target(in: original)
    let verified = try await ScreenTargetFreshness.verifiedStableAccessibilityTarget(
      target: proposed, original: original, refreshed: current)
    #expect(verified.candidateID == current.groundingCandidates[0].id)
    #expect(verified.candidateID != proposed.candidateID)
    #expect(verified.x == 0.25 && verified.y == 0.25)
    #expect(verified.width == 0.25 && verified.height == 0.2)
    #expect(verified.instruction == proposed.instruction && verified.advanceOn == "click")
    #expect(original.revision == 1 && original.frameID != current.frameID)
    // The existing general freshness path intentionally retains its stronger
    // global image requirement; this new native-only path does not alter it.
    let resolved = try original.resolvingTarget(proposed)
    do {
      _ = try await ScreenTargetFreshness.verified(
        target: resolved,
        original: original, refreshed: current)
      Issue.record("Unrelated global changes bypassed the original full-scene gate.")
    } catch is ProviderError {}
    // A subsequent proof uses the genuine newly returned frame-scoped ID.
    let next = try evidence(image: image(), revision: 3)
    let repeated = try await ScreenTargetFreshness.verifiedStableAccessibilityTarget(
      target: verified, original: current, refreshed: next)
    #expect(repeated.candidateID == next.groundingCandidates[0].id)
  }

  @Test func changedTargetPixelsCannotHideBehindUnchangedNativeLabelsAndBounds() async throws {
    let original = try evidence(image: image(), revision: 1, age: 2)
    for changed in [
      try image(control: .init(red: 0.2, green: 0.2, blue: 0.2, alpha: 1)),
      try image(localTargetChange: true),
      try image(control: .init(red: 0.8, green: 0, blue: 0, alpha: 1)),
    ] {
      let fresh = try evidence(image: changed, revision: 2)
      await rejects(target(in: original), original, fresh)
    }
  }

  @Test func nativeCounterpartMustHaveExactRoleLabelStateAndBoundsWithoutAmbiguity() async throws {
    let original = try evidence(image: image(), revision: 1, age: 2)
    let current = try evidence(image: image(outsideChange: true), revision: 2)
    let candidate = current.groundingCandidates[0]
    var variants: [ScreenGroundingCandidate] = [
      copy(candidate, role: "AXLink"), copy(candidate, label: "Different control"),
      copy(candidate, enabled: false), copy(candidate, actionable: false),
      copy(candidate, x: candidate.x + 0.01), copy(candidate, width: candidate.width + 0.01),
      copy(candidate, id: ScreenGrounding.candidateID(frameID: original.frameID, index: 0)),
    ]
    variants.append(copy(candidate, source: .ocr))
    for changed in variants {
      var frame = current
      frame.groundingCandidates = [changed]
      await rejects(target(in: original), original, frame)
    }
    for duplicate in [
      candidate,
      copy(
        candidate,
        id: ScreenGrounding.candidateID(frameID: current.frameID, index: 1)),
    ] {
      var frame = current
      frame.groundingCandidates.append(duplicate)
      await rejects(target(in: original), original, frame)
    }
    var sourceDuplicate = original
    sourceDuplicate.groundingCandidates.append(original.groundingCandidates[0])
    await rejects(target(in: original), sourceDuplicate, current)
    var disabledSource = original
    disabledSource.groundingCandidates = [copy(original.groundingCandidates[0], enabled: false)]
    var disabledCurrent = current
    disabledCurrent.groundingCandidates = [copy(candidate, enabled: false)]
    await rejects(target(in: original), disabledSource, disabledCurrent)
  }

  @Test func imageOnlyOCRAndUnknownIDsCannotEnterTheNativeOnlyPath() async throws {
    let original = try evidence(image: image(), revision: 1, age: 2)
    let current = try evidence(image: image(), revision: 2)
    var pixels = target(in: original)
    pixels.candidateID = nil
    pixels.pixelBounds = .init(x: 80, y: 50, width: 80, height: 40)
    await rejects(pixels, original, current)
    pixels.pixelBounds = nil
    await rejects(pixels, original, current)
    var unknown = target(in: original)
    unknown.candidateID = ScreenGrounding.candidateID(frameID: original.frameID, index: 99)
    await rejects(unknown, original, current)
    var ocr = original
    ocr.groundingCandidates = [copy(original.groundingCandidates[0], source: .ocr)]
    var manual = target(in: original)
    manual.advanceOn = "manual"
    await rejects(manual, ocr, current)
  }

  @Test func scopeDatesRevisionsAndHeaderMetadataRemainStrict() async throws {
    let original = try evidence(image: image(), revision: 1, age: 2)
    let current = try evidence(image: image(), revision: 2)
    var variants: [OpenCompanion.ScreenEvidence] = []
    var frame = current
    frame.frameID = original.frameID
    variants.append(frame)
    frame = current
    frame.revision = original.revision
    variants.append(frame)
    frame = current
    frame.capturedAt = original.capturedAt - 0.1
    variants.append(frame)
    frame = current
    frame.capturedAt = .nan
    variants.append(frame)
    frame = current
    frame.capturedAt = ProcessInfo.processInfo.systemUptime + 10
    variants.append(frame)
    frame = current
    frame.capturedAt = ProcessInfo.processInfo.systemUptime - 16
    variants.append(frame)
    frame = current
    frame.foregroundPID += 1
    variants.append(frame)
    frame = current
    frame.displayID += 1
    variants.append(frame)
    frame = current
    frame.windowID = 43
    variants.append(frame)
    frame = current
    frame.capturedWindowBounds?.origin.x += 1
    variants.append(frame)
    frame = current
    frame.screenRect.origin.x += 1
    variants.append(frame)
    frame = current
    frame.imageWidth = 0
    variants.append(frame)
    frame = current
    frame.imageHeight = 199
    variants.append(frame)
    frame = current
    frame.image = Data("bad JPEG".utf8)
    variants.append(frame)
    for variant in variants { await rejects(target(in: original), original, variant) }
  }

  @Test func cancelledCorroborationCannotReturnFreshAuthority() async throws {
    let original = try evidence(image: image(), revision: 1, age: 2)
    let current = try evidence(image: image(outsideChange: true), revision: 2)
    let proposed = target(in: original)
    let (stream, continuation) = AsyncStream<Void>.makeStream()
    let task = Task {
      for await _ in stream { break }
      return try await ScreenTargetFreshness.verifiedStableAccessibilityTarget(
        target: proposed, original: original, refreshed: current)
    }
    task.cancel()
    continuation.finish()
    do {
      _ = try await task.value
      Issue.record("Cancelled local corroboration returned current target authority.")
    } catch is CancellationError {}
  }

  private func target(in frame: OpenCompanion.ScreenEvidence) -> ProviderTarget {
    .init(
      x: 0, y: 0, width: 0, height: 0, instruction: "Choose the visible fixture control.",
      label: "Open", shape: "ellipse", advanceOn: "click",
      candidateID: frame.groundingCandidates[0].id)
  }

  private func evidence(image: Data, revision: UInt64, age: Double = 0.1) throws
    -> OpenCompanion.ScreenEvidence
  {
    let frameID = UUID()
    return .init(
      frameID: frameID, revision: revision,
      capturedAt: ProcessInfo.processInfo.systemUptime - age,
      displayID: 7, foregroundPID: 421, foregroundName: "Authored public fixture",
      screenRect: CGRect(x: -640, y: 80, width: 320, height: 200), windowID: 42,
      capturedWindowBounds: CGRect(x: -640, y: 80, width: 320, height: 200), image: image,
      semanticText: "",
      groundingCandidates: [
        .init(
          id: ScreenGrounding.candidateID(frameID: frameID, index: 0), source: .accessibility,
          role: "AXButton", label: "Open", enabled: true, actionable: true,
          x: 0.25, y: 0.25, width: 0.25, height: 0.2)
      ], imageWidth: 320, imageHeight: 200)
  }

  private func copy(
    _ value: ScreenGroundingCandidate, id: String? = nil,
    source: ScreenGroundingCandidate.Source? = nil, role: String? = nil, label: String? = nil,
    enabled: Bool? = nil, actionable: Bool? = nil, x: Double? = nil, width: Double? = nil
  )
    -> ScreenGroundingCandidate
  {
    .init(
      id: id ?? value.id, source: source ?? value.source, role: role ?? value.role,
      label: label ?? value.label, enabled: enabled ?? value.enabled,
      actionable: actionable ?? value.actionable, x: x ?? value.x, y: value.y,
      width: width ?? value.width, height: value.height)
  }

  private func rejects(
    _ target: ProviderTarget, _ original: OpenCompanion.ScreenEvidence,
    _ current: OpenCompanion.ScreenEvidence
  ) async {
    do {
      _ = try await ScreenTargetFreshness.verifiedStableAccessibilityTarget(
        target: target, original: original, refreshed: current)
      Issue.record("Changed or ungrounded native target was corroborated.")
    } catch is ProviderError {
      // Failure preserves the old immutable frame and grants no replacement.
    } catch { Issue.record("Expected provider refusal, received \(error).") }
  }

  private func image(
    outsideChange: Bool = false, control: CGColor? = nil,
    localTargetChange: Bool = false
  ) throws -> Data {
    let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
    let context = try #require(
      CGContext(
        data: nil, width: 320, height: 200,
        bitsPerComponent: 8, bytesPerRow: 320 * 4, space: space,
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
    context.setFillColor(CGColor(gray: 0.12, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 320, height: 200))
    context.setFillColor(control ?? CGColor(gray: 0.9, alpha: 1))
    context.fill(CGRect(x: 80, y: 110, width: 80, height: 40))
    if outsideChange {
      context.setFillColor(CGColor(gray: 0.9, alpha: 1))
      context.fill(CGRect(x: 240, y: 20, width: 60, height: 150))
    }
    if localTargetChange {
      context.setFillColor(CGColor(gray: 0.1, alpha: 1))
      context.fill(CGRect(x: 115, y: 125, width: 10, height: 10))
    }
    let rendered = try #require(context.makeImage())
    let data = NSMutableData()
    let destination = try #require(
      CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil))
    CGImageDestinationAddImage(
      destination, rendered,
      [kCGImageDestinationLossyCompressionQuality: 1.0] as CFDictionary)
    #expect(CGImageDestinationFinalize(destination))
    return data as Data
  }
}
