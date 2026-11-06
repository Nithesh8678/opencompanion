import Foundation

/// Replace an explicitly selected screenshot before reasoning about its current
/// window/region. Content may change; the selected capture scope must not.
@MainActor enum SelectedGuidanceEvidenceRefresh {
  static func capture(
    original: ScreenEvidence,
    refresh: @MainActor (ScreenEvidence) async throws -> ScreenEvidence,
    stillOwned: @MainActor () -> Bool,
    now: @MainActor () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
  ) async throws -> ScreenEvidence {
    try requireOwnership(stillOwned)
    guard validSource(original) else { throw failure() }

    // Always refresh once, including a young original. This precedes model
    // input, so changed pixels are expected and need no similarity comparison.
    // The closure receives the original scope rather than a pointer-selected
    // display, and there is no old-image fallback or second capture attempt.
    let fresh = try await refresh(original)
    try requireOwnership(stillOwned)
    guard validSource(fresh), fresh.frameID != original.frameID,
      fresh.revision > original.revision,
      fresh.capturedAt >= original.capturedAt,
      fresh.foregroundPID == original.foregroundPID,
      fresh.displayID == original.displayID, fresh.windowID == original.windowID,
      fresh.screenRect == original.screenRect
    else { throw failure() }

    // Current CaptureService emits JPEG. Use its existing bounded header-only
    // reader; PNG, malformed/oversized data, orientation and metadata mismatch
    // fail closed. The discarded original image intentionally is not decoded.
    let size = try ScreenImageGeometry.trustedEncodedPixelSize(fresh.image)
    guard fresh.imageWidth > 0, fresh.imageHeight > 0,
      fresh.imageWidth == Int(size.width), fresh.imageHeight == Int(size.height)
    else { throw failure() }
    try requireOwnership(stillOwned)
    let currentTime = now()
    let age = currentTime - fresh.capturedAt
    guard currentTime.isFinite, currentTime >= 0, age.isFinite,
      age >= 0, age < ScreenGuidancePolicy.admissionEvidenceAge
    else { throw failure() }
    return fresh
  }

  private static func requireOwnership(_ stillOwned: @MainActor () -> Bool) throws {
    try Task.checkCancellation()
    guard stillOwned() else { throw CancellationError() }
  }

  private static func validSource(_ evidence: ScreenEvidence) -> Bool {
    let rect = evidence.screenRect
    return evidence.foregroundPID > 0 && evidence.displayID > 0
      && (evidence.windowID.map { $0 > 0 } ?? true)
      && evidence.capturedAt.isFinite && evidence.capturedAt >= 0
      && rect.origin.x.isFinite && rect.origin.y.isFinite
      && abs(rect.origin.x) <= 10_000_000 && abs(rect.origin.y) <= 10_000_000
      && rect.size.width.isFinite && rect.size.height.isFinite
      && rect.size.width > 0 && rect.size.height > 0
      && rect.size.width <= 100_000 && rect.size.height <= 100_000
      && rect.maxX.isFinite && rect.maxY.isFinite
  }

  private static func failure() -> ProviderError {
    .message(
      "The selected screen context could not be refreshed in its original scope. Recapture that window or region before requesting guidance."
    )
  }
}
