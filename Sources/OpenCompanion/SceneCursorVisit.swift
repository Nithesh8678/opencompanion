import Foundation

/// Local motion toward a host-verified own-scene surface. This value has no
/// screenshot, pointer-control, accessibility, model or wall-clock capability.
struct SceneCursorVisit: Sendable {
  struct Pose: Sendable {
    let point: CGPoint
    let tangent: CGPoint
    let velocity: CGPoint
    let travelling: Bool
  }

  static let maximumBoundsDimension: CGFloat = 4_096
  /// Scene targets identify the rendered glyph tip; flights animate its center.
  static let bodyTipOffset = CursorCompanionGlyph.tipOffset
  static let retargetTolerance: CGFloat = 0.1
  /// Authored attachment limit, not a recovered reference layout constant.
  static let maximumCaptionBodyGap: CGFloat = 24
  private(set) var authority: SceneFocusAuthority
  private(set) var target: CGPoint
  private var flight: CursorFlight
  private var began: TimeInterval

  init?(
    authority: SceneFocusAuthority, from: CGPoint, point: CGPoint, bounds: CGRect,
    at uptime: TimeInterval
  ) {
    guard Self.valid(point: point, in: bounds), Self.finite(from), uptime.isFinite, uptime >= 0
    else {
      return nil
    }
    self.authority = authority
    target = point
    flight = CursorFlight(start: from, end: Self.bodyCenter(for: point))
    began = uptime
  }

  /// Retarget from the current flight position, never from its old origin.
  /// A stale scoped update leaves the current owner untouched.
  @discardableResult mutating func update(
    authority: SceneFocusAuthority, point: CGPoint, bounds: CGRect, at uptime: TimeInterval,
    reduceMotion: Bool = false, presentationPoint: CGPoint? = nil
  ) -> Bool {
    guard self.authority == authority, Self.valid(point: point, in: bounds),
      presentationPoint.map(Self.finite) ?? true,
      let current = pose(at: uptime, reduceMotion: reduceMotion)
    else { return false }
    guard hypot(point.x - target.x, point.y - target.y) > Self.retargetTolerance else {
      return true
    }
    target = point
    flight = CursorFlight(
      start: presentationPoint ?? current.point, end: Self.bodyCenter(for: point),
      initialVelocity: reduceMotion ? .zero : current.velocity)
    began = uptime
    return true
  }

  func pose(at uptime: TimeInterval, reduceMotion: Bool = false) -> Pose? {
    guard uptime.isFinite, uptime >= began else { return nil }
    let progress = reduceMotion ? 1 : min(1, (uptime - began) / flight.duration)
    return Pose(
      point: flight.point(at: progress), tangent: flight.tangent(at: progress),
      velocity: reduceMotion ? .zero : flight.velocity(at: progress),
      travelling: progress < 1)
  }

  static func valid(point: CGPoint, in bounds: CGRect) -> Bool {
    guard finite(point), finite(bounds.origin), bounds.size.width.isFinite,
      bounds.size.height.isFinite, bounds.size.width > 0, bounds.size.height > 0,
      bounds.size.width <= maximumBoundsDimension, bounds.size.height <= maximumBoundsDimension,
      bounds.maxX.isFinite, bounds.maxY.isFinite
    else { return false }
    return bounds.contains(point)
  }

  static func bodyCenter(for surfacePoint: CGPoint) -> CGPoint {
    CGPoint(x: surfacePoint.x - bodyTipOffset.x, y: surfacePoint.y - bodyTipOffset.y)
  }

  /// The ordinary follower clamps its halo inside the display. A verified
  /// surface visit instead preserves the actual tip position at display edges;
  /// only its transparent halo may extend beyond the visible screen.
  static func anchoring(
    _ placement: CursorCompanionPlacement, bodyCenter center: CGPoint
  ) -> CursorCompanionPlacement {
    guard finite(center) else { return placement }
    let bubble =
      placement.bubbleFrame.isEmpty
      ? CGRect.zero
      : CGRect(
        x: placement.frame.minX + placement.bubbleFrame.minX,
        y: placement.frame.maxY - placement.bubbleFrame.maxY,
        width: placement.bubbleFrame.width, height: placement.bubbleFrame.height)
    let body = CGRect(
      x: center.x - CursorCompanionLayout.bodySize.width / 2,
      y: center.y - CursorCompanionLayout.bodySize.height / 2,
      width: CursorCompanionLayout.bodySize.width, height: CursorCompanionLayout.bodySize.height)
    var frame = body.insetBy(dx: -18, dy: -18)
    if !bubble.isEmpty { frame = frame.union(bubble.insetBy(dx: -12, dy: -12)) }
    return CursorCompanionPlacement(
      frame: frame,
      bodyPoint: CGPoint(x: center.x - frame.minX, y: frame.maxY - center.y),
      bubbleFrame: bubble.isEmpty
        ? .zero
        : CGRect(
          x: bubble.minX - frame.minX, y: frame.maxY - bubble.maxY,
          width: bubble.width, height: bubble.height))
  }

  /// Prefer nearby space outside the own-scene panel, but never detach the
  /// caption just to avoid its transparent host. The attached layout is fallback.
  static func avoidingScene(
    _ placement: CursorCompanionPlacement, bounds: CGRect, display: CGRect, visible: CGRect
  ) -> CursorCompanionPlacement {
    guard valid(point: CGPoint(x: bounds.midX, y: bounds.midY), in: bounds),
      placement.bubbleFrame.width > 0, placement.bubbleFrame.height > 0
    else { return placement }
    let region = display.intersection(visible)
    guard !region.isNull, region.width > 12, region.height > 12 else { return placement }
    let safe = region.insetBy(dx: 6, dy: 6)
    let original = CGRect(
      x: placement.frame.minX + placement.bubbleFrame.minX,
      y: placement.frame.maxY - placement.bubbleFrame.maxY,
      width: placement.bubbleFrame.width, height: placement.bubbleFrame.height)
    let obstacle = bounds.insetBy(dx: -6, dy: -6)
    guard original.intersects(obstacle), original.width <= safe.width,
      original.height <= safe.height
    else { return placement }
    let center = CGPoint(
      x: placement.frame.minX + placement.bodyPoint.x,
      y: placement.frame.maxY - placement.bodyPoint.y)
    let body = CGRect(
      x: center.x - CursorCompanionLayout.bodySize.width / 2,
      y: center.y - CursorCompanionLayout.bodySize.height / 2,
      width: CursorCompanionLayout.bodySize.width, height: CursorCompanionLayout.bodySize.height)
    let width = original.width
    let height = original.height
    func clampedX(_ value: CGFloat) -> CGFloat {
      min(max(safe.minX, value), safe.maxX - width)
    }
    func clampedY(_ value: CGFloat) -> CGFloat {
      min(max(safe.minY, value), safe.maxY - height)
    }
    let candidates = [
      CGRect(x: clampedX(original.minX), y: obstacle.maxY, width: width, height: height),
      CGRect(x: clampedX(original.minX), y: obstacle.minY - height, width: width, height: height),
      CGRect(x: obstacle.minX - width, y: clampedY(original.minY), width: width, height: height),
      CGRect(x: obstacle.maxX, y: clampedY(original.minY), width: width, height: height),
    ]
    guard
      let bubble = candidates.filter({
        safe.contains($0) && !$0.intersects(obstacle)
          && rectangleGap(body, $0) <= maximumCaptionBodyGap
      })
      .min(by: {
        hypot($0.midX - original.midX, $0.midY - original.midY)
          < hypot($1.midX - original.midX, $1.midY - original.midY)
      })
    else { return placement }
    let frame = body.insetBy(dx: -18, dy: -18)
      .union(bubble.insetBy(dx: -12, dy: -12).intersection(safe))
    return CursorCompanionPlacement(
      frame: frame,
      bodyPoint: CGPoint(x: center.x - frame.minX, y: frame.maxY - center.y),
      bubbleFrame: CGRect(
        x: bubble.minX - frame.minX, y: frame.maxY - bubble.maxY,
        width: bubble.width, height: bubble.height))
  }

  private static func rectangleGap(_ first: CGRect, _ second: CGRect) -> CGFloat {
    let dx = max(0, first.minX - second.maxX, second.minX - first.maxX)
    let dy = max(0, first.minY - second.maxY, second.minY - first.maxY)
    return hypot(dx, dy)
  }

  private static func finite(_ point: CGPoint) -> Bool {
    point.x.isFinite && point.y.isFinite && abs(point.x) <= 10_000_000
      && abs(point.y) <= 10_000_000
  }
}
