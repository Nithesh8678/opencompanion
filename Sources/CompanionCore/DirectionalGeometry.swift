import Foundation

extension SceneNode {
  /// Converts directional size metadata into the renderer's explicit local point representation.
  /// Invoke only at the provider boundary, before a scene transaction is validated and accepted.
  /// Existing retained documents and user edits are never silently rewritten.
  public func canonicalizedDirectionalGeometry(limits: SceneLimits = .init()) throws -> Self {
    let geometry = [x, y, width, height]
    guard geometry.allSatisfy({ $0.isFinite && abs($0) <= limits.maximumCoordinate }) else {
      throw CoreError.invalidDocument("nonfinite or out-of-bounds directional geometry for \(id)")
    }
    guard points.count <= limits.maximumPoints, subpaths.count <= limits.maximumPoints else {
      throw CoreError.budgetExceeded("directional vertices")
    }
    var totalPoints = points.count
    for subpath in subpaths {
      guard subpath.count <= limits.maximumPoints - totalPoints else {
        throw CoreError.budgetExceeded("directional vertices")
      }
      totalPoints += subpath.count
    }
    guard
      points.allSatisfy({
        $0.isFinite && abs($0.x) <= limits.maximumCoordinate
          && abs($0.y) <= limits.maximumCoordinate
      }),
      subpaths.joined().allSatisfy({
        $0.isFinite && abs($0.x) <= limits.maximumCoordinate
          && abs($0.y) <= limits.maximumCoordinate
      })
    else {
      throw CoreError.invalidDocument("nonfinite or out-of-bounds directional points for \(id)")
    }
    guard kind == .line || kind == .arrow || kind == .path else {
      guard width >= 0, height >= 0 else {
        throw CoreError.invalidDocument("negative area dimensions for \(id)")
      }
      return self
    }

    var result = self
    let hasSubpathPoints = subpaths.contains { !$0.isEmpty }
    if points.isEmpty && !hasSubpathPoints {
      guard limits.maximumPoints >= 2 else {
        throw CoreError.budgetExceeded("directional vertices")
      }
      result.points = [Point2D(x: 0, y: 0), Point2D(x: width, y: height)]
    }
    // Empty subpaths must not mask explicit points in the renderer's subpath precedence rule.
    if !hasSubpathPoints { result.subpaths = [] }
    result.width = 0
    result.height = 0
    return result
  }
}
