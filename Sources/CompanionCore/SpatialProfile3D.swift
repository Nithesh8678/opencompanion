import Foundation

/// Bounded planar geometry shared by admission and the native procedural mesh.
/// It accepts numeric profiles only, never curves, source code or assets.
public enum SpatialProfile3D {
  public static let maximumPoints = 32

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

  /// Validate a simple, implicitly closed polygon. Negative origins are valid;
  /// repeated endpoints, self-touching edges and degenerate material are not.
  public static func signedArea(
    of profile: [Point2D], maximumPoints: Int = SpatialProfile3D.maximumPoints,
    maximumDimension: Double = 1_000
  ) throws -> Double {
    guard maximumPoints >= 3, profile.count >= 3, profile.count <= min(34, maximumPoints),
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
      guard hypot(profile[j].x - profile[i].x, profile[j].y - profile[i].y) >= 0.001 else {
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

  /// Ear clipping has at most 32 vertices and a hard quadratic search bound.
  /// Returned triples are counterclockwise in XY regardless of input winding.
  public static func triangulation(
    _ profile: [Point2D], maximumDimension: Double = 1_000
  ) throws -> [Int] {
    let area = try signedArea(of: profile, maximumDimension: maximumDimension)
    var remaining = area > 0 ? Array(profile.indices) : Array(profile.indices.reversed())
    var triangles: [Int] = []
    triangles.reserveCapacity((profile.count - 2) * 3)
    for _ in 0..<(maximumPoints * maximumPoints) {
      if remaining.count == 3 {
        guard cross(profile[remaining[0]], profile[remaining[1]], profile[remaining[2]]) > 1e-10
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
        let turn = cross(profile[a], profile[b], profile[c])
        if abs(turn) <= 1e-10 {
          remaining.remove(at: index)
          clipped = true
          break
        }
        guard turn > 0 else { continue }
        let containsVertex = remaining.contains { candidate in
          candidate != a && candidate != b && candidate != c
            && cross(profile[a], profile[b], profile[candidate]) >= -1e-10
            && cross(profile[b], profile[c], profile[candidate]) >= -1e-10
            && cross(profile[c], profile[a], profile[candidate]) >= -1e-10
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
