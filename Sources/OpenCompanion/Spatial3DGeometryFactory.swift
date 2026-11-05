import CompanionCore
import SceneKit

/// Builds host-owned geometry only after the semantic primitive passes its allocation budget.
@MainActor
enum Spatial3DGeometryFactory {
  static func make(_ geometry: Geometry3D, limits: SceneLimits = .init()) throws -> SCNGeometry {
    let budget = try geometry.validatedBudget(limits: limits)
    switch geometry {
    case .box(let width, let height, let depth, let chamferRadius):
      let result = SCNBox(
        width: CGFloat(width), height: CGFloat(height), length: CGFloat(depth),
        chamferRadius: CGFloat(chamferRadius))
      result.widthSegmentCount = 1
      result.heightSegmentCount = 1
      result.lengthSegmentCount = 1
      result.chamferSegmentCount = 4
      return result
    case .sphere(let radius, let segments):
      let result = SCNSphere(radius: CGFloat(radius))
      result.isGeodesic = false
      result.segmentCount = segments
      return result
    case .cylinder(let radius, let height, let segments):
      let result = SCNCylinder(radius: CGFloat(radius), height: CGFloat(height))
      result.radialSegmentCount = segments
      result.heightSegmentCount = 1
      return result
    case .torus(let ringRadius, let pipeRadius, let ringSegments, let pipeSegments):
      let result = SCNTorus(ringRadius: CGFloat(ringRadius), pipeRadius: CGFloat(pipeRadius))
      result.ringSegmentCount = ringSegments
      result.pipeSegmentCount = pipeSegments
      return result
    case .tube(
      let innerRadius, let outerRadius, let height, let segments, let startAngleDegrees,
      let sweepAngleDegrees):
      return tube(
        innerRadius: innerRadius, outerRadius: outerRadius, height: height, segments: segments,
        startAngleDegrees: startAngleDegrees, sweepAngleDegrees: sweepAngleDegrees, budget: budget)
    }
  }

  /// Angles run from +X toward +Z around Y. Every face is wound outward, including the bore.
  private static func tube(
    innerRadius: Double, outerRadius: Double, height: Double, segments: Int,
    startAngleDegrees: Double, sweepAngleDegrees: Double, budget: SpatialGeometryBudget
  ) -> SCNGeometry {
    var vertices: [SCNVector3] = []
    var normals: [SCNVector3] = []
    var indices: [UInt32] = []
    vertices.reserveCapacity(budget.vertices)
    normals.reserveCapacity(budget.vertices)
    indices.reserveCapacity(budget.triangles * 3)

    func vector(_ x: Double, _ y: Double, _ z: Double) -> SCNVector3 {
      SCNVector3(Float(x), Float(y), Float(z))
    }
    func point(_ radius: Double, _ y: Double, _ angle: Double) -> SCNVector3 {
      vector(radius * cos(angle), y, radius * sin(angle))
    }
    func radial(_ angle: Double, sign: Double = 1) -> SCNVector3 {
      vector(sign * cos(angle), 0, sign * sin(angle))
    }
    func quad(
      _ a: SCNVector3, _ b: SCNVector3, _ c: SCNVector3, _ d: SCNVector3,
      normals faceNormals: [SCNVector3]
    ) {
      let first = UInt32(vertices.count)
      vertices.append(contentsOf: [a, b, c, d])
      normals.append(contentsOf: faceNormals)
      indices.append(contentsOf: [first, first + 1, first + 2, first, first + 2, first + 3])
    }
    func triangle(_ a: SCNVector3, _ b: SCNVector3, _ c: SCNVector3, normal: SCNVector3) {
      let first = UInt32(vertices.count)
      vertices.append(contentsOf: [a, b, c])
      normals.append(contentsOf: [normal, normal, normal])
      indices.append(contentsOf: [first, first + 1, first + 2])
    }

    let halfHeight = height / 2
    let start = startAngleDegrees * .pi / 180
    let sweep = sweepAngleDegrees * .pi / 180
    let up = vector(0, 1, 0)
    let down = vector(0, -1, 0)

    for segment in 0..<segments {
      let a = start + sweep * Double(segment) / Double(segments)
      let b = start + sweep * Double(segment + 1) / Double(segments)
      let outerBottomA = point(outerRadius, -halfHeight, a)
      let outerTopA = point(outerRadius, halfHeight, a)
      let outerBottomB = point(outerRadius, -halfHeight, b)
      let outerTopB = point(outerRadius, halfHeight, b)
      quad(
        outerBottomA, outerTopA, outerTopB, outerBottomB,
        normals: [radial(a), radial(a), radial(b), radial(b)])

      if innerRadius > 0 {
        let innerBottomA = point(innerRadius, -halfHeight, a)
        let innerTopA = point(innerRadius, halfHeight, a)
        let innerBottomB = point(innerRadius, -halfHeight, b)
        let innerTopB = point(innerRadius, halfHeight, b)
        quad(
          innerBottomA, innerBottomB, innerTopB, innerTopA,
          normals: [
            radial(a, sign: -1), radial(b, sign: -1), radial(b, sign: -1), radial(a, sign: -1),
          ])
        quad(
          outerTopA, innerTopA, innerTopB, outerTopB,
          normals: [up, up, up, up])
        quad(
          outerBottomA, outerBottomB, innerBottomB, innerBottomA,
          normals: [down, down, down, down])
      } else {
        // A zero-radius bore is solid; use fans rather than degenerate inner-wall quads.
        triangle(outerTopA, point(0, halfHeight, a), outerTopB, normal: up)
        triangle(outerBottomA, outerBottomB, point(0, -halfHeight, a), normal: down)
      }
    }

    if sweepAngleDegrees < 360 {
      let end = start + sweep
      let startNormal = vector(sin(start), 0, -cos(start))
      let endNormal = vector(-sin(end), 0, cos(end))
      quad(
        point(outerRadius, -halfHeight, start), point(innerRadius, -halfHeight, start),
        point(innerRadius, halfHeight, start), point(outerRadius, halfHeight, start),
        normals: [startNormal, startNormal, startNormal, startNormal])
      quad(
        point(outerRadius, -halfHeight, end), point(outerRadius, halfHeight, end),
        point(innerRadius, halfHeight, end), point(innerRadius, -halfHeight, end),
        normals: [endNormal, endNormal, endNormal, endNormal])
    }

    return SCNGeometry(
      sources: [SCNGeometrySource(vertices: vertices), SCNGeometrySource(normals: normals)],
      elements: [SCNGeometryElement(indices: indices, primitiveType: .triangles)])
  }
}
