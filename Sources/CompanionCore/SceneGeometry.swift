import Foundation

public struct ScenePose: Equatable, Sendable {
  public var node: SceneNode
  public var transform: AffineTransform2D
  public var effectiveOpacity: Double
}

extension SceneDocument {
  /// World poses use parent * translation * rotation * scale and top-left primitive origins.
  public func worldPoses(at time: Double) throws -> [ScenePose] {
    let resolved = try resolvedNodes(at: time)
    var lookup: [String: SceneNode] = [:]
    for node in resolved {
      guard lookup.updateValue(node, forKey: node.id) == nil else {
        throw CoreError.duplicateID(node.id)
      }
    }
    var cache: [String: ScenePose] = [:]
    var visiting = Set<String>()
    func resolve(_ node: SceneNode, depth: Int) throws -> ScenePose {
      if let cached = cache[node.id] { return cached }
      guard depth <= 32, visiting.insert(node.id).inserted else {
        throw CoreError.invalidDocument("cyclic/deep world hierarchy")
      }
      defer { visiting.remove(node.id) }
      let radians = node.rotation * .pi / 180
      var transform = AffineTransform2D(a: node.scaleX, d: node.scaleY)
        .concatenating(.init(a: cos(radians), b: sin(radians), c: -sin(radians), d: cos(radians)))
        .concatenating(.init(tx: node.x, ty: node.y))
      var opacity = node.opacity
      if let parentID = node.parentID {
        guard let parent = lookup[parentID] else { throw CoreError.missingReference(parentID) }
        let parentPose = try resolve(parent, depth: depth + 1)
        transform = transform.concatenating(parentPose.transform)
        opacity *= parentPose.effectiveOpacity
      }
      guard transform.isFinite, opacity.isFinite else { throw CoreError.invalidTransform }
      let pose = ScenePose(node: node, transform: transform, effectiveOpacity: opacity)
      cache[node.id] = pose
      return pose
    }
    return try resolved.map { try resolve($0, depth: 0) }
  }

  public func hitTest(_ point: Point2D, at time: Double, tolerance: Double = 6) throws -> String? {
    guard point.isFinite, tolerance.isFinite, tolerance >= 0, tolerance <= 100 else {
      throw CoreError.invalidTransform
    }
    for pose in try worldPoses(at: time).reversed()
    where pose.node.kind != .group && pose.node.kind != .mesh && pose.effectiveOpacity > 0.01 {
      guard let inverse = try? pose.transform.inverted() else { continue }
      let local = inverse.applying(to: point)
      let node = pose.node
      if [.line, .arrow, .path].contains(node.kind) {
        let paths = node.subpaths.isEmpty ? [node.points] : node.subpaths
        for path in paths where path.count >= 2 {
          for index in 1..<path.count {
            let a = pose.transform.applying(to: path[index - 1])
            let b = pose.transform.applying(to: path[index])
            if Self.distance(point, toSegmentFrom: a, to: b) <= max(tolerance, node.strokeWidth / 2)
            {
              return node.id
            }
          }
        }
      } else if node.kind == .ellipse, node.width > 0, node.height > 0 {
        let dx = (local.x - node.width / 2) / (node.width / 2 + tolerance)
        let dy = (local.y - node.height / 2) / (node.height / 2 + tolerance)
        if dx * dx + dy * dy <= 1 { return node.id }
      } else if Rect2D(
        x: -tolerance, y: -tolerance, width: max(node.width, 15) + tolerance * 2,
        height: max(node.height, node.fontSize * 1.3) + tolerance * 2
      ).contains(local) {
        return node.id
      }
    }
    return nil
  }
  private static func distance(_ point: Point2D, toSegmentFrom a: Point2D, to b: Point2D) -> Double
  {
    let dx = b.x - a.x
    let dy = b.y - a.y
    let lengthSquared = dx * dx + dy * dy
    guard lengthSquared > 1e-12 else { return hypot(point.x - a.x, point.y - a.y) }
    let t = min(1, max(0, ((point.x - a.x) * dx + (point.y - a.y) * dy) / lengthSquared))
    return hypot(point.x - (a.x + t * dx), point.y - (a.y + t * dy))
  }
}
