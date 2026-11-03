import CoreGraphics
import Foundation
import ImageIO
import Testing

@testable import OpenCompanion

struct ScreenTargetFreshnessTests {
  @Test func identicalAuthoredPixelsAdmitResolvedGeometryWithoutRefreshingOldEvidence() async throws
  {
    let image = try authoredImage()
    let old = evidence(image: image, age: 30)
    let fresh = evidence(image: image)
    let originalDate = old.capturedAt
    let proposed = target()
    let result = try await ScreenTargetFreshness.verified(
      target: proposed, original: old, refreshed: fresh)
    #expect(result.candidateID == nil)
    #expect(result.x == proposed.x && result.y == proposed.y)
    #expect(result.width == proposed.width && result.height == proposed.height)
    #expect(result.instruction == proposed.instruction && result.label == proposed.label)
    #expect(result.shape == proposed.shape && result.advanceOn == proposed.advanceOn)
    #expect(old.capturedAt == originalDate && old.frameID != fresh.frameID)
  }

  @Test func movedRemovedAndDisabledTargetPixelsReject() async throws {
    let old = evidence(image: try authoredImage(), age: 30)
    for image in [
      try authoredImage(offset: 14), try authoredImage(showControl: false),
      try authoredImage(controlGray: 0.25),
    ] {
      await expectRejected(original: old, refreshed: evidence(image: image))
    }
  }

  @Test func smallLocalTargetChangeRejectsEvenWhenMostOfTheFrameIsIdentical() async throws {
    let old = evidence(image: try authoredImage(), age: 30)
    let fresh = evidence(image: try authoredImage(localChange: true))
    await expectRejected(original: old, refreshed: fresh)
  }

  @Test func changedSceneOutsideTargetRejects() async throws {
    let old = evidence(image: try authoredImage(), age: 30)
    let fresh = evidence(image: try authoredImage(backgroundGray: 0.7))
    await expectRejected(original: old, refreshed: fresh)
  }

  @Test func coloredTargetStateChangeCannotHideBehindSimilarLuminance() async throws {
    let red = try authoredImage(controlColor: CGColor(red: 0.8, green: 0, blue: 0, alpha: 1))
    let green = try authoredImage(controlColor: CGColor(red: 0, green: 0.24, blue: 0, alpha: 1))
    await expectRejected(original: evidence(image: red, age: 30), refreshed: evidence(image: green))
  }

  @Test func sourceIdentityAndCaptureScopeMustAllMatch() async throws {
    let image = try authoredImage()
    let old = evidence(image: image, age: 30)
    let fresh = evidence(image: image)
    var variants: [ScreenEvidence] = []
    var changed = fresh
    changed.frameID = old.frameID
    variants.append(changed)
    changed = fresh
    changed.foregroundPID += 1
    variants.append(changed)
    changed = fresh
    changed.displayID += 1
    variants.append(changed)
    changed = fresh
    changed.windowID = 44
    variants.append(changed)
    changed = fresh
    changed.screenRect.origin.x += 1
    variants.append(changed)
    changed = fresh
    changed.screenRect.size.width += 1
    variants.append(changed)
    for variant in variants { await expectRejected(original: old, refreshed: variant) }
  }

  @Test func staleFutureAndNonfiniteTimesReject() async throws {
    let image = try authoredImage()
    let old = evidence(image: image, age: 30)
    for age in [15.1, 30, -10, Double.nan, Double.infinity] {
      await expectRejected(original: old, refreshed: evidence(image: image, age: age))
    }
    let fresh = evidence(image: image)
    for age in [90.1, -10, Double.nan, Double.infinity] {
      await expectRejected(original: evidence(image: image, age: age), refreshed: fresh)
    }
  }

  @Test func invalidImageFormatSizeDimensionsAndPublishedMetadataReject() async throws {
    let image = try authoredImage()
    let old = evidence(image: image, age: 30)
    let invalidImages = [
      Data(), Data("Not an image".utf8), Data(repeating: 0, count: 12_000_001),
      try authoredImage(width: 321), try authoredImage(format: "public.png"),
    ]
    for invalid in invalidImages {
      await expectRejected(original: old, refreshed: evidence(image: invalid))
    }
    for dimensions in [(319, 200), (320, 199), (-1, 200)] {
      var fresh = evidence(image: image)
      fresh.imageWidth = dimensions.0
      fresh.imageHeight = dimensions.1
      await expectRejected(original: old, refreshed: fresh)
    }
    var invalidOriginal = old
    invalidOriginal.imageWidth = 1
    await expectRejected(original: invalidOriginal, refreshed: evidence(image: image))
  }

  @Test func malformedTargetAndNegativeRawCaptureDimensionsReject() async throws {
    let image = try authoredImage()
    let old = evidence(image: image, age: 30)
    let fresh = evidence(image: image)
    for box in [
      CGRect(x: -0.1, y: 0.2, width: 0.2, height: 0.2),
      CGRect(x: 0.9, y: 0.2, width: 0.2, height: 0.2),
      CGRect(x: 0.2, y: 0.2, width: -0.2, height: 0.2),
      CGRect(x: Double.nan, y: 0.2, width: 0.2, height: 0.2),
    ] {
      var proposed = target()
      proposed.x = box.origin.x
      proposed.y = box.origin.y
      proposed.width = box.size.width
      proposed.height = box.size.height
      await expectRejected(target: proposed, original: old, refreshed: fresh)
    }
    var badOld = old
    var badFresh = fresh
    badOld.screenRect = CGRect(x: 0, y: 0, width: -320, height: 200)
    badFresh.screenRect = badOld.screenRect
    await expectRejected(original: badOld, refreshed: badFresh)
  }

  @Test func cancelledCallerCannotReceiveVerifiedTarget() async throws {
    let image = try authoredImage()
    let old = evidence(image: image, age: 30)
    let fresh = evidence(image: image)
    let proposed = target()
    let (stream, continuation) = AsyncStream<Void>.makeStream()
    let task = Task {
      for await _ in stream { break }
      return try await ScreenTargetFreshness.verified(
        target: proposed, original: old, refreshed: fresh)
    }
    task.cancel()
    continuation.finish()
    do {
      _ = try await task.value
      Issue.record("A cancelled freshness check returned a target.")
    } catch is CancellationError {
      // The cancellation must survive the detached verification boundary.
    } catch {
      Issue.record("Expected cancellation, received \(error).")
    }
  }

  private func evidence(image: Data, age: Double = 0.1) -> ScreenEvidence {
    ScreenEvidence(
      frameID: UUID(), revision: 1, capturedAt: ProcessInfo.processInfo.systemUptime - age,
      displayID: 7, foregroundPID: 123, foregroundName: "Authored public fixture",
      screenRect: CGRect(x: -640, y: 80, width: 320, height: 200), image: image,
      semanticText: "Authored pixels only", imageWidth: 320, imageHeight: 200)
  }

  private func target() -> ProviderTarget {
    ProviderTarget(
      x: 0.25, y: 0.25, width: 0.25, height: 0.2, instruction: "Select the fixture control.",
      label: "New item", shape: "ellipse", advanceOn: "click", candidateID: "original-resolved-ID")
  }

  private func expectRejected(
    target proposed: ProviderTarget? = nil, original: ScreenEvidence, refreshed: ScreenEvidence
  ) async {
    do {
      _ = try await ScreenTargetFreshness.verified(
        target: proposed ?? target(), original: original, refreshed: refreshed)
      Issue.record("Changed or invalid evidence was admitted.")
    } catch is ProviderError {
      // Deliberately reject rather than weakening the target admission guard.
    } catch {
      Issue.record("Expected an actionable provider error, received \(error).")
    }
  }

  private func authoredImage(
    width: Int = 320, backgroundGray: CGFloat = 0.13, controlGray: CGFloat = 0.9,
    controlColor: CGColor? = nil, offset: CGFloat = 0, showControl: Bool = true,
    localChange: Bool = false, format: String = "public.jpeg"
  ) throws -> Data {
    let height = 200
    let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
    let context = try #require(
      CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
        space: space,
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
    context.setFillColor(CGColor(gray: backgroundGray, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    context.setFillColor(CGColor(gray: 0.35, alpha: 1))
    context.fill(CGRect(x: 20, y: 170, width: 260, height: 5))
    if showControl {
      context.setFillColor(controlColor ?? CGColor(gray: controlGray, alpha: 1))
      context.fill(CGRect(x: 80 + offset, y: 110, width: 80, height: 40))
    }
    if localChange {
      context.setFillColor(CGColor(gray: 0.05, alpha: 1))
      context.fill(CGRect(x: 116, y: 126, width: 8, height: 8))
    }
    let image = try #require(context.makeImage())
    let data = NSMutableData()
    let destination = try #require(
      CGImageDestinationCreateWithData(data, format as CFString, 1, nil))
    CGImageDestinationAddImage(
      destination, image, [kCGImageDestinationLossyCompressionQuality: 1.0] as CFDictionary)
    #expect(CGImageDestinationFinalize(destination))
    return data as Data
  }
}
