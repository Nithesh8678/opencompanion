import Foundation

/// A target-local attachment point. Omitting point selects the target's center;
/// this does not infer or move the point onto the target's surface.
public struct SpatialConnectorEndpoint: Codable, Equatable, Sendable {
  public var targetID: String
  public var point: Vector3D

  public init(targetID: String, point: Vector3D = .zero) {
    self.targetID = targetID
    self.point = point
  }

  private enum CodingKeys: String, CodingKey { case targetID, point }

  public init(from decoder: any Decoder) throws {
    try ConnectorDecoding.rejectUnknown(decoder, allowing: ["targetID", "point"])
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      targetID: try container.decode(String.self, forKey: .targetID),
      point: try container.decodeIfPresent(Vector3D.self, forKey: .point) ?? .zero)
  }
}

/// An explicitly requested static cylinder joining two existing typed meshes.
/// Geometry and transform are derived locally; the wire has no such fields.
public struct SpatialConnector: Codable, Equatable, Sendable {
  public var id: String
  public var from, to: SpatialConnectorEndpoint
  public var radius: Double
  public var segments: Int
  public var fill: String
  public var parentID: String?
  public var opacity: Double

  public init(
    id: String, from: SpatialConnectorEndpoint, to: SpatialConnectorEndpoint,
    radius: Double, segments: Int = 24, fill: String, parentID: String? = nil,
    opacity: Double = 1
  ) {
    self.id = id
    self.from = from
    self.to = to
    self.radius = radius
    self.segments = segments
    self.fill = fill
    self.parentID = parentID
    self.opacity = opacity
  }

  private enum CodingKeys: String, CodingKey {
    case id, from, to, radius, segments, fill, parentID, opacity
  }

  public init(from decoder: any Decoder) throws {
    try ConnectorDecoding.rejectUnknown(
      decoder,
      allowing: ["id", "from", "to", "radius", "segments", "fill", "parentID", "opacity"])
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      id: try container.decode(String.self, forKey: .id),
      from: try container.decode(SpatialConnectorEndpoint.self, forKey: .from),
      to: try container.decode(SpatialConnectorEndpoint.self, forKey: .to),
      radius: try container.decode(Double.self, forKey: .radius),
      segments: try container.decodeIfPresent(Int.self, forKey: .segments) ?? 24,
      fill: try container.decode(String.self, forKey: .fill),
      parentID: try container.decodeIfPresent(String.self, forKey: .parentID),
      opacity: try container.decodeIfPresent(Double.self, forKey: .opacity) ?? 1)
  }
}

public enum SpatialConnectorCompiler {
  /// Returns new nodes without mutating the supplied working graph. This is a
  /// static construction, not a joint that follows later edits or animations.
  /// The caller must still admit the final atomic transaction, including its
  /// actual animation/removal operations and document revision.
  public static func compile(
    _ connectors: [SpatialConnector], in document: SceneDocument,
    limits: SceneLimits = .init()
  ) throws -> [SceneNode] {
    guard connectors.count <= 16, document.nodes.count <= min(1_024, limits.maximumNodes),
      document.animations.count <= 2_560
    else { throw CoreError.budgetExceeded("spatial connectors") }
    guard !connectors.isEmpty else { return [] }
    try Task.checkCancellation()

    var lookup: [String: SceneNode] = [:]
    for node in document.nodes {
      guard validIdentifier(node.id) else { throw invalid("existing node identifier") }
      guard lookup.updateValue(node, forKey: node.id) == nil else {
        throw CoreError.duplicateID(node.id)
      }
    }
    var connectorIDs = Set<String>()
    for connector in connectors {
      guard validIdentifier(connector.id) else { throw invalid("identifier") }
      guard connectorIDs.insert(connector.id).inserted, lookup[connector.id] == nil else {
        throw CoreError.duplicateID(connector.id)
      }
    }
    let animatedIDs = Set(document.animations.map(\.targetID))
    guard animatedIDs.isDisjoint(with: connectorIDs) else {
      throw invalid("a connector cannot be animated")
    }

    func requireStaticAncestry(_ id: String) throws {
      var next: String? = id
      var visited = Set<String>()
      while let current = next {
        guard visited.count <= min(32, limits.maximumDepth), visited.insert(current).inserted else {
          throw invalid("parent depth or cycle")
        }
        guard let node = lookup[current] else { throw CoreError.missingReference(current) }
        guard node.bindings.isEmpty, !animatedIDs.contains(current) else {
          throw invalid("endpoints and parent ancestry must be static")
        }
        next = node.parentID
      }
    }

    for connector in connectors {
      for endpoint in [connector.from, connector.to] {
        guard validIdentifier(endpoint.targetID), !connectorIDs.contains(endpoint.targetID),
          let target = lookup[endpoint.targetID], target.kind == .mesh,
          target.spatial3D?.geometry != nil
        else { throw invalid("endpoint must reference an existing typed mesh") }
        guard
          endpoint.point.components.allSatisfy({
            $0.isFinite && abs($0) <= min(1_000, limits.maximumSpatialDimension)
          })
        else { throw invalid("endpoint coordinate") }
        try requireStaticAncestry(endpoint.targetID)
      }
      if let parentID = connector.parentID {
        guard validIdentifier(parentID), !connectorIDs.contains(parentID),
          let parent = lookup[parentID], parent.kind == .group, parent.spatial3D != nil
        else { throw invalid("parent must reference an existing typed group") }
        try requireStaticAncestry(parentID)
      }
    }

    // No labels, bindings or animations participate in prerequisite pose math.
    // In particular, same-transaction labels may reference the new connectors.
    let staticNodes = document.nodes.compactMap { original -> SceneNode? in
      guard original.spatial3D != nil, original.kind != .text else { return nil }
      var node = original
      node.bindings = [:]
      return node
    }
    let math = SceneDocument(nodes: staticNodes)
    let poses = try math.spatialWorldPoses(at: 0, limits: limits)
    let transforms = Dictionary(uniqueKeysWithValues: poses.map { ($0.node.id, $0.transform) })
    var result: [SceneNode] = []
    result.reserveCapacity(connectors.count)
    for connector in connectors {
      try Task.checkCancellation()
      guard let fromTransform = transforms[connector.from.targetID],
        let toTransform = transforms[connector.to.targetID]
      else { throw invalid("missing endpoint transform") }
      let fromWorld = fromTransform.applying(to: connector.from.point)
      let toWorld = toTransform.applying(to: connector.to.point)
      guard
        [fromWorld, toWorld].allSatisfy({ point in
          point.components.allSatisfy({ $0.isFinite && abs($0) <= limits.maximumCoordinate })
        })
      else { throw invalid("world endpoint coordinate") }
      let from: Vector3D
      let to: Vector3D
      if let parentID = connector.parentID {
        guard let matrix = transforms[parentID] else { throw invalid("missing parent transform") }
        let inverse = try AffineInverse(matrix)
        from = inverse.applying(to: fromWorld)
        to = inverse.applying(to: toWorld)
      } else {
        from = fromWorld
        to = toWorld
      }
      let delta = Vector3D(x: to.x - from.x, y: to.y - from.y, z: to.z - from.z)
      let planarLength = hypot(delta.x, delta.y)
      let length = hypot(planarLength, delta.z)
      guard from.isFinite, to.isFinite, length.isFinite, length >= 0.001 else {
        throw invalid("zero-length or nonfinite connector")
      }
      let geometry = Geometry3D.cylinder(
        radius: connector.radius, height: length, segments: connector.segments)
      _ = try geometry.validatedBudget(limits: limits)
      // Rz * Rx maps local +Y exactly onto the endpoint direction, including
      // anti-parallel +Y and the poles; no approximate axis classification.
      let transform = Transform3D(
        position: .init(x: from.x + delta.x / 2, y: from.y + delta.y / 2, z: from.z + delta.z / 2),
        rotationDegrees: .init(
          x: atan2(delta.z, planarLength) * 180 / .pi, y: 0,
          z: atan2(-delta.x, delta.y) * 180 / .pi))
      result.append(
        SceneNode(
          id: connector.id, kind: .mesh, fill: connector.fill, opacity: connector.opacity,
          parentID: connector.parentID, spatial3D: .init(transform: transform, geometry: geometry)))
    }
    var augmented = document
    augmented.nodes.append(contentsOf: result)
    // Context animations may include conservative pre-removal proposals.
    // They were scanned above; the caller validates actual animation operations.
    augmented.animations = []
    for index in augmented.nodes.indices { augmented.nodes[index].bindings = [:] }
    augmented.parameters = [:]
    augmented.expressions = [:]
    augmented.controls = []
    _ = try augmented.validated(limits: limits)
    return result
  }

  private static func validIdentifier(_ id: String) -> Bool {
    !id.isEmpty && id.utf8.count <= 256
  }

  private static func invalid(_ detail: String) -> CoreError {
    .invalidDocument("spatial connector: " + detail)
  }

  private struct AffineInverse {
    let translation, rowX, rowY, rowZ: Vector3D
    let determinant: Double

    init(_ matrix: Matrix4x4D) throws {
      let m = matrix.elements
      let a = Vector3D(x: m[0], y: m[1], z: m[2])
      let b = Vector3D(x: m[4], y: m[5], z: m[6])
      let c = Vector3D(x: m[8], y: m[9], z: m[10])
      translation = .init(x: m[12], y: m[13], z: m[14])
      rowX = Self.cross(b, c)
      rowY = Self.cross(c, a)
      rowZ = Self.cross(a, b)
      determinant = Self.dot(a, rowX)
      guard determinant.isFinite, abs(determinant) > 1e-24 else {
        throw CoreError.invalidTransform
      }
    }

    func applying(to point: Vector3D) -> Vector3D {
      let p = Vector3D(
        x: point.x - translation.x, y: point.y - translation.y, z: point.z - translation.z)
      return .init(
        x: Self.dot(p, rowX) / determinant, y: Self.dot(p, rowY) / determinant,
        z: Self.dot(p, rowZ) / determinant)
    }

    private static func cross(_ a: Vector3D, _ b: Vector3D) -> Vector3D {
      .init(x: a.y * b.z - a.z * b.y, y: a.z * b.x - a.x * b.z, z: a.x * b.y - a.y * b.x)
    }

    private static func dot(_ a: Vector3D, _ b: Vector3D) -> Double {
      a.x * b.x + a.y * b.y + a.z * b.z
    }
  }
}

private enum ConnectorDecoding {
  private struct Key: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }
    init(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
  }

  static func rejectUnknown(_ decoder: any Decoder, allowing allowed: Set<String>) throws {
    let container = try decoder.container(keyedBy: Key.self)
    guard container.allKeys.allSatisfy({ allowed.contains($0.stringValue) }) else {
      throw CoreError.invalidDocument("unknown or mixed spatial connector fields")
    }
  }
}
