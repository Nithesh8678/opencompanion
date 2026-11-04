import Foundation

/// One provider response remains bound to its immutable input frame. A late
/// response may gain one newly captured frame after local verification; this
/// object never changes the model's published evidence or extends timestamps.
@MainActor final class ScreenGuidanceTurnBinding {
  let source: ScreenEvidence
  private(set) var current: ScreenEvidence
  private(set) var didRefresh = false

  init(source: ScreenEvidence) {
    self.source = source
    current = source
  }

  func prepare(
    _ payload: ProviderTarget,
    refresh: @MainActor () async throws -> ScreenEvidence,
    stillOwned: @MainActor () -> Bool
  ) async throws -> ProviderTarget {
    try checkOwnership(stillOwned)
    let resolved = try source.resolvingTarget(payload)
    try validate(resolved)
    let age = ProcessInfo.processInfo.systemUptime - current.capturedAt
    guard age.isFinite, age >= 0 else { throw failure() }

    if age < ScreenGuidancePolicy.admissionEvidenceAge {
      guard didRefresh else { return resolved }
      let verified = try await ScreenTargetFreshness.verified(
        target: resolved, original: source, refreshed: current)
      try checkOwnership(stillOwned)
      return verified
    }

    guard !didRefresh else { throw failure() }
    // Consume the budget before yielding, even if capture/verification fails.
    // Reentrant marks and retries cannot start a second refresh.
    didRefresh = true
    let fresh = try await refresh()
    try checkOwnership(stillOwned)
    let verified = try await ScreenTargetFreshness.verified(
      target: resolved, original: source, refreshed: fresh)
    try checkOwnership(stillOwned)
    // stillOwned observes the previously published current frame. Publishing
    // into this binding happens only after that last check and without a yield.
    current = fresh
    return verified
  }

  private func checkOwnership(_ stillOwned: @MainActor () -> Bool) throws {
    try Task.checkCancellation()
    guard stillOwned() else { throw CancellationError() }
  }

  private func validate(_ target: ProviderTarget) throws {
    let styled = GuidanceTargetPresentation.styled(target)
    guard target.instruction.utf8.count <= 32_000,
      (target.label?.prefix(81).count ?? 0) <= 80,
      [nil, "click", "manual"].contains(target.advanceOn),
      [nil, "ellipse", "roundedRectangle"].contains(styled.shape),
      ScreenGuidancePolicy.targetRect(target, in: source.screenRect) != nil
    else { throw ProviderError.message("Invalid or oversized screen guidance target.") }
  }

  private func failure() -> ProviderError {
    .message("The screen target needs new guidance evidence. Ask for screen guidance again.")
  }
}
