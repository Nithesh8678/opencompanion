import CoreGraphics
import Foundation
import ImageIO
import Testing

@testable import OpenCompanion

/// Public bitmap fixtures and ownership closures only. No AppModel, windows,
/// real capture, focus changes, provider request, or user library is involved.
@Suite @MainActor struct ScreenGuidanceTurnBindingTests {
  @Test func freshSourceNeedsNoCaptureAndPreservesOriginalCandidateIdentity() async throws {
    let source = try frame(age: 0)
    let binding = ScreenGuidanceTurnBinding(source: source)
    let target = payload(source)
    var captures = 0
    let result = try await binding.prepare(
      target,
      refresh: {
        captures += 1
        return source
      }, stillOwned: { true })
    #expect(captures == 0 && !binding.didRefresh)
    #expect(result.candidateID == target.candidateID)
    #expect(result.x == 0.125 && result.y == 0.25)
    #expect(ScreenEvidenceIdentity(binding.current) == ScreenEvidenceIdentity(source))
  }

  @Test func thirtySecondResponseUsesRealNewFrameAndOneRefreshForLaterManualMark() async throws {
    let source = try frame(age: 30)
    let fresh = try frame(age: 0, revision: 2, image: source.image)
    let binding = ScreenGuidanceTurnBinding(source: source)
    var captures = 0
    let refresh: @MainActor @Sendable () async throws -> ScreenEvidence = {
      captures += 1
      return fresh
    }
    let first = try await binding.prepare(payload(source), refresh: refresh, stillOwned: { true })
    #expect(captures == 1 && binding.didRefresh)
    #expect(first.candidateID == nil)
    #expect(binding.current.frameID == fresh.frameID)
    #expect(binding.current.capturedAt == fresh.capturedAt)
    #expect(binding.source.frameID == source.frameID)
    #expect(binding.source.capturedAt == source.capturedAt)
    var manual = payload(source)
    manual.advanceOn = "manual"
    let next = try await binding.prepare(manual, refresh: refresh, stillOwned: { true })
    #expect(next.candidateID == nil && next.x == first.x && next.y == first.y)
    #expect(captures == 1 && binding.current.frameID == fresh.frameID)
  }

  @Test func invalidCandidateContentOrShapeCannotSpendCaptureBudget() async throws {
    let source = try frame(age: 30)
    var stale = payload(source)
    stale.candidateID = ScreenGrounding.candidateID(frameID: UUID(), index: 0)
    var oversized = payload(source)
    oversized.instruction = String(repeating: "x", count: 32_001)
    var label = payload(source)
    label.label = String(repeating: "x", count: 81)
    var shape = payload(source)
    shape.shape = "shell-command"
    var condition = payload(source)
    condition.advanceOn = "drag"
    for target in [stale, oversized, label, shape, condition] {
      let binding = ScreenGuidanceTurnBinding(source: source)
      var captures = 0
      await #expect(throws: (any Error).self) {
        try await binding.prepare(
          target,
          refresh: {
            captures += 1
            return source
          }, stillOwned: { true })
      }
      #expect(captures == 0 && !binding.didRefresh)
      #expect(binding.current.frameID == source.frameID)
    }
  }

  @Test func changedPixelsRejectWithoutPublishingAndCannotRecaptureAgain() async throws {
    let source = try frame(age: 30)
    let changed = try frame(age: 0, revision: 2, image: jpeg(movedControl: true))
    let binding = ScreenGuidanceTurnBinding(source: source)
    var captures = 0
    let refresh: @MainActor @Sendable () async throws -> ScreenEvidence = {
      captures += 1
      return changed
    }
    await #expect(throws: (any Error).self) {
      try await binding.prepare(payload(source), refresh: refresh, stillOwned: { true })
    }
    #expect(captures == 1 && binding.didRefresh)
    #expect(binding.current.frameID == source.frameID)
    await #expect(throws: (any Error).self) {
      try await binding.prepare(payload(source), refresh: refresh, stillOwned: { true })
    }
    #expect(captures == 1 && binding.current.frameID == source.frameID)
  }

  @Test func refreshFailureConsumesOnlyOneBudgetAndKeepsSource() async throws {
    let source = try frame(age: 30)
    let binding = ScreenGuidanceTurnBinding(source: source)
    var captures = 0
    let refresh: @MainActor @Sendable () async throws -> ScreenEvidence = {
      captures += 1
      throw ProviderError.message("Public refresh failure")
    }
    for _ in 0..<2 {
      await #expect(throws: (any Error).self) {
        try await binding.prepare(payload(source), refresh: refresh, stillOwned: { true })
      }
    }
    #expect(captures == 1 && binding.didRefresh)
    #expect(binding.current.frameID == source.frameID)
  }

  @Test func ownershipLossDuringCaptureCannotPublishTheFreshFrame() async throws {
    let source = try frame(age: 30)
    let fresh = try frame(age: 0, revision: 2, image: source.image)
    let binding = ScreenGuidanceTurnBinding(source: source)
    let gate = SuspendedGuidanceRefresh()
    var owned = true
    let task = Task { @MainActor in
      try await binding.prepare(
        payload(source), refresh: { try await gate.capture() }, stillOwned: { owned })
    }
    await gate.waitUntilStarted()
    owned = false
    await gate.finish(fresh)
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(binding.current.frameID == source.frameID && binding.didRefresh)
  }

  @Test func stopCancellationDuringCaptureCannotPublishOrAdmitTheTarget() async throws {
    let source = try frame(age: 30)
    let fresh = try frame(age: 0, revision: 2, image: source.image)
    let binding = ScreenGuidanceTurnBinding(source: source)
    let gate = SuspendedGuidanceRefresh()
    let task = Task { @MainActor in
      try await binding.prepare(
        payload(source), refresh: { try await gate.capture() }, stillOwned: { true })
    }
    await gate.waitUntilStarted()
    task.cancel()
    await gate.finish(fresh)
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(binding.current.frameID == source.frameID && binding.didRefresh)
  }

  @Test func finalOwnershipCheckPrecedesCurrentMutationAfterPixelVerification() async throws {
    let source = try frame(age: 30)
    let fresh = try frame(age: 0, revision: 2, image: source.image)
    let binding = ScreenGuidanceTurnBinding(source: source)
    var checks = 0
    await #expect(throws: CancellationError.self) {
      try await binding.prepare(
        payload(source), refresh: { fresh },
        stillOwned: {
          checks += 1
          #expect(binding.current.frameID == source.frameID)
          return checks < 3
        })
    }
    #expect(checks == 3 && binding.current.frameID == source.frameID)
  }

  @Test func changedApplicationIdentityAndFutureSourceFailClosed() async throws {
    let source = try frame(age: 30)
    var other = try frame(age: 0, revision: 2, image: source.image)
    other.foregroundPID += 1
    let binding = ScreenGuidanceTurnBinding(source: source)
    await #expect(throws: (any Error).self) {
      try await binding.prepare(payload(source), refresh: { other }, stillOwned: { true })
    }
    #expect(binding.current.frameID == source.frameID)
    let future = try frame(age: -30)
    let futureBinding = ScreenGuidanceTurnBinding(source: future)
    var captures = 0
    await #expect(throws: (any Error).self) {
      try await futureBinding.prepare(
        payload(future),
        refresh: {
          captures += 1
          return future
        }, stillOwned: { true })
    }
    #expect(captures == 0 && !futureBinding.didRefresh)
  }

  private func frame(age: TimeInterval, revision: UInt64 = 1, image: Data? = nil) throws
    -> ScreenEvidence
  {
    let id = UUID()
    return ScreenEvidence(
      frameID: id, revision: revision, capturedAt: ProcessInfo.processInfo.systemUptime - age,
      displayID: 1, foregroundPID: 421, foregroundName: "Public fixture",
      screenRect: CGRect(x: -320, y: 100, width: 320, height: 200), windowID: 42,
      image: try image ?? jpeg(), semanticText: "Public fixture only",
      groundingCandidates: [
        .init(
          id: ScreenGrounding.candidateID(frameID: id, index: 0), source: .accessibility,
          role: "AXButton", label: "New task", enabled: true, actionable: true,
          x: 0.125, y: 0.25, width: 0.25, height: 0.2)
      ], imageWidth: 320, imageHeight: 200)
  }

  private func payload(_ frame: ScreenEvidence) -> ProviderTarget {
    ProviderTarget(
      x: 0.8, y: 0.8, width: 0.1, height: 0.1, instruction: "Choose the visible control.",
      label: "New task", shape: "ellipse", advanceOn: "click",
      candidateID: ScreenGrounding.candidateID(frameID: frame.frameID, index: 0))
  }

  private func jpeg(movedControl: Bool = false) throws -> Data {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let context = try #require(
      CGContext(
        data: nil, width: 320, height: 200, bitsPerComponent: 8, bytesPerRow: 0,
        space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(CGColor(gray: 0.1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 320, height: 200))
    context.setFillColor(CGColor(gray: 0.9, alpha: 1))
    context.fill(CGRect(x: movedControl ? 200 : 40, y: 110, width: 80, height: 40))
    let image = try #require(context.makeImage())
    let bytes = NSMutableData()
    let destination = try #require(
      CGImageDestinationCreateWithData(bytes, "public.jpeg" as CFString, 1, nil))
    CGImageDestinationAddImage(
      destination, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
    #expect(CGImageDestinationFinalize(destination))
    return bytes as Data
  }
}

private actor SuspendedGuidanceRefresh {
  private var pending: CheckedContinuation<ScreenEvidence, any Error>?
  private var started: [CheckedContinuation<Void, Never>] = []

  func capture() async throws -> ScreenEvidence {
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

  func finish(_ evidence: ScreenEvidence) {
    pending?.resume(returning: evidence)
    pending = nil
  }
}
