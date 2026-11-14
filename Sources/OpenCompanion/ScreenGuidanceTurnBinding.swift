import Foundation

/// One provider response remains bound to its immutable input frame. A late
/// response may gain one newly captured frame after local verification; this
/// object never changes the model's published evidence or extends timestamps.
@MainActor final class ScreenGuidanceTurnBinding {
  /// A valid supporting mark can be omitted without invalidating the primary
  /// instruction already awaiting user input. No target is admitted by this.
  enum Decline: Error, Sendable, Equatable {
    case secondaryWouldRefreshPresentedPrimary
  }

  let source: ScreenEvidence
  private(set) var current: ScreenEvidence
  private(set) var didRefresh = false
  private(set) var hasPresentedPrimary = false
  private let now: @MainActor () -> TimeInterval

  init(
    source: ScreenEvidence,
    now: @escaping @MainActor () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
  ) {
    self.source = source
    current = source
    self.now = now
  }

  /// Call only after successful native admission. An explanation without a
  /// user action does not reserve the frame against later primary guidance.
  func recordPresentedTarget(_ target: ProviderTarget) {
    if Self.isPrimary(target) { hasPresentedPrimary = true }
  }

  func prepare(
    _ payload: ProviderTarget,
    refresh: @MainActor () async throws -> ScreenEvidence,
    stillOwned: @MainActor () -> Bool,
    visualChangeRequiresRefresh: Bool = false,
    supportsSecondary: Bool = true
  ) async throws -> ProviderTarget {
    try checkOwnership(stillOwned)
    let resolved = try source.resolvingTarget(payload)
    try validate(resolved)
    if hasPresentedPrimary, !Self.isPrimary(resolved), !supportsSecondary {
      throw Decline.secondaryWouldRefreshPresentedPrimary
    }
    let currentTime = now()
    let age = currentTime - current.capturedAt
    guard currentTime.isFinite, currentTime >= 0, current.capturedAt.isFinite,
      current.capturedAt >= 0, age.isFinite, age >= 0
    else { throw failure() }

    if age < ScreenGuidancePolicy.admissionEvidenceAge, !visualChangeRequiresRefresh {
      guard didRefresh else { return resolved }
      do {
        let verified = try await ScreenTargetFreshness.verified(
          target: resolved, original: source, refreshed: current)
        try checkOwnership(stillOwned)
        return verified
      } catch {
        try checkOwnership(stillOwned)
        if hasPresentedPrimary, !Self.isPrimary(resolved) {
          // A supporting target cannot revoke an already corroborated primary
          // merely because unrelated pixels differed in that same refresh.
          throw Decline.secondaryWouldRefreshPresentedPrimary
        }
        throw error
      }
    }

    if hasPresentedPrimary, !Self.isPrimary(resolved) {
      // Resolution and full content/geometry validation precede this decision.
      // Swapping frame identity here would clear the primary's existing mark
      // and manual lease. Keep those independently bounded leases unchanged;
      // never admit this secondary on old evidence or refresh implicitly.
      try checkOwnership(stillOwned)
      throw Decline.secondaryWouldRefreshPresentedPrimary
    }

    guard !didRefresh else { throw failure() }
    // Consume the budget before yielding, even if capture/verification fails.
    // Reentrant marks and retries cannot start a second refresh.
    didRefresh = true
    let fresh = try await refresh()
    try checkOwnership(stillOwned)
    let verified: ProviderTarget
    do {
      verified = try await ScreenTargetFreshness.verified(
        target: resolved, original: source, refreshed: fresh)
    } catch {
      try checkOwnership(stillOwned)
      guard visualChangeRequiresRefresh else { throw error }
      // Unrelated animation may defeat full-scene equality. Only a unique
      // fresh native control plus unchanged expanded target pixels can then
      // corroborate the target; image-only/OCR targets keep the old contract.
      verified = try await ScreenTargetFreshness.verifiedStableAccessibilityTarget(
        target: payload, original: source, refreshed: fresh)
    }
    try checkOwnership(stillOwned)
    // stillOwned observes the previously published current frame. Publishing
    // into this binding happens only after that last check and without a yield.
    current = fresh
    return verified
  }

  private static func isPrimary(_ target: ProviderTarget) -> Bool {
    target.advanceOn == "click" || (target.advanceOn == "manual" && target.awaitUser == true)
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
      target.awaitUser != true || target.advanceOn == "manual",
      [nil, "ellipse", "roundedRectangle"].contains(styled.shape),
      ScreenGuidancePolicy.targetRect(target, in: source.screenRect) != nil
    else { throw ProviderError.message("Invalid or oversized screen guidance target.") }
  }

  private func failure() -> ProviderError {
    .message("The screen target needs new guidance evidence. Ask for screen guidance again.")
  }
}
