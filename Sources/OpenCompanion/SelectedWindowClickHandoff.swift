import CoreGraphics
import Foundation

/// One recorded down/up pair for one selected-window mark. This observes input
/// metadata only; a match requests fresh perception and never proves success.
struct SelectedWindowClickHandoff: Sendable {
  struct Authority: Sendable, Equatable {
    let lease: UUID
    let frameID: UUID
    let generation: UInt64
    let requestID: UUID
    let step: Int
    let foregroundPID: pid_t
    let windowID: CGWindowID
    let targetRect: CGRect
    let admittedAt: TimeInterval
    let deadline: TimeInterval
  }

  private struct Down: Sendable {
    let authority: Authority
    let timestamp: TimeInterval
  }

  private var pending: Down?
  var hasPendingDown: Bool { pending != nil }

  mutating func clear() { pending = nil }

  @discardableResult
  mutating func receiveDown(
    authority: Authority, point: CGPoint?, timestamp: TimeInterval,
    eventTargetPID: pid_t?, handlingWindowID: CGWindowID?
  ) -> Bool {
    if let pending, pending.authority != authority { return false }
    // An unknown/conflicting second down revokes the prior pair. The caller
    // checks the current lease before forwarding, so an old queued callback
    // cannot clear a newer owner's down.
    pending = nil
    guard valid(authority), valid(point, inside: authority.targetRect),
      timestamp.isFinite, timestamp >= authority.admittedAt, timestamp < authority.deadline,
      let eventTargetPID, eventTargetPID > 0, eventTargetPID == authority.foregroundPID,
      let handlingWindowID, handlingWindowID > 0, handlingWindowID == authority.windowID
    else { return false }
    pending = Down(authority: authority, timestamp: timestamp)
    return true
  }

  @discardableResult
  mutating func receiveUp(
    authority: Authority, point: CGPoint?, timestamp: TimeInterval,
    eventTargetPID: pid_t?
  ) -> Bool {
    guard let down = pending, down.authority == authority else { return false }
    pending = nil
    guard valid(authority),
      valid(point, inside: authority.targetRect), timestamp.isFinite,
      timestamp >= down.timestamp, timestamp < authority.deadline,
      timestamp - down.timestamp <= ScreenGuidancePolicy.markedTargetLifetime,
      eventTargetPID == nil || eventTargetPID == 0 || eventTargetPID == authority.foregroundPID
    else { return false }
    // A menu can open on mouseDown. Do not query/reinterpret its later window
    // destination as the destination of the already authenticated down.
    return true
  }

  private func valid(_ authority: Authority) -> Bool {
    let rect = authority.targetRect
    return authority.foregroundPID > 0 && authority.windowID > 0
      && (0..<ScreenGuidancePolicy.maximumChecks).contains(authority.step)
      && authority.admittedAt.isFinite && authority.admittedAt >= 0
      && authority.deadline.isFinite && authority.deadline > authority.admittedAt
      && authority.deadline - authority.admittedAt <= ScreenGuidancePolicy.markedTargetLifetime
      && rect.origin.x.isFinite && rect.origin.y.isFinite
      && abs(rect.origin.x) <= 10_000_000 && abs(rect.origin.y) <= 10_000_000
      && rect.size.width.isFinite && rect.size.height.isFinite
      && rect.size.width > 0 && rect.size.height > 0
      && rect.size.width <= 100_000 && rect.size.height <= 100_000
      && rect.maxX.isFinite && rect.maxY.isFinite
  }

  private func valid(_ point: CGPoint?, inside rect: CGRect) -> Bool {
    guard let point, point.x.isFinite, point.y.isFinite else { return false }
    return rect.contains(point)
  }
}
