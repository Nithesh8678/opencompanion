import AppKit
import CoreGraphics
import Foundation
import Testing

@testable import OpenCompanion

/// Authored offscreen bitmaps and injected capture/ownership callbacks only.
/// This verifies the selected-frame handoff, not model input or native capture.
@Suite @MainActor struct SelectedGuidanceEvidenceRefreshTests {
  @Test(arguments: [0.25, 14.5])
  func evenAYoungSelectionUsesExactlyOneNewImageAndNewSemanticCandidates(_ age: Double)
    async throws
  {
    let original = try frame(capturedAt: 1_000 - age)
    let fresh = try frame(capturedAt: 1_000, revision: 2, changedPixels: true)
    var captures = 0
    let result = try await SelectedGuidanceEvidenceRefresh.capture(
      original: original,
      refresh: { passedOriginal in
        captures += 1
        #expect(ScreenEvidenceIdentity(original).matches(passedOriginal))
        #expect(passedOriginal.image == original.image)
        return fresh
      }, stillOwned: { true }, now: { 1_000 })

    #expect(captures == 1 && result.frameID == fresh.frameID && result.frameID != original.frameID)
    #expect(result.revision == fresh.revision && result.capturedAt == fresh.capturedAt)
    #expect(result.image == fresh.image && result.image != original.image)
    #expect(
      result.semanticText == fresh.semanticText && result.semanticText != original.semanticText)
    #expect(result.groundingCandidates == fresh.groundingCandidates)
    #expect(
      Set(result.groundingCandidates.map(\.id)).isDisjoint(
        with: original.groundingCandidates.map(\.id)))
    #expect(
      result.foregroundPID == original.foregroundPID && result.displayID == original.displayID)
    #expect(result.windowID == original.windowID && result.screenRect == original.screenRect)
  }

  @Test func aRegionOrDisplayScopeIsNotReplacedByThePointerOrAWindow() async throws {
    var original = try frame(capturedAt: 999)
    original.windowID = nil
    var fresh = try frame(capturedAt: 1_000, revision: 2)
    fresh.windowID = nil
    var captures = 0
    let result = try await SelectedGuidanceEvidenceRefresh.capture(
      original: original,
      refresh: { scope in
        captures += 1
        #expect(scope.windowID == nil && scope.screenRect == original.screenRect)
        return fresh
      }, stillOwned: { true }, now: { 1_000 })
    #expect(captures == 1 && result.windowID == nil && result.screenRect == original.screenRect)
    #expect(
      result.displayID == original.displayID && result.foregroundPID == original.foregroundPID)
  }

  @Test func anyRefreshedScopeChangeRefusesWithoutAnOldImageFallback() async throws {
    let original = try frame(capturedAt: 999)
    let fresh = try frame(capturedAt: 1_000, revision: 2)
    var wrongPID = fresh
    wrongPID.foregroundPID += 1
    var wrongDisplay = fresh
    wrongDisplay.displayID += 1
    var wrongWindow = fresh
    wrongWindow.windowID = 43
    var removedWindow = fresh
    removedWindow.windowID = nil
    var moved = fresh
    moved.screenRect = moved.screenRect.offsetBy(dx: 1, dy: 0)
    var resized = fresh
    resized.screenRect.size.width += 1
    var captures = 0
    for changed in [wrongPID, wrongDisplay, wrongWindow, removedWindow, moved, resized] {
      await #expect(throws: ProviderError.self) {
        try await SelectedGuidanceEvidenceRefresh.capture(
          original: original,
          refresh: { _ in
            captures += 1
            return changed
          },
          stillOwned: { true }, now: { 1_000 })
      }
    }
    #expect(captures == 6)
  }

  @Test func invalidOriginalGeometryAndAuthorityNeverStartCapture() async throws {
    let original = try frame(capturedAt: 999)
    let fresh = try frame(capturedAt: 1_000, revision: 2)
    var negative = original
    negative.screenRect.size.width = -320
    var empty = original
    empty.screenRect.size.height = 0
    var nonfinite = original
    nonfinite.screenRect.origin.x = .nan
    var oversized = original
    oversized.screenRect.size.width = 100_001
    var noPID = original
    noPID.foregroundPID = 0
    var noDisplay = original
    noDisplay.displayID = 0
    var invalidWindow = original
    invalidWindow.windowID = 0
    var invalidDate = original
    invalidDate.capturedAt = .nan
    var captures = 0
    for invalid in [
      negative, empty, nonfinite, oversized, noPID, noDisplay, invalidWindow, invalidDate,
    ] {
      await #expect(throws: ProviderError.self) {
        try await SelectedGuidanceEvidenceRefresh.capture(
          original: invalid,
          refresh: { _ in
            captures += 1
            return fresh
          },
          stillOwned: { true }, now: { 1_000 })
      }
    }
    #expect(captures == 0)
  }

  @Test func frameIdentityRevisionAndTimeCannotBeRelabeledAsNew() async throws {
    let original = try frame(capturedAt: 999)
    let fresh = try frame(capturedAt: 1_000, revision: 2)
    var sameID = fresh
    sameID.frameID = original.frameID
    var sameRevision = fresh
    sameRevision.revision = original.revision
    var olderRevision = fresh
    olderRevision.revision = 0
    var olderDate = fresh
    olderDate.capturedAt = original.capturedAt - 1
    var futureDate = fresh
    futureDate.capturedAt = 1_001
    var invalidDate = fresh
    invalidDate.capturedAt = .infinity
    var captures = 0
    for invalid in [sameID, sameRevision, olderRevision, olderDate, futureDate, invalidDate] {
      await #expect(throws: ProviderError.self) {
        try await SelectedGuidanceEvidenceRefresh.capture(
          original: original,
          refresh: { _ in
            captures += 1
            return invalid
          },
          stillOwned: { true }, now: { 1_000 })
      }
    }
    #expect(captures == 6)
  }

  @Test func equalTimestampsAreAllowedOnlyWithNewIdentityAndIncreasingRevision() async throws {
    let original = try frame(capturedAt: 999)
    let fresh = try frame(capturedAt: 999, revision: 2)
    let result = try await SelectedGuidanceEvidenceRefresh.capture(
      original: original, refresh: { _ in fresh }, stillOwned: { true }, now: { 1_000 })
    #expect(result.capturedAt == original.capturedAt && result.frameID != original.frameID)
    #expect(result.revision > original.revision)
  }

  @Test func expiredFreshFrameOrAnInvalidClockCannotPassHandoff() async throws {
    let original = try frame(capturedAt: 970)
    let fresh = try frame(capturedAt: 985, revision: 2)
    var captures = 0
    for clock in [1_000, Double.nan, Double.infinity, -1] {
      await #expect(throws: ProviderError.self) {
        try await SelectedGuidanceEvidenceRefresh.capture(
          original: original,
          refresh: { _ in
            captures += 1
            return fresh
          },
          stillOwned: { true }, now: { clock })
      }
    }
    #expect(captures == 4)
  }

  @Test func malformedHeadersFormatsAndPublishedDimensionMismatchesAreRefused() async throws {
    let original = try frame(capturedAt: 999)
    let fresh = try frame(capturedAt: 1_000, revision: 2)
    var malformed = fresh
    malformed.image = Data([0, 1, 2])
    // This is a bounded header reader, not a complete JPEG pixel decoder.
    // Truncate the header itself; a partial pixel stream can retain valid dimensions.
    var truncated = fresh
    truncated.image = Data(fresh.image.prefix(8))
    var png = fresh
    png.image = try #require(bitmap(changed: true).representation(using: .png, properties: [:]))
    var wrongWidth = fresh
    wrongWidth.imageWidth += 1
    var missingWidth = fresh
    missingWidth.imageWidth = 0
    var missingHeight = fresh
    missingHeight.imageHeight = 0
    var captures = 0
    for invalid in [malformed, truncated, png, wrongWidth, missingWidth, missingHeight] {
      await #expect(throws: ProviderError.self) {
        try await SelectedGuidanceEvidenceRefresh.capture(
          original: original,
          refresh: { _ in
            captures += 1
            return invalid
          },
          stillOwned: { true }, now: { 1_000 })
      }
    }
    #expect(captures == 6)
  }

  @Test func discardedOldPixelsAreNeverDecodedOrUsedAsFallback() async throws {
    var original = try frame(capturedAt: 999)
    original.image = Data([0])
    original.imageWidth = 0
    original.imageHeight = 0
    let fresh = try frame(capturedAt: 1_000, revision: 2, changedPixels: true)
    let result = try await SelectedGuidanceEvidenceRefresh.capture(
      original: original, refresh: { _ in fresh }, stillOwned: { true }, now: { 1_000 })
    #expect(result.image == fresh.image && result.imageWidth == 320 && result.imageHeight == 200)
  }

  @Test func captureFailureIsPropagatedOnceWithoutRetryOrOldEvidence() async throws {
    let original = try frame(capturedAt: 999)
    var captures = 0
    await #expect(throws: ProbeFailure.capture) {
      try await SelectedGuidanceEvidenceRefresh.capture(
        original: original,
        refresh: { _ in
          captures += 1
          throw ProbeFailure.capture
        },
        stillOwned: { true }, now: { 1_000 })
    }
    #expect(captures == 1)
  }

  @Test func lostOwnershipOrCancellationBeforeCaptureStartsNoWork() async throws {
    let original = try frame(capturedAt: 999)
    let fresh = try frame(capturedAt: 1_000, revision: 2)
    var captures = 0
    await #expect(throws: CancellationError.self) {
      try await SelectedGuidanceEvidenceRefresh.capture(
        original: original,
        refresh: { _ in
          captures += 1
          return fresh
        },
        stillOwned: { false }, now: { 1_000 })
    }
    let task = Task { @MainActor in
      try await SelectedGuidanceEvidenceRefresh.capture(
        original: original,
        refresh: { _ in
          captures += 1
          return fresh
        },
        stillOwned: { true }, now: { 1_000 })
    }
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(captures == 0)
  }

  @Test func ownershipLostAcrossTheCaptureAwaitCannotPublish() async throws {
    let original = try frame(capturedAt: 999)
    let fresh = try frame(capturedAt: 1_000, revision: 2)
    let gate = SelectedRefreshGate()
    var owned = true
    var captures = 0
    var published: OpenCompanion.ScreenEvidence?
    let task = Task { @MainActor in
      let result = try await SelectedGuidanceEvidenceRefresh.capture(
        original: original,
        refresh: { _ in
          captures += 1
          return try await gate.capture()
        },
        stillOwned: { owned }, now: { 1_000 })
      published = result
    }
    await gate.waitUntilStarted()
    owned = false
    await gate.finish(fresh)
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(captures == 1 && published == nil)
  }

  @Test func cancellationAcrossTheCaptureAwaitCannotPublish() async throws {
    let original = try frame(capturedAt: 999)
    let fresh = try frame(capturedAt: 1_000, revision: 2)
    let gate = SelectedRefreshGate()
    var captures = 0
    var published: OpenCompanion.ScreenEvidence?
    let task = Task { @MainActor in
      let result = try await SelectedGuidanceEvidenceRefresh.capture(
        original: original,
        refresh: { _ in
          captures += 1
          return try await gate.capture()
        },
        stillOwned: { true }, now: { 1_000 })
      published = result
    }
    await gate.waitUntilStarted()
    task.cancel()
    await gate.finish(fresh)
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(captures == 1 && published == nil)
  }

  private func frame(
    capturedAt: TimeInterval, revision: UInt64 = 1, changedPixels: Bool = false
  ) throws -> OpenCompanion.ScreenEvidence {
    let id = UUID()
    return OpenCompanion.ScreenEvidence(
      frameID: id, revision: revision, capturedAt: capturedAt, displayID: 1,
      foregroundPID: 421, foregroundName: "Public authored selection",
      screenRect: CGRect(x: -320, y: 100, width: 320, height: 200), windowID: 42,
      image: try #require(
        bitmap(changed: changedPixels).representation(
          using: .jpeg, properties: [.compressionFactor: 0.9])),
      semanticText: changedPixels ? "A fresh public panel is visible." : "The old public panel.",
      groundingCandidates: [
        .init(
          id: ScreenGrounding.candidateID(frameID: id, index: 0), source: .accessibility,
          role: "AXButton", label: changedPixels ? "Fresh public action" : "Old public action",
          enabled: true, actionable: true, x: changedPixels ? 0.55 : 0.125,
          y: 0.25, width: 0.25, height: 0.2)
      ], imageWidth: 320, imageHeight: 200)
  }

  private func bitmap(changed: Bool) throws -> NSBitmapImageRep {
    let context = try #require(
      CGContext(
        data: nil, width: 320, height: 200, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(CGColor(gray: changed ? 0.65 : 0.1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 320, height: 200))
    context.setFillColor(CGColor(gray: 0.9, alpha: 1))
    context.fill(CGRect(x: changed ? 176 : 40, y: 110, width: 80, height: 40))
    return NSBitmapImageRep(cgImage: try #require(context.makeImage()))
  }

  private enum ProbeFailure: Error, Equatable { case capture }
}

private actor SelectedRefreshGate {
  private var pending: CheckedContinuation<OpenCompanion.ScreenEvidence, any Error>?
  private var started: [CheckedContinuation<Void, Never>] = []

  func capture() async throws -> OpenCompanion.ScreenEvidence {
    try await withCheckedThrowingContinuation { continuation in
      pending = continuation
      for waiter in started { waiter.resume() }
      started.removeAll()
    }
  }

  func waitUntilStarted() async {
    if pending != nil { return }
    await withCheckedContinuation { started.append($0) }
  }

  func finish(_ evidence: OpenCompanion.ScreenEvidence) {
    pending?.resume(returning: evidence)
    pending = nil
  }
}
