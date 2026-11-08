import Foundation

/// Bounded planar geometry shared by admission and the native procedural mesh.
/// It accepts numeric profiles only, never curves, source code or assets.
public enum SpatialProfile3D {
  public static let maximumPoints = 32
  public static let maximumExpandedPoints = 160

  /// Close an ordered radius/Y generating contour by discs to the Y axis.
  /// Returning along an inner wall permits a real hollow vessel. The enclosed
  /// material cross-section must remain one simple polygon, without axis crossings.
  public static func latheContour(
    _ profile: [LathePoint3D], maximumDimension: Double = 1_000
  ) throws -> [Point2D] {
    guard (2...maximumPoints).contains(profile.count), maximumDimension.isFinite,
      maximumDimension >= 0.001,
      profile.allSatisfy({
        $0.radius.isFinite && $0.y.isFinite && $0.radius >= 0
          && $0.radius <= min(1_000, maximumDimension)
          && abs($0.y) <= min(1_000, maximumDimension)
      })
    else { throw invalid() }
    var contour = profile.map { Point2D(x: $0.radius, y: $0.y) }
    guard let first = contour.first, let last = contour.last else { throw invalid() }
    if first.y != last.y {
      if last.x != 0 { contour.append(.init(x: 0, y: last.y)) }
      if first.x != 0 { contour.append(.init(x: 0, y: first.y)) }
    }
    // When both ends lie at the same Y, the implicit cap joins them directly.
    _ = try signedArea(
      of: contour, maximumPoints: maximumPoints + 2, maximumDimension: maximumDimension)
    return contour
  }

  /// Explicit corner rounding, never an automatic reinterpretation of an old
  /// polygon. Each adjacent edge is trimmed by the supplied fraction, then four
  /// fixed quadratic segments join entry to exit with the corner as control.
  /// Convex corners lose material; concave corners can add it inside the corner
  /// triangle. Attachment roots and clearances must account for that change.
  /// Rounded samples are quantized to native Float mesh precision. Fractions
  /// or short edges producing collapsed samples are rejected, never silently
  /// treated as a linear outline.
  public static func extrusionContour(
    _ profile: [Point2D], cornerRounding: Double = 0, maximumDimension: Double = 1_000
  ) throws -> [Point2D] {
    guard cornerRounding.isFinite, (0...0.25).contains(cornerRounding) else { throw invalid() }
    _ = try signedArea(of: profile, maximumDimension: maximumDimension)
    guard cornerRounding > 0 else { return profile }
    let scale = profile.reduce(1.0) { max($0, max(abs($1.x), abs($1.y))) }
    let tolerance = max(1e-7, scale * Double(Float.ulpOfOne))
    var result: [Point2D] = []
    result.reserveCapacity(profile.count * 5)
    func native(_ point: Point2D) -> Point2D {
      .init(x: Double(Float(point.x)), y: Double(Float(point.y)))
    }
    func append(_ point: Point2D) throws {
      let value = native(point)
      if let last = result.last, hypot(last.x - value.x, last.y - value.y) <= tolerance {
        throw invalid()
      }
      result.append(value)
    }
    for index in profile.indices {
      let p = profile[index]
      let before = profile[(index + profile.count - 1) % profile.count]
      let after = profile[(index + 1) % profile.count]
      let entry = Point2D(
        x: p.x + (before.x - p.x) * cornerRounding,
        y: p.y + (before.y - p.y) * cornerRounding)
      let exit = Point2D(
        x: p.x + (after.x - p.x) * cornerRounding,
        y: p.y + (after.y - p.y) * cornerRounding)
      // Reject sub-precision curves instead of producing unstable vertices.
      guard
        min(hypot(entry.x - p.x, entry.y - p.y), hypot(exit.x - p.x, exit.y - p.y)) > tolerance * 4
      else { throw invalid() }
      for sample in 0...4 {
        let t = Double(sample) / 4
        let u = 1 - t
        try append(
          .init(
            x: u * u * entry.x + 2 * u * t * p.x + t * t * exit.x,
            y: u * u * entry.y + 2 * u * t * p.y + t * t * exit.y))
      }
    }
    if let first = result.first, let last = result.last,
      hypot(first.x - last.x, first.y - last.y) <= tolerance
    {
      throw invalid()
    }
    let originalArea = try signedArea(of: profile, maximumDimension: maximumDimension)
    let roundedArea = try signedArea(
      of: result, maximumPoints: maximumExpandedPoints,
      maximumDimension: maximumDimension, minimumEdgeLength: 0)
    guard originalArea * roundedArea > 0 else { throw invalid() }
    return result
  }

  /// Validate a simple, implicitly closed polygon. Negative origins are valid;
  /// repeated endpoints, self-touching edges and degenerate material are not.
  public static func signedArea(
    of profile: [Point2D], maximumPoints: Int = SpatialProfile3D.maximumPoints,
    maximumDimension: Double = 1_000, minimumEdgeLength: Double = 0.001
  ) throws -> Double {
    guard maximumPoints >= 3, profile.count >= 3,
      profile.count <= min(maximumExpandedPoints, maximumPoints),
      minimumEdgeLength.isFinite, minimumEdgeLength >= 0,
      maximumDimension.isFinite,
      maximumDimension >= 0.001,
      profile.allSatisfy({
        $0.isFinite && abs($0.x) <= min(1_000, maximumDimension)
          && abs($0.y) <= min(1_000, maximumDimension)
      })
    else { throw invalid() }
    let xs = profile.map(\.x)
    let ys = profile.map(\.y)
    guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max(),
      maxX - minX >= 0.001, maxY - minY >= 0.001,
      maxX - minX <= maximumDimension, maxY - minY <= maximumDimension
    else { throw invalid() }
    var twiceArea = 0.0
    for i in profile.indices {
      let j = (i + 1) % profile.count
      let k = (i + 2) % profile.count
      let edgeLength = hypot(profile[j].x - profile[i].x, profile[j].y - profile[i].y)
      guard edgeLength > 0, edgeLength >= minimumEdgeLength else {
        throw invalid()
      }
      let dot =
        (profile[j].x - profile[i].x) * (profile[k].x - profile[j].x)
        + (profile[j].y - profile[i].y) * (profile[k].y - profile[j].y)
      if abs(cross(profile[i], profile[j], profile[k])) <= 1e-10, dot < 0 { throw invalid() }
      twiceArea += profile[i].x * profile[j].y - profile[j].x * profile[i].y
      for k in profile.indices where k > i {
        let l = (k + 1) % profile.count
        if j == k || l == i { continue }
        if intersects(profile[i], profile[j], profile[k], profile[l]) { throw invalid() }
      }
    }
    guard twiceArea.isFinite, abs(twiceArea) >= 1e-9 else { throw invalid() }
    return twiceArea / 2
  }

  /// Ear clipping has at most 160 derived vertices and a hard bounded search.
  /// Returned triples are counterclockwise in XY regardless of input winding.
  public static func triangulation(
    _ profile: [Point2D], maximumDimension: Double = 1_000,
    maximumPoints: Int = SpatialProfile3D.maximumPoints, minimumEdgeLength: Double = 0.001,
    preserveBoundary: Bool = false
  ) throws -> [Int] {
    let area = try signedArea(
      of: profile, maximumPoints: maximumPoints, maximumDimension: maximumDimension,
      minimumEdgeLength: minimumEdgeLength)
    var remaining = area > 0 ? Array(profile.indices) : Array(profile.indices.reversed())
    var triangles: [Int] = []
    triangles.reserveCapacity((profile.count - 2) * 3)
    // Rounded contours already use native Float coordinates. Preserve their
    // real small turns rather than dropping them under a world-unit epsilon.
    // Every boundary vertex must participate, or triangulation rejects.
    func orientation(_ a: Int, _ b: Int, _ c: Int) -> Int {
      let u = Point2D(x: profile[b].x - profile[a].x, y: profile[b].y - profile[a].y)
      let v = Point2D(x: profile[c].x - profile[a].x, y: profile[c].y - profile[a].y)
      let lhs = u.x * v.y
      let rhs = u.y * v.x
      let tolerance = preserveBoundary ? 16 * Double.ulpOfOne * (abs(lhs) + abs(rhs)) : 1e-10
      let value = lhs - rhs
      return value > tolerance ? 1 : value < -tolerance ? -1 : 0
    }
    for _ in 0..<(maximumExpandedPoints * maximumExpandedPoints) {
      if remaining.count == 3 {
        guard orientation(remaining[0], remaining[1], remaining[2]) > 0
        else {
          throw invalid()
        }
        return triangles + remaining
      }
      var clipped = false
      for index in remaining.indices {
        let a = remaining[(index + remaining.count - 1) % remaining.count]
        let b = remaining[index]
        let c = remaining[(index + 1) % remaining.count]
        let turn = orientation(a, b, c)
        if turn == 0, !preserveBoundary {
          remaining.remove(at: index)
          clipped = true
          break
        }
        guard turn > 0 else { continue }
        let containsVertex = remaining.contains { candidate in
          candidate != a && candidate != b && candidate != c
            && orientation(a, b, candidate) >= 0
            && orientation(b, c, candidate) >= 0
            && orientation(c, a, candidate) >= 0
        }
        if !containsVertex {
          triangles.append(contentsOf: [a, b, c])
          remaining.remove(at: index)
          clipped = true
          break
        }
      }
      guard clipped, remaining.count >= 3 else { throw invalid() }
    }
    throw invalid()
  }

  private static func cross(_ a: Point2D, _ b: Point2D, _ c: Point2D) -> Double {
    (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)
  }
  private static func intersects(_ a: Point2D, _ b: Point2D, _ c: Point2D, _ d: Point2D) -> Bool {
    let abC = cross(a, b, c)
    let abD = cross(a, b, d)
    let cdA = cross(c, d, a)
    let cdB = cross(c, d, b)
    func on(_ p: Point2D, _ a: Point2D, _ b: Point2D, _ cross: Double) -> Bool {
      abs(cross) <= 1e-10 && p.x >= min(a.x, b.x) - 1e-10 && p.x <= max(a.x, b.x) + 1e-10
        && p.y >= min(a.y, b.y) - 1e-10 && p.y <= max(a.y, b.y) + 1e-10
    }
    return (abC * abD < 0 && cdA * cdB < 0)
      || on(c, a, b, abC) || on(d, a, b, abD) || on(a, c, d, cdA) || on(b, c, d, cdB)
  }
  private static func invalid() -> CoreError {
    .invalidDocument("3D profile must be simple and bounded")
  }
}
