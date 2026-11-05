import Foundation
import Testing

@testable import CompanionCore

struct SpatialConnectorTests {
  @Test func strictWireDefaultsRoundTripAndUnknownAuthorityRejects() throws {
    let wire =
      ##"{"id":"link","from":{"targetID":"a"},"to":{"targetID":"b"},"radius":0.06,"fill":"#778899"}"##
    let connector = try JSONDecoder().decode(SpatialConnector.self, from: Data(wire.utf8))
    #expect(connector.from.point == .zero && connector.to.point == .zero)
    #expect(connector.segments == 24 && connector.opacity == 1 && connector.parentID == nil)
    let encoded = try JSONEncoder().encode(connector)
    #expect(try JSONDecoder().decode(SpatialConnector.self, from: encoded) == connector)
    for key in ["geometry", "transform", "spatial3D", "kind", "height", "bindings", "url"] {
      let mixed = String(wire.dropLast()) + ",\"\(key)\":null}"
      #expect(throws: (any Error).self) {
        try JSONDecoder().decode(SpatialConnector.self, from: Data(mixed.utf8))
      }
    }
    for endpoint in [
      #"{"targetID":"a","position":{"x":0,"y":0,"z":0}}"#,
      #"{"targetID":"a","point":{"x":0,"y":0,"z":0,"w":1}}"#,
    ] {
      #expect(throws: (any Error).self) {
        try JSONDecoder().decode(SpatialConnectorEndpoint.self, from: Data(endpoint.utf8))
      }
    }
  }

  @Test func obliqueEndpointPointsDetermineBothCylinderCapsWithoutMutation() throws {
    let a = mesh("a", position: .init(x: -2, y: 1, z: 0.8))
    let b = mesh("b", position: .init(x: 1, y: -2, z: 3))
    let document = try SceneDocument(nodes: [a, b]).validated()
    let original = document
    let from = Vector3D(x: 0.2, y: -0.3, z: 0.4)
    let to = Vector3D(x: -0.1, y: 0.2, z: -0.2)
    let request = SpatialConnector(
      id: "rod", from: .init(targetID: "a", point: from), to: .init(targetID: "b", point: to),
      radius: 0.07, fill: "#AABBCC")
    let nodes = try SpatialConnectorCompiler.compile([request], in: document)
    let node = try #require(nodes.first)
    try expectCaps(
      node, in: document, from: .init(x: -1.8, y: 0.7, z: 1.2),
      to: .init(x: 0.9, y: -1.8, z: 2.8))
    #expect(node.fill == request.fill && node.bindings.isEmpty && node.kind == .mesh)
    #expect(document == original && document.revision == 0)
    #expect(request.from.point == from && request.to.point == to)
  }

  @Test func rotatedNonuniformParentPreservesIndependentWorldEndpoints() throws {
    let groupTransform = Transform3D(
      position: .init(x: 3, y: -2, z: 1), rotationDegrees: .init(x: 25, y: -35, z: 48),
      scale: .init(x: 2, y: 0.7, z: 1.3))
    let group = SceneNode(id: "assembly", kind: .group, spatial3D: .init(transform: groupTransform))
    var a = mesh("a", position: .init(x: -1, y: 0.4, z: 0.2))
    a.parentID = group.id
    a.spatial3D?.transform.rotationDegrees = .init(x: 13, y: -21, z: 7)
    var b = mesh("b", position: .init(x: 0.8, y: -0.2, z: 1.4))
    b.parentID = group.id
    b.spatial3D?.transform.scale = .init(x: 0.5, y: 1.1, z: 0.8)
    let document = try SceneDocument(nodes: [a, b, group]).validated()
    let p = Vector3D(x: 0.2, y: -0.1, z: 0.3)
    let q = Vector3D(x: -0.2, y: 0.1, z: 0)
    let expectedFrom = manualApply(
      groupTransform, to: manualApply(try #require(a.spatial3D).transform, to: p))
    let expectedTo = manualApply(
      groupTransform, to: manualApply(try #require(b.spatial3D).transform, to: q))
    for parentID: String? in [nil, group.id] {
      let connector = SpatialConnector(
        id: "link", from: .init(targetID: a.id, point: p), to: .init(targetID: b.id, point: q),
        radius: 0.04, fill: "#FFFFFF", parentID: parentID)
      let result = try SpatialConnectorCompiler.compile([connector], in: document)
      let node = try #require(result.first)
      try expectCaps(node, in: document, from: expectedFrom, to: expectedTo)
      #expect(node.parentID == parentID)
    }
  }

  @Test(arguments: [Vector3D(x: 0, y: -3, z: 0), Vector3D(x: 0, y: 0, z: 3)])
  func antiparallelAndPoleDirectionsDoNotNeedApproximateAxisBranches(_ end: Vector3D) throws {
    let document = SceneDocument(nodes: [mesh("a"), mesh("b", position: end)])
    let nodes = try SpatialConnectorCompiler.compile([connector()], in: document)
    try expectCaps(try #require(nodes.first), in: document, from: .zero, to: end)
  }

  @Test func sameTransactionLabelCanReferenceGeneratedMesh() throws {
    let label = SceneNode(
      id: "caption", kind: .text, text: "Connector",
      spatial3D: .init(labelAnchor: .init(targetID: "link")))
    let document = SceneDocument(nodes: [
      mesh("a"), mesh("b", position: .init(x: 2, y: 0, z: 0)), label,
    ])
    let nodes = try SpatialConnectorCompiler.compile([connector()], in: document)
    var final = document
    final.nodes.append(contentsOf: nodes)
    #expect(try final.validated().nodes.count == 4)
    #expect(document.nodes.count == 3 && document.nodes.last == label)
  }

  @Test func duplicateCollisionConstructionReferencesAndWrongDomainsReject() throws {
    let document = SceneDocument(nodes: [mesh("a"), mesh("b", position: .init(x: 2, y: 0, z: 0))])
    var duplicate = connector()
    duplicate.id = "a"
    var missing = connector()
    missing.to.targetID = "missing"
    var selfReference = connector()
    selfReference.from.targetID = selfReference.id
    var futureReference = connector()
    futureReference.to.targetID = "other-link"
    var second = connector()
    second.id = "other-link"
    for requests in [
      [connector(), connector()], [duplicate], [missing], [selfReference],
      [futureReference, second],
    ] {
      #expect(throws: CoreError.self) {
        try SpatialConnectorCompiler.compile(requests, in: document)
      }
    }
    for target in [
      SceneNode(id: "a", kind: .group, spatial3D: .init()),
      SceneNode(id: "a", kind: .mesh),
      SceneNode(id: "a", kind: .text, text: "Text"),
    ] {
      let wrong = SceneDocument(nodes: [target, document.nodes[1]])
      #expect(throws: CoreError.self) {
        try SpatialConnectorCompiler.compile([connector()], in: wrong)
      }
    }
    var wrongParent = connector()
    wrongParent.parentID = "a"
    #expect(throws: CoreError.self) {
      try SpatialConnectorCompiler.compile([wrongParent], in: document)
    }
  }

  @Test func cyclesAndDynamicEndpointOrParentAncestryReject() throws {
    let group = SceneNode(id: "group", kind: .group, spatial3D: .init())
    var a = mesh("a")
    a.parentID = group.id
    let b = mesh("b", position: .init(x: 2, y: 0, z: 0))
    let base = SceneDocument(nodes: [a, b, group])
    for targetID in ["a", "b", "group", "link"] {
      var dynamic = base
      dynamic.animations = [.init(id: "spin", targetID: targetID, axis3D: .z)]
      #expect(throws: CoreError.self) {
        try SpatialConnectorCompiler.compile([connector()], in: dynamic)
      }
    }
    for index in [0, 1, 2] {
      var dynamic = base
      dynamic.nodes[index].bindings["opacity"] = .number(1)
      #expect(throws: CoreError.self) {
        try SpatialConnectorCompiler.compile([connector()], in: dynamic)
      }
    }
    var cycle = base
    cycle.nodes[2].parentID = "group"
    #expect(throws: CoreError.self) {
      try SpatialConnectorCompiler.compile([connector()], in: cycle)
    }
    var parentOnlyDynamic = base
    parentOnlyDynamic.nodes.append(.init(id: "output-parent", kind: .group, spatial3D: .init()))
    parentOnlyDynamic.animations = [.init(id: "move", targetID: "output-parent", behavior: .flow)]
    var request = connector()
    request.parentID = "output-parent"
    #expect(throws: CoreError.self) {
      try SpatialConnectorCompiler.compile([request], in: parentOnlyDynamic)
    }
  }

  @Test func unrelatedAnimationsAndUnresolvedBindingsDoNotEnterEndpointMath() throws {
    var unrelated = mesh("other", position: .init(x: 0, y: 3, z: 0))
    unrelated.bindings["spatial3D.transform.position.x"] = .reference(
      "defined-by-pending-operation")
    let document = SceneDocument(
      nodes: [mesh("a"), mesh("b", position: .init(x: 2, y: 0, z: 0)), unrelated],
      animations: [.init(id: "unrelated-spin", targetID: unrelated.id, axis3D: .y)])
    let nodes = try SpatialConnectorCompiler.compile([connector()], in: document)
    try expectCaps(
      try #require(nodes.first), in: SceneDocument(nodes: Array(document.nodes.prefix(2))),
      from: .zero, to: .init(x: 2, y: 0, z: 0))
    #expect(document.animations.count == 1 && document.nodes.last?.bindings == unrelated.bindings)
  }

  @Test func nonfiniteZeroLengthUnboundedPointsAndInvalidMaterialsReject() throws {
    let document = SceneDocument(nodes: [mesh("a"), mesh("b", position: .init(x: 2, y: 0, z: 0))])
    for point in [
      Vector3D(x: .nan, y: 0, z: 0), .init(x: 0, y: .infinity, z: 0), .init(x: 1_001, y: 0, z: 0),
    ] {
      var request = connector()
      request.from.point = point
      #expect(throws: CoreError.self) {
        try SpatialConnectorCompiler.compile([request], in: document)
      }
    }
    var zero = document
    zero.nodes[1].spatial3D?.transform.position = .zero
    #expect(throws: CoreError.self) {
      try SpatialConnectorCompiler.compile([connector()], in: zero)
    }
    for radius in [-1.0, 0, .nan, .infinity, 1_001] {
      var request = connector()
      request.radius = radius
      #expect(throws: CoreError.self) {
        try SpatialConnectorCompiler.compile([request], in: document)
      }
    }
    var invalidMaterial = connector()
    invalidMaterial.fill = "not-a-color"
    #expect(throws: CoreError.self) {
      try SpatialConnectorCompiler.compile([invalidMaterial], in: document)
    }
    invalidMaterial = connector()
    invalidMaterial.opacity = .nan
    #expect(throws: CoreError.self) {
      try SpatialConnectorCompiler.compile([invalidMaterial], in: document)
    }
  }

  @Test func countsGeometryAggregateDepthAndWorldBoundsRemainNativeGates() throws {
    let document = SceneDocument(nodes: [mesh("a"), mesh("b", position: .init(x: 2, y: 0, z: 0))])
    let many = (0..<17).map { index -> SpatialConnector in
      var request = connector()
      request.id = "link-\(index)"
      return request
    }
    #expect(throws: CoreError.self) { try SpatialConnectorCompiler.compile(many, in: document) }
    var segments = connector()
    segments.segments = 65
    #expect(throws: CoreError.self) {
      try SpatialConnectorCompiler.compile([segments], in: document)
    }
    var limits = SceneLimits()
    limits.maximumSpatialVertices = 1_300
    #expect(throws: CoreError.self) {
      try SpatialConnectorCompiler.compile([connector()], in: document, limits: limits)
    }
    limits = SceneLimits()
    limits.maximumNodes = 2
    #expect(throws: CoreError.self) {
      try SpatialConnectorCompiler.compile([connector()], in: document, limits: limits)
    }
    var world = document
    world.nodes.append(
      .init(
        id: "huge", kind: .group,
        spatial3D: .init(transform: .init(scale: .init(x: 100, y: 100, z: 100)))))
    world.nodes[0].parentID = "huge"
    world.nodes[0].spatial3D?.transform.position = .init(x: 1_000, y: 0, z: 0)
    #expect(throws: CoreError.self) {
      try SpatialConnectorCompiler.compile([connector()], in: world)
    }
    var deep = document
    deep.nodes.append(.init(id: "group", kind: .group, spatial3D: .init()))
    deep.nodes[0].parentID = "group"
    limits = SceneLimits()
    limits.maximumDepth = 0
    #expect(throws: CoreError.self) {
      try SpatialConnectorCompiler.compile([connector()], in: deep, limits: limits)
    }
    #expect(try SpatialConnectorCompiler.compile([], in: document).isEmpty)
  }

  private func connector() -> SpatialConnector {
    .init(
      id: "link", from: .init(targetID: "a"), to: .init(targetID: "b"), radius: 0.06,
      fill: "#778899")
  }

  private func mesh(_ id: String, position: Vector3D = .zero) -> SceneNode {
    .init(
      id: id, kind: .mesh,
      spatial3D: .init(transform: .init(position: position), geometry: .sphere(radius: 0.5)))
  }

  private func expectCaps(
    _ node: SceneNode, in document: SceneDocument, from: Vector3D, to: Vector3D
  ) throws {
    guard case .cylinder(_, let height, _) = node.spatial3D?.geometry else {
      Issue.record("A compiled connector must have cylinder geometry")
      return
    }
    var augmented = document
    augmented.nodes.append(node)
    let pose = try #require(augmented.spatialWorldPoses(at: 0).first { $0.node.id == node.id })
    let start = pose.transform.applying(to: .init(x: 0, y: -height / 2, z: 0))
    let end = pose.transform.applying(to: .init(x: 0, y: height / 2, z: 0))
    #expect(distance(start, from) < 1e-8)
    #expect(distance(end, to) < 1e-8)
  }

  private func distance(_ a: Vector3D, _ b: Vector3D) -> Double {
    hypot(hypot(a.x - b.x, a.y - b.y), a.z - b.z)
  }

  /// An independent scalar T*Rz*Ry*Rx*S implementation for endpoint oracles.
  private func manualApply(_ transform: Transform3D, to point: Vector3D) -> Vector3D {
    let x = point.x * transform.scale.x
    let y = point.y * transform.scale.y
    let z = point.z * transform.scale.z
    let rx = transform.rotationDegrees.x * .pi / 180
    let ry = transform.rotationDegrees.y * .pi / 180
    let rz = transform.rotationDegrees.z * .pi / 180
    let yy = y * cos(rx) - z * sin(rx)
    let zz = y * sin(rx) + z * cos(rx)
    let xx = x * cos(ry) + zz * sin(ry)
    let zzz = -x * sin(ry) + zz * cos(ry)
    return .init(
      x: xx * cos(rz) - yy * sin(rz) + transform.position.x,
      y: xx * sin(rz) + yy * cos(rz) + transform.position.y,
      z: zzz + transform.position.z)
  }
}
