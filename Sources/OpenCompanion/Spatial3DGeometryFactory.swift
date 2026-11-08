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
    case .cone(let top, let bottom, let height, let segments):
      return try revolved(
        SpatialProfile3D.latheContour([
          .init(radius: bottom, y: -height / 2), .init(radius: top, y: height / 2),
        ]), segments: segments, budget: budget, smoothProfile: false)
    case .capsule(let radius, let height, let segments):
      let rings = max(3, segments / 2)
      let halfStraight = (height - 2 * radius) / 2
      var contour: [Point2D] = []
      for index in 0...rings {
        let angle = -.pi / 2 + .pi / 2 * Double(index) / Double(rings)
        contour.append(
          .init(x: index == 0 ? 0 : radius * cos(angle), y: -halfStraight + radius * sin(angle)))
      }
      if halfStraight > 0 { contour.append(.init(x: radius, y: halfStraight)) }
      for index in 1...rings {
        let angle = .pi / 2 * Double(index) / Double(rings)
        contour.append(
          .init(x: index == rings ? 0 : radius * cos(angle), y: halfStraight + radius * sin(angle)))
      }
      return try revolved(contour, segments: segments, budget: budget, smoothProfile: true)
    case .lathe(let profile, let segments):
      return try revolved(
        SpatialProfile3D.latheContour(profile), segments: segments, budget: budget,
        smoothProfile: true)
    case .extrusion(let profile, let depth):
      return try extruded(profile, depth: depth, budget: budget)
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

  /// All new primitives use host-authored indexed triangles, so no native
  /// constructor's initial/default tessellation can exceed the admitted cost.
  private static func revolved(
    _ contour: [Point2D], segments: Int, budget: SpatialGeometryBudget, smoothProfile: Bool
  ) throws -> SCNGeometry {
    let area = contour.indices.reduce(0.0) { total, index in
      let next = contour[(index + 1) % contour.count]
      return total + contour[index].x * next.y - next.x * contour[index].y
    }
    let sign = area > 0 ? 1.0 : -1.0
    let faceNormals = contour.indices.map { index -> SIMD2<Double> in
      let a = contour[index]
      let b = contour[(index + 1) % contour.count]
      let normal = SIMD2(sign * (b.y - a.y), sign * (a.x - b.x))
      return normal / max(1e-15, hypot(normal.x, normal.y))
    }
    func endpointNormal(edge: Int, vertex: Int) -> SIMD2<Double> {
      let current = faceNormals[edge]
      guard smoothProfile else { return current }
      let adjacent = faceNormals[
        vertex == edge ? (edge + contour.count - 1) % contour.count : (edge + 1) % contour.count]
      // Preserve crisp vessel rims/caps; blend modest profile bends only.
      guard current.x * adjacent.x + current.y * adjacent.y > 0.5 else { return current }
      let sum = current + adjacent
      return sum / max(1e-15, hypot(sum.x, sum.y))
    }
    var mesh = ProceduralMesh(budget: budget)
    for edge in contour.indices {
      let next = (edge + 1) % contour.count
      let a = contour[edge]
      let b = contour[next]
      if a.x == 0, b.x == 0 { continue }
      let normalA = endpointNormal(edge: edge, vertex: edge)
      let normalB = endpointNormal(edge: edge, vertex: next)
      for segment in 0..<segments {
        let t0 = Double(segment) * 2 * .pi / Double(segments)
        let t1 = Double(segment + 1) * 2 * .pi / Double(segments)
        func point(_ p: Point2D, _ angle: Double) -> SIMD3<Double> {
          .init(p.x * cos(angle), p.y, p.x * sin(angle))
        }
        func normal(_ n: SIMD2<Double>, _ angle: Double) -> SIMD3<Double> {
          .init(n.x * cos(angle), n.y, n.x * sin(angle))
        }
        mesh.quad(
          [point(a, t0), point(b, t0), point(b, t1), point(a, t1)],
          normals: [
            normal(normalA, t0), normal(normalB, t0), normal(normalB, t1), normal(normalA, t1),
          ])
      }
    }
    return try mesh.geometry()
  }

  private static func extruded(
    _ profile: [Point2D], depth: Double, budget: SpatialGeometryBudget
  ) throws -> SCNGeometry {
    let triangles = try SpatialProfile3D.triangulation(profile)
    let area = try SpatialProfile3D.signedArea(of: profile)
    let direction = area > 0 ? 1.0 : -1.0
    var mesh = ProceduralMesh(budget: budget)
    func point(_ index: Int, _ z: Double) -> SIMD3<Double> {
      .init(profile[index].x, profile[index].y, z)
    }
    for index in stride(from: 0, to: triangles.count, by: 3) {
      let a = triangles[index]
      let b = triangles[index + 1]
      let c = triangles[index + 2]
      mesh.triangle(
        [point(a, depth / 2), point(b, depth / 2), point(c, depth / 2)], normal: .init(0, 0, 1))
      mesh.triangle(
        [point(a, -depth / 2), point(c, -depth / 2), point(b, -depth / 2)], normal: .init(0, 0, -1))
    }
    for index in profile.indices {
      let next = (index + 1) % profile.count
      let dx = profile[next].x - profile[index].x
      let dy = profile[next].y - profile[index].y
      let length = hypot(dx, dy)
      let normal = SIMD3(direction * dy / length, -direction * dx / length, 0)
      mesh.quad(
        [
          point(index, -depth / 2), point(next, -depth / 2), point(next, depth / 2),
          point(index, depth / 2),
        ],
        normals: [normal, normal, normal, normal])
    }
    return try mesh.geometry()
  }

  private struct ProceduralMesh {
    let budget: SpatialGeometryBudget
    var vertices: [SCNVector3] = []
    var normals: [SCNVector3] = []
    var indices: [UInt32] = []
    init(budget: SpatialGeometryBudget) {
      self.budget = budget
      vertices.reserveCapacity(budget.vertices)
      normals.reserveCapacity(budget.vertices)
      indices.reserveCapacity(budget.triangles * 3)
    }
    mutating func triangle(_ points: [SIMD3<Double>], normal: SIMD3<Double>) {
      quadOrTriangle(points, normals: Array(repeating: normal, count: 3))
    }
    mutating func quad(_ points: [SIMD3<Double>], normals: [SIMD3<Double>]) {
      quadOrTriangle(points, normals: normals)
    }
    private mutating func quadOrTriangle(
      _ points: [SIMD3<Double>], normals supplied: [SIMD3<Double>]
    ) {
      let start = UInt32(vertices.count)
      vertices.append(contentsOf: points.map { .init(Float($0.x), Float($0.y), Float($0.z)) })
      normals.append(contentsOf: supplied.map { .init(Float($0.x), Float($0.y), Float($0.z)) })
      for corners in points.count == 3 ? [[0, 1, 2]] : [[0, 1, 2], [0, 2, 3]] {
        let u = points[corners[1]] - points[corners[0]]
        let v = points[corners[2]] - points[corners[0]]
        let cross = SIMD3(u.y * v.z - u.z * v.y, u.z * v.x - u.x * v.z, u.x * v.y - u.y * v.x)
        let squared = cross.x * cross.x + cross.y * cross.y + cross.z * cross.z
        guard squared > 1e-24 else { continue }
        let n = supplied[corners[0]] + supplied[corners[1]] + supplied[corners[2]]
        let dot = cross.x * n.x + cross.y * n.y + cross.z * n.z
        let ordered = dot >= 0 ? corners : [corners[0], corners[2], corners[1]]
        indices.append(contentsOf: ordered.map { start + UInt32($0) })
      }
    }
    @MainActor func geometry() throws -> SCNGeometry {
      guard !indices.isEmpty, vertices.count <= budget.vertices,
        indices.count / 3 <= budget.triangles
      else {
        throw CoreError.budgetExceeded("native procedural geometry")
      }
      let data = indices.withUnsafeBufferPointer { Data(buffer: $0) }
      return SCNGeometry(
        sources: [SCNGeometrySource(vertices: vertices), SCNGeometrySource(normals: normals)],
        elements: [
          SCNGeometryElement(
            data: data, primitiveType: .triangles, primitiveCount: indices.count / 3,
            bytesPerIndex: MemoryLayout<UInt32>.size)
        ])
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
