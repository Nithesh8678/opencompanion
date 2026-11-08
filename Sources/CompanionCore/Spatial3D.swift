import Foundation

public struct Vector3D: Codable, Equatable, Hashable, Sendable {
  public var x, y, z: Double
  public init(x: Double, y: Double, z: Double) {
    self.x = x
    self.y = y
    self.z = z
  }
  public static let zero = Self(x: 0, y: 0, z: 0)
  public static let one = Self(x: 1, y: 1, z: 1)
  public var isFinite: Bool { x.isFinite && y.isFinite && z.isFinite }
  public var components: [Double] { [x, y, z] }
  private enum CodingKeys: String, CodingKey { case x, y, z }
  public init(from decoder: any Decoder) throws {
    try SpatialDecoding.rejectUnknown(decoder, allowing: ["x", "y", "z"])
    let c = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      x: try c.decode(Double.self, forKey: .x), y: try c.decode(Double.self, forKey: .y),
      z: try c.decode(Double.self, forKey: .z))
  }
}

public enum Axis3D: String, Codable, CaseIterable, Sendable { case x, y, z }

/// Right-handed world units, +Y up. Local transform is T * Rz * Ry * Rx * S.
public struct Transform3D: Codable, Equatable, Hashable, Sendable {
  public var position, rotationDegrees, scale: Vector3D
  public init(
    position: Vector3D = .zero, rotationDegrees: Vector3D = .zero, scale: Vector3D = .one
  ) {
    self.position = position
    self.rotationDegrees = rotationDegrees
    self.scale = scale
  }
  public static let identity = Self()
  private enum CodingKeys: String, CodingKey { case position, rotationDegrees, scale }
  public init(from decoder: any Decoder) throws {
    try SpatialDecoding.rejectUnknown(decoder, allowing: ["position", "rotationDegrees", "scale"])
    let c = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      position: try c.decodeIfPresent(Vector3D.self, forKey: .position) ?? .zero,
      rotationDegrees: try c.decodeIfPresent(Vector3D.self, forKey: .rotationDegrees) ?? .zero,
      scale: try c.decodeIfPresent(Vector3D.self, forKey: .scale) ?? .one)
  }
  public var matrix: Matrix4x4D {
    let a = rotationDegrees.x * .pi / 180
    let b = rotationDegrees.y * .pi / 180
    let c = rotationDegrees.z * .pi / 180
    let rx = Matrix4x4D([1, 0, 0, 0, 0, cos(a), sin(a), 0, 0, -sin(a), cos(a), 0, 0, 0, 0, 1])
    let ry = Matrix4x4D([cos(b), 0, -sin(b), 0, 0, 1, 0, 0, sin(b), 0, cos(b), 0, 0, 0, 0, 1])
    let rz = Matrix4x4D([cos(c), sin(c), 0, 0, -sin(c), cos(c), 0, 0, 0, 0, 1, 0, 0, 0, 0, 1])
    let s = Matrix4x4D([scale.x, 0, 0, 0, 0, scale.y, 0, 0, 0, 0, scale.z, 0, 0, 0, 0, 1])
    let t = Matrix4x4D([1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, position.x, position.y, position.z, 1])
    return t.multiplied(by: rz).multiplied(by: ry).multiplied(by: rx).multiplied(by: s)
  }
}

/// Fixed-size column-major matrix. No native framework or serialized matrix is trusted.
public struct Matrix4x4D: Equatable, Sendable {
  public let elements: [Double]
  fileprivate init(_ elements: [Double]) { self.elements = elements }
  public static let identity = Self([1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1])
  public func multiplied(by rhs: Self) -> Self {
    var result = [Double](repeating: 0, count: 16)
    for column in 0..<4 {
      for row in 0..<4 {
        for k in 0..<4 {
          result[column * 4 + row] += elements[k * 4 + row] * rhs.elements[column * 4 + k]
        }
      }
    }
    return Self(result)
  }
  public func applying(to point: Vector3D) -> Vector3D {
    .init(
      x: elements[0] * point.x + elements[4] * point.y + elements[8] * point.z + elements[12],
      y: elements[1] * point.x + elements[5] * point.y + elements[9] * point.z + elements[13],
      z: elements[2] * point.x + elements[6] * point.y + elements[10] * point.z + elements[14])
  }
  fileprivate var validWorldTransform: Bool {
    guard elements.allSatisfy({ $0.isFinite && abs($0) <= 100_000 }) else { return false }
    for column in 0..<3 {
      let offset = column * 4
      let length = hypot(hypot(elements[offset], elements[offset + 1]), elements[offset + 2])
      guard (0.000_001...10_000).contains(length) else { return false }
    }
    return true
  }
}

public struct SpatialGeometryBudget: Equatable, Sendable {
  public let vertices, triangles: Int
}

public struct LathePoint3D: Codable, Equatable, Hashable, Sendable {
  public var radius, y: Double
  public init(radius: Double, y: Double) {
    self.radius = radius
    self.y = y
  }
  private enum CodingKeys: String, CodingKey { case radius, y }
  public init(from decoder: any Decoder) throws {
    try SpatialDecoding.rejectUnknown(decoder, allowing: ["radius", "y"])
    let c = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      radius: try c.decode(Double.self, forKey: .radius), y: try c.decode(Double.self, forKey: .y))
  }
}

/// Dimensions are world units. Shape-specific keys are strict; there are no assets or shaders.
public enum Geometry3D: Equatable, Hashable, Sendable, Codable {
  case box(width: Double, height: Double, depth: Double, chamferRadius: Double = 0)
  case sphere(radius: Double, segments: Int = 24)
  case cylinder(radius: Double, height: Double, segments: Int = 32)
  case cone(topRadius: Double, bottomRadius: Double, height: Double, segments: Int = 32)
  case capsule(radius: Double, height: Double, segments: Int = 24)
  case lathe(profile: [LathePoint3D], segments: Int = 32)
  case extrusion(profile: [Point2D], depth: Double, cornerRounding: Double = 0)
  case torus(ringRadius: Double, pipeRadius: Double, ringSegments: Int = 32, pipeSegments: Int = 12)
  case tube(
    innerRadius: Double, outerRadius: Double, height: Double, segments: Int = 32,
    startAngleDegrees: Double = 0, sweepAngleDegrees: Double = 360)
  private enum Keys: String, CodingKey {
    case type, width, height, depth, chamferRadius, radius, segments, ringRadius, pipeRadius,
      ringSegments, pipeSegments, innerRadius, outerRadius, startAngleDegrees, sweepAngleDegrees,
      topRadius, bottomRadius, profile, cornerRounding
  }
  private enum Tag: String, Codable {
    case box, sphere, cylinder, torus, tube, cone, capsule, lathe, extrusion
  }
  public init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: Keys.self)
    let tag = try c.decode(Tag.self, forKey: .type)
    let allowed: Set<String>
    switch tag {
    case .box: allowed = ["type", "width", "height", "depth", "chamferRadius"]
    case .sphere: allowed = ["type", "radius", "segments"]
    case .cylinder: allowed = ["type", "radius", "height", "segments"]
    case .cone: allowed = ["type", "topRadius", "bottomRadius", "height", "segments"]
    case .capsule: allowed = ["type", "radius", "height", "segments"]
    case .lathe: allowed = ["type", "profile", "segments"]
    case .extrusion: allowed = ["type", "profile", "depth", "cornerRounding"]
    case .torus: allowed = ["type", "ringRadius", "pipeRadius", "ringSegments", "pipeSegments"]
    case .tube:
      allowed = [
        "type", "innerRadius", "outerRadius", "height", "segments", "startAngleDegrees",
        "sweepAngleDegrees",
      ]
    }
    try SpatialDecoding.rejectUnknown(decoder, allowing: allowed)
    switch tag {
    case .box:
      self = .box(
        width: try c.decode(Double.self, forKey: .width),
        height: try c.decode(Double.self, forKey: .height),
        depth: try c.decode(Double.self, forKey: .depth),
        chamferRadius: try c.decodeIfPresent(Double.self, forKey: .chamferRadius) ?? 0)
    case .sphere:
      self = .sphere(
        radius: try c.decode(Double.self, forKey: .radius),
        segments: try c.decodeIfPresent(Int.self, forKey: .segments) ?? 24)
    case .cylinder:
      self = .cylinder(
        radius: try c.decode(Double.self, forKey: .radius),
        height: try c.decode(Double.self, forKey: .height),
        segments: try c.decodeIfPresent(Int.self, forKey: .segments) ?? 32)
    case .cone:
      self = .cone(
        topRadius: try c.decode(Double.self, forKey: .topRadius),
        bottomRadius: try c.decode(Double.self, forKey: .bottomRadius),
        height: try c.decode(Double.self, forKey: .height),
        segments: try c.decodeIfPresent(Int.self, forKey: .segments) ?? 32)
    case .capsule:
      self = .capsule(
        radius: try c.decode(Double.self, forKey: .radius),
        height: try c.decode(Double.self, forKey: .height),
        segments: try c.decodeIfPresent(Int.self, forKey: .segments) ?? 24)
    case .lathe:
      self = .lathe(
        profile: try Self.decodeProfile(LathePoint3D.self, from: c, keys: ["radius", "y"]),
        segments: try c.decodeIfPresent(Int.self, forKey: .segments) ?? 32)
    case .extrusion:
      self = .extrusion(
        profile: try Self.decodeProfile(Point2D.self, from: c, keys: ["x", "y"]),
        depth: try c.decode(Double.self, forKey: .depth),
        cornerRounding: try c.decodeIfPresent(Double.self, forKey: .cornerRounding) ?? 0)
    case .torus:
      self = .torus(
        ringRadius: try c.decode(Double.self, forKey: .ringRadius),
        pipeRadius: try c.decode(Double.self, forKey: .pipeRadius),
        ringSegments: try c.decodeIfPresent(Int.self, forKey: .ringSegments) ?? 32,
        pipeSegments: try c.decodeIfPresent(Int.self, forKey: .pipeSegments) ?? 12)
    case .tube:
      self = .tube(
        innerRadius: try c.decode(Double.self, forKey: .innerRadius),
        outerRadius: try c.decode(Double.self, forKey: .outerRadius),
        height: try c.decode(Double.self, forKey: .height),
        segments: try c.decodeIfPresent(Int.self, forKey: .segments) ?? 32,
        startAngleDegrees: try c.decodeIfPresent(Double.self, forKey: .startAngleDegrees) ?? 0,
        sweepAngleDegrees: try c.decodeIfPresent(Double.self, forKey: .sweepAngleDegrees) ?? 360)
    }
  }
  public func encode(to encoder: any Encoder) throws {
    var c = encoder.container(keyedBy: Keys.self)
    switch self {
    case .box(let w, let h, let d, let r):
      try c.encode(Tag.box, forKey: .type)
      try c.encode(w, forKey: .width)
      try c.encode(h, forKey: .height)
      try c.encode(d, forKey: .depth)
      try c.encode(r, forKey: .chamferRadius)
    case .sphere(let r, let s):
      try c.encode(Tag.sphere, forKey: .type)
      try c.encode(r, forKey: .radius)
      try c.encode(s, forKey: .segments)
    case .cylinder(let r, let h, let s):
      try c.encode(Tag.cylinder, forKey: .type)
      try c.encode(r, forKey: .radius)
      try c.encode(h, forKey: .height)
      try c.encode(s, forKey: .segments)
    case .cone(let top, let bottom, let height, let segments):
      try c.encode(Tag.cone, forKey: .type)
      try c.encode(top, forKey: .topRadius)
      try c.encode(bottom, forKey: .bottomRadius)
      try c.encode(height, forKey: .height)
      try c.encode(segments, forKey: .segments)
    case .capsule(let radius, let height, let segments):
      try c.encode(Tag.capsule, forKey: .type)
      try c.encode(radius, forKey: .radius)
      try c.encode(height, forKey: .height)
      try c.encode(segments, forKey: .segments)
    case .lathe(let profile, let segments):
      try c.encode(Tag.lathe, forKey: .type)
      try c.encode(profile, forKey: .profile)
      try c.encode(segments, forKey: .segments)
    case .extrusion(let profile, let depth, let rounding):
      try c.encode(Tag.extrusion, forKey: .type)
      try c.encode(profile, forKey: .profile)
      try c.encode(depth, forKey: .depth)
      if rounding != 0 { try c.encode(rounding, forKey: .cornerRounding) }
    case .torus(let r, let p, let s, let t):
      try c.encode(Tag.torus, forKey: .type)
      try c.encode(r, forKey: .ringRadius)
      try c.encode(p, forKey: .pipeRadius)
      try c.encode(s, forKey: .ringSegments)
      try c.encode(t, forKey: .pipeSegments)
    case .tube(let i, let o, let h, let s, let a, let b):
      try c.encode(Tag.tube, forKey: .type)
      try c.encode(i, forKey: .innerRadius)
      try c.encode(o, forKey: .outerRadius)
      try c.encode(h, forKey: .height)
      try c.encode(s, forKey: .segments)
      try c.encode(a, forKey: .startAngleDegrees)
      try c.encode(b, forKey: .sweepAngleDegrees)
    }
  }
  public func validatedBudget(limits: SceneLimits = .init()) throws -> SpatialGeometryBudget {
    func dimension(_ values: Double...) -> Bool {
      values.allSatisfy {
        $0.isFinite && $0 >= 0.001 && $0 <= min(1_000, limits.maximumSpatialDimension)
      }
    }
    func segments(_ values: Int...) -> Bool {
      values.allSatisfy { $0 >= 3 && $0 <= min(64, limits.maximumSpatialSegments) }
    }
    let cost: SpatialGeometryBudget
    switch self {
    case .box(let w, let h, let d, let r):
      guard dimension(w, h, d), r.isFinite, r >= 0, r <= min(w, min(h, d)) / 2 else {
        throw invalid()
      }
      cost = .init(vertices: r == 0 ? 24 : 512, triangles: r == 0 ? 12 : 1_024)
    case .sphere(let r, let s):
      guard dimension(r), segments(s) else { throw invalid() }
      // SceneKit constructs its default mesh before committing changed segment counts.
      // Admission must cover both that initial mesh and the requested tessellation.
      let nativeSegments = max(24, s)
      cost = .init(
        vertices: (nativeSegments + 1) * (nativeSegments + 1),
        triangles: 2 * nativeSegments * nativeSegments)
    case .cylinder(let r, let h, let s):
      guard dimension(r, h), segments(s) else { throw invalid() }
      let nativeSegments = max(48, s)
      // Each cap has its own center/rim vertices in addition to the side surface.
      cost = .init(vertices: 6 * (nativeSegments + 1), triangles: 4 * nativeSegments)
    case .cone(let top, let bottom, let height, let s):
      guard top.isFinite, bottom.isFinite, top >= 0, bottom >= 0,
        top == 0 || top >= 0.001, bottom == 0 || bottom >= 0.001,
        dimension(max(top, bottom), height), segments(s)
      else { throw invalid() }
      cost = .init(vertices: 12 * s, triangles: 4 * s)
    case .capsule(let radius, let height, let s):
      guard dimension(radius, height), height >= 2 * radius, segments(s) else { throw invalid() }
      let profileEdges = 2 * max(3, s / 2) + 2
      cost = .init(vertices: 4 * s * profileEdges, triangles: 2 * s * profileEdges)
    case .lathe(let profile, let s):
      guard segments(s) else { throw invalid() }
      let contour = try SpatialProfile3D.latheContour(
        profile, maximumDimension: limits.maximumSpatialDimension)
      cost = .init(vertices: 4 * s * contour.count, triangles: 2 * s * contour.count)
    case .extrusion(let profile, let depth, let rounding):
      guard dimension(depth) else { throw invalid() }
      let contour = try SpatialProfile3D.extrusionContour(
        profile, cornerRounding: rounding, maximumDimension: limits.maximumSpatialDimension)
      let triangles = try SpatialProfile3D.triangulation(
        contour, maximumDimension: limits.maximumSpatialDimension,
        maximumPoints: SpatialProfile3D.maximumExpandedPoints,
        minimumEdgeLength: rounding == 0 ? 0.001 : 0, preserveBoundary: rounding > 0)
      cost = .init(
        vertices: 4 * contour.count + 2 * triangles.count,
        triangles: 2 * contour.count + 2 * triangles.count / 3)
    case .torus(let r, let p, let s, let t):
      guard dimension(r, p), r > p, r + p <= limits.maximumSpatialDimension, segments(s, t) else {
        throw invalid()
      }
      let nativeRingSegments = max(48, s)
      let nativePipeSegments = max(24, t)
      cost = .init(
        vertices: (nativeRingSegments + 1) * (nativePipeSegments + 1),
        triangles: 2 * nativeRingSegments * nativePipeSegments)
    case .tube(let i, let o, let h, let s, let a, let b):
      guard dimension(i, o, h), o - i >= 0.001, segments(s), a.isFinite, abs(a) <= 360_000,
        b.isFinite, b >= 1, b <= 360
      else { throw invalid() }
      cost = .init(vertices: 16 * s + 8, triangles: 8 * s + 4)
    }
    guard cost.vertices <= min(32_768, limits.maximumSpatialVertices),
      cost.triangles <= min(65_536, limits.maximumSpatialTriangles)
    else {
      throw CoreError.budgetExceeded("3D geometry")
    }
    return cost
  }
  fileprivate var halfExtent: Vector3D {
    switch self {
    case .box(let w, let h, let d, _): return .init(x: w / 2, y: h / 2, z: d / 2)
    case .sphere(let r, _): return .init(x: r, y: r, z: r)
    case .cylinder(let r, let h, _): return .init(x: r, y: h / 2, z: r)
    case .cone(let top, let bottom, let height, _):
      return .init(x: max(top, bottom), y: height / 2, z: max(top, bottom))
    case .capsule(let radius, let height, _): return .init(x: radius, y: height / 2, z: radius)
    case .lathe(let profile, _):
      return .init(
        x: profile.map(\.radius).max() ?? 0, y: profile.map { abs($0.y) }.max() ?? 0,
        z: profile.map(\.radius).max() ?? 0)
    case .extrusion(let profile, let depth, _):
      return .init(
        x: profile.map { abs($0.x) }.max() ?? 0, y: profile.map { abs($0.y) }.max() ?? 0,
        z: depth / 2)
    case .torus(let r, let p, _, _): return .init(x: r + p, y: p, z: r + p)
    case .tube(_, let o, let h, _, _, _): return .init(x: o, y: h / 2, z: o)
    }
  }
  private func invalid() -> CoreError { .invalidDocument("3D geometry dimensions or tessellation") }

  private static func decodeProfile<T: Decodable>(
    _ type: T.Type, from c: KeyedDecodingContainer<Keys>, keys: Set<String>
  ) throws -> [T] {
    var values = try c.nestedUnkeyedContainer(forKey: .profile)
    var result: [T] = []
    while !values.isAtEnd {
      guard result.count < SpatialProfile3D.maximumPoints else {
        throw CoreError.budgetExceeded("3D profile points")
      }
      let decoder = try values.superDecoder()
      try SpatialDecoding.rejectUnknown(decoder, allowing: keys)
      result.append(try T(from: decoder))
    }
    return result
  }
}

public struct LabelAnchor3D: Codable, Equatable, Sendable {
  public var targetID: String
  public var point: Vector3D
  public var screenOffset: Point2D
  public var leader: Bool
  public init(
    targetID: String, point: Vector3D = .zero, screenOffset: Point2D = .init(x: 24, y: -18),
    leader: Bool = true
  ) {
    self.targetID = targetID
    self.point = point
    self.screenOffset = screenOffset
    self.leader = leader
  }
  private enum CodingKeys: String, CodingKey { case targetID, point, screenOffset, leader }
  public init(from decoder: any Decoder) throws {
    try SpatialDecoding.rejectUnknown(
      decoder, allowing: ["targetID", "point", "screenOffset", "leader"])
    let c = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      targetID: try c.decode(String.self, forKey: .targetID),
      point: try c.decodeIfPresent(Vector3D.self, forKey: .point) ?? .zero,
      screenOffset: try c.decodeIfPresent(Point2D.self, forKey: .screenOffset)
        ?? .init(x: 24, y: -18),
      leader: try c.decodeIfPresent(Bool.self, forKey: .leader) ?? true)
  }
}

public struct SceneSpatial3D: Codable, Equatable, Sendable {
  public var transform: Transform3D
  public var geometry: Geometry3D?
  public var labelAnchor: LabelAnchor3D?
  public init(
    transform: Transform3D = .identity, geometry: Geometry3D? = nil,
    labelAnchor: LabelAnchor3D? = nil
  ) {
    self.transform = transform
    self.geometry = geometry
    self.labelAnchor = labelAnchor
  }
  private enum CodingKeys: String, CodingKey { case transform, geometry, labelAnchor }
  public init(from decoder: any Decoder) throws {
    try SpatialDecoding.rejectUnknown(decoder, allowing: ["transform", "geometry", "labelAnchor"])
    let c = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      transform: try c.decodeIfPresent(Transform3D.self, forKey: .transform) ?? .identity,
      geometry: try c.decodeIfPresent(Geometry3D.self, forKey: .geometry),
      labelAnchor: try c.decodeIfPresent(LabelAnchor3D.self, forKey: .labelAnchor))
  }
}

public struct ScenePose3D: Equatable, Sendable {
  public let node: SceneNode
  public let transform: Matrix4x4D
  public let effectiveOpacity: Double
}

extension SceneDocument {
  public var usesSpatial3D: Bool {
    nodes.contains { $0.spatial3D != nil } || animations.contains { $0.axis3D != nil }
  }

  public func spatialWorldPoses(at time: Double, limits: SceneLimits = .init()) throws
    -> [ScenePose3D]
  {
    let resolved = try resolvedNodes(at: time)
    let nodes = resolved.filter { $0.spatial3D != nil && $0.kind != .text }
    var lookup: [String: SceneNode] = [:]
    for node in nodes {
      guard lookup.updateValue(node, forKey: node.id) == nil else {
        throw CoreError.duplicateID(node.id)
      }
    }
    var cache: [String: ScenePose3D] = [:]
    var visiting = Set<String>()
    func resolve(_ node: SceneNode, depth: Int) throws -> ScenePose3D {
      if let cached = cache[node.id] { return cached }
      guard depth <= 32, visiting.insert(node.id).inserted, let spatial = node.spatial3D else {
        throw CoreError.invalidDocument("3D hierarchy")
      }
      defer { visiting.remove(node.id) }
      try Self.validateSpatialTransform(spatial.transform)
      var world = spatial.transform.matrix
      var opacity = node.opacity
      if let id = node.parentID {
        guard let parent = lookup[id], parent.kind == .group else {
          throw CoreError.invalidDocument("3D parent must be a 3D group")
        }
        let pose = try resolve(parent, depth: depth + 1)
        world = pose.transform.multiplied(by: world)
        opacity *= pose.effectiveOpacity
      }
      guard world.validWorldTransform, opacity.isFinite, (0...1).contains(opacity) else {
        throw CoreError.invalidTransform
      }
      if let half = spatial.geometry?.halfExtent {
        // This is the exact AABB of the transformed primitive bounds. It checks
        // every corner without constructing eight points on every render frame.
        for row in 0..<3 {
          let extent =
            abs(world.elements[row]) * half.x + abs(world.elements[4 + row]) * half.y
            + abs(world.elements[8 + row]) * half.z
          let bound = abs(world.elements[12 + row]) + extent
          guard bound.isFinite, bound <= limits.maximumCoordinate else {
            throw CoreError.invalidTransform
          }
        }
      }
      let pose = ScenePose3D(node: node, transform: world, effectiveOpacity: opacity)
      cache[node.id] = pose
      return pose
    }
    let poses = try nodes.map { try resolve($0, depth: 0) }
    for label in resolved where label.kind == .text && label.spatial3D != nil {
      guard let anchor = label.spatial3D?.labelAnchor, let target = cache[anchor.targetID] else {
        throw CoreError.invalidDocument("3D label target")
      }
      let point = target.transform.applying(to: anchor.point)
      guard point.components.allSatisfy({ $0.isFinite && abs($0) <= limits.maximumCoordinate })
      else {
        throw CoreError.invalidTransform
      }
    }
    return poses
  }

  func validateSpatial3D(limits: SceneLimits) throws {
    let spatialNodes = nodes.filter { $0.spatial3D != nil }
    guard !spatialNodes.isEmpty else { return }
    guard spatialNodes.count <= min(128, limits.maximumSpatialNodes) else {
      throw CoreError.budgetExceeded("3D nodes")
    }
    var lookup: [String: SceneNode] = [:]
    for node in nodes { lookup[node.id] = node }
    var vertices = 0
    var triangles = 0
    for node in nodes {
      if let parentID = node.parentID, let parent = lookup[parentID],
        (node.spatial3D != nil) != (parent.spatial3D != nil)
      {
        throw CoreError.invalidDocument("2D and 3D parents cannot be mixed")
      }
      guard let spatial = node.spatial3D else { continue }
      try Self.validateSpatialTransform(spatial.transform)
      switch node.kind {
      case .mesh:
        guard let geometry = spatial.geometry, spatial.labelAnchor == nil else {
          throw CoreError.invalidDocument("3D mesh needs geometry only")
        }
        let cost = try geometry.validatedBudget(limits: limits)
        vertices += cost.vertices
        triangles += cost.triangles
      case .group:
        guard spatial.geometry == nil, spatial.labelAnchor == nil else {
          throw CoreError.invalidDocument("3D group is transform only")
        }
      case .text:
        guard spatial.geometry == nil, spatial.transform == .identity, node.parentID == nil,
          let anchor = spatial.labelAnchor, let target = lookup[anchor.targetID],
          [.mesh, .group].contains(target.kind), target.spatial3D != nil,
          !anchor.targetID.isEmpty, anchor.targetID.utf8.count <= 256,
          anchor.point.components.allSatisfy({
            $0.isFinite && abs($0) <= limits.maximumSpatialDimension
          }),
          anchor.screenOffset.isFinite, abs(anchor.screenOffset.x) <= 4_096,
          abs(anchor.screenOffset.y) <= 4_096
        else { throw CoreError.invalidDocument("3D label anchor") }
      default: throw CoreError.invalidDocument("unsupported 3D node kind")
      }
      guard vertices <= min(32_768, limits.maximumSpatialVertices),
        triangles <= min(65_536, limits.maximumSpatialTriangles)
      else { throw CoreError.budgetExceeded("aggregate 3D geometry") }
    }
    _ = try spatialWorldPoses(at: 0, limits: limits)
  }

  private static func validateSpatialTransform(_ transform: Transform3D) throws {
    guard transform.position.components.allSatisfy({ $0.isFinite && abs($0) <= 1_000 }),
      transform.rotationDegrees.components.allSatisfy({ $0.isFinite && abs($0) <= 360_000 }),
      transform.scale.components.allSatisfy({ $0.isFinite && (0.001...100).contains($0) })
    else { throw CoreError.invalidTransform }
  }
}

private enum SpatialDecoding {
  struct Key: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }
    init(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
  }
  static func rejectUnknown(_ decoder: any Decoder, allowing allowed: Set<String>) throws {
    let c = try decoder.container(keyedBy: Key.self)
    guard c.allKeys.allSatisfy({ allowed.contains($0.stringValue) }) else {
      throw CoreError.invalidDocument("unknown or mixed 3D fields")
    }
  }
}
