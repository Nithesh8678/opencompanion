import Foundation
import Testing

@testable import CompanionCore

struct Spatial3DTests {
  @Test func primitiveTagsRoundTripWithExplicitDimensionsAndDefaults() throws {
    for json in [
      #"{"type":"box","width":2,"height":1,"depth":1}"#,
      #"{"type":"sphere","radius":0.5}"#,
      #"{"type":"cylinder","radius":0.1,"height":3}"#,
      #"{"type":"torus","ringRadius":0.6,"pipeRadius":0.1}"#,
      #"{"type":"tube","innerRadius":0.9,"outerRadius":1.1,"height":2,"sweepAngleDegrees":240}"#,
    ] {
      let shape = try JSONDecoder().decode(Geometry3D.self, from: Data(json.utf8))
      let budget = try shape.validatedBudget()
      #expect(budget.vertices > 0 && budget.triangles > 0)
      let encoded = try JSONEncoder().encode(shape)
      #expect(try JSONDecoder().decode(Geometry3D.self, from: encoded) == shape)
    }
  }

  @Test func unknownMixedAssetAndMissingGeometryFieldsReject() {
    for json in [
      #"{"type":"externalModel","url":"https://example.invalid/model"}"#,
      #"{"type":"box","width":2,"height":1,"depth":1,"radius":1}"#,
      #"{"type":"sphere","radius":1,"shader":"code"}"#,
      #"{"type":"cylinder","radius":1,"height":2,"url":"file:///fixture"}"#,
      #"{"type":"box","width":2,"height":1}"#,
    ] {
      #expect(throws: (any Error).self) {
        try JSONDecoder().decode(Geometry3D.self, from: Data(json.utf8))
      }
    }
    #expect(throws: (any Error).self) {
      try JSONDecoder().decode(
        Transform3D.self, from: Data(#"{"position":{"x":0,"y":0,"z":0},"matrix":[1]}"#.utf8))
    }
  }

  @Test func invalidGeometryAndTessellationRejectBeforeNativeAllocation() {
    for shape in [
      Geometry3D.box(width: -1, height: 1, depth: 1),
      .box(width: 1, height: 1, depth: 1, chamferRadius: 0.6),
      .sphere(radius: .nan), .sphere(radius: 1, segments: Int.max),
      .cylinder(radius: 1, height: .infinity),
      .torus(ringRadius: 0.2, pipeRadius: 0.4),
      .tube(innerRadius: 0, outerRadius: 1, height: 1),
      .tube(innerRadius: 0.99, outerRadius: 1, height: 1, sweepAngleDegrees: 0.000_001),
      .tube(innerRadius: 1, outerRadius: 0.5, height: 1),
    ] {
      #expect(throws: CoreError.self) { try shape.validatedBudget() }
    }
    var low = SceneLimits()
    low.maximumSpatialSegments = 2
    #expect(throws: CoreError.self) {
      try Geometry3D.sphere(radius: 1).validatedBudget(limits: low)
    }
  }

  @Test func aggregateGeometryAndNodeBudgetsAreEnforced() throws {
    let expensive = SceneDocument(
      nodes: (0..<9).map {
        mesh("sphere-\($0)", geometry: .sphere(radius: 1, segments: 64))
      })
    #expect(throws: CoreError.self) { try expensive.validated() }
    let groups = SceneDocument(
      nodes: (0..<129).map {
        SceneNode(id: "group-\($0)", kind: .group, spatial3D: .init())
      })
    #expect(throws: CoreError.self) { try groups.validated() }
    var tiny = SceneLimits()
    tiny.maximumSpatialVertices = 23
    #expect(throws: CoreError.self) {
      try SceneDocument(nodes: [mesh("box")]).validated(limits: tiny)
    }
  }

  @Test func nativeConstructorMeshesAreIncludedInAdmissionBeforeAllocation() throws {
    let cylinder = Geometry3D.cylinder(radius: 0.2, height: 2, segments: 3)
    let torus = Geometry3D.torus(
      ringRadius: 1, pipeRadius: 0.1, ringSegments: 3, pipeSegments: 3)
    let sphere = Geometry3D.sphere(radius: 1, segments: 3)
    #expect(try cylinder.validatedBudget() == .init(vertices: 294, triangles: 192))
    #expect(try torus.validatedBudget() == .init(vertices: 1_225, triangles: 2_304))
    #expect(try sphere.validatedBudget() == .init(vertices: 625, triangles: 1_152))
    var insufficient = SceneLimits()
    insufficient.maximumSpatialVertices = 293
    #expect(throws: CoreError.self) { try cylinder.validatedBudget(limits: insufficient) }
    insufficient.maximumSpatialVertices = 32_768
    insufficient.maximumSpatialTriangles = 2_303
    #expect(throws: CoreError.self) { try torus.validatedBudget(limits: insufficient) }
    let repeated = SceneDocument(
      nodes: (0..<27).map { mesh("torus-\($0)", geometry: torus) })
    #expect(throws: CoreError.self) { try repeated.validated() }
  }

  @Test func versionOneDocumentsAndLegacyMotorKeepTheirExistingMeaning() throws {
    let motor = try BuiltInLessons.motor()
    #expect(!motor.usesSpatial3D && motor.nodes.allSatisfy { $0.spatial3D == nil })
    let encoded = try JSONEncoder().encode(motor)
    let json = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    #expect(json["specVersion"] as? String == SceneDocument.schemaVersion)
    #expect(try JSONDecoder().decode(SceneDocument.self, from: encoded) == motor)
  }

  @Test func typedDocumentsUseVersionTwoAndCannotMasqueradeAsLegacy() throws {
    let document = SceneDocument(nodes: [mesh("body")])
    let encoded = try JSONEncoder().encode(document)
    var json = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    #expect(json["specVersion"] as? String == SceneDocument.spatialSchemaVersion)
    #expect(try JSONDecoder().decode(SceneDocument.self, from: encoded) == document)
    for version in [SceneDocument.schemaVersion, "opencompanion.scene/999"] {
      json["specVersion"] = version
      let invalid = try JSONSerialization.data(withJSONObject: json)
      #expect(throws: CoreError.self) {
        try JSONDecoder().decode(SceneDocument.self, from: invalid)
      }
    }
    json.removeValue(forKey: "specVersion")
    let unversioned = try JSONSerialization.data(withJSONObject: json)
    #expect(throws: CoreError.self) {
      try JSONDecoder().decode(SceneDocument.self, from: unversioned)
    }
  }

  @Test func parentTransformsComposeInThreeDimensionsWithChildBeforeParent() throws {
    let group = SceneNode(
      id: "assembly", kind: .group,
      spatial3D: .init(
        transform: .init(
          position: .init(x: 10, y: 0, z: 0),
          rotationDegrees: .init(x: 0, y: 0, z: 90), scale: .init(x: 2, y: 2, z: 2))))
    var child = mesh("part")
    child.parentID = group.id
    child.spatial3D?.transform.position = .init(x: 1, y: 0, z: 0)
    let label = SceneNode(
      id: "caption", kind: .text, text: "Part",
      spatial3D: .init(labelAnchor: .init(targetID: child.id, point: .init(x: 1, y: 0, z: 0))))
    let document = try SceneDocument(nodes: [child, label, group]).validated()
    let pose = try #require(document.spatialWorldPoses(at: 0).first { $0.node.id == child.id })
    let origin = pose.transform.applying(to: .zero)
    let anchor = pose.transform.applying(to: try #require(label.spatial3D?.labelAnchor).point)
    #expect(abs(origin.x - 10) < 0.000_001 && abs(origin.y - 2) < 0.000_001)
    #expect(abs(anchor.x - 10) < 0.000_001 && abs(anchor.y - 4) < 0.000_001)
    #expect(origin.z == 0 && anchor.z == 0)
  }

  @Test func mixedHierarchiesSingularScalesAndInvalidAnchorsReject() throws {
    let typedGroup = SceneNode(id: "typed", kind: .group, spatial3D: .init())
    let plainGroup = SceneNode(id: "plain", kind: .group)
    var typedChild = mesh("part")
    typedChild.parentID = plainGroup.id
    let plainChild = SceneNode(
      id: "text", kind: .text, text: "Wrong parent", parentID: typedGroup.id)
    var singular = mesh("singular")
    singular.spatial3D?.transform.scale.z = 0
    let missingLabel = SceneNode(
      id: "label", kind: .text, text: "Missing",
      spatial3D: .init(labelAnchor: .init(targetID: "not-present")))
    for nodes in [[plainGroup, typedChild], [typedGroup, plainChild], [singular], [missingLabel]] {
      #expect(throws: CoreError.self) { try SceneDocument(nodes: nodes).validated() }
    }
  }

  @Test func explicitAxisAnimationAndSafeBindingsResolveWithoutChangingSavedGeometry() throws {
    var part = mesh("rotor", geometry: .cylinder(radius: 0.2, height: 2))
    part.bindings["spatial3D.transform.position.z"] = .number(3)
    let document = try SceneDocument(
      nodes: [part],
      animations: [
        .init(id: "spin", targetID: part.id, speed: 90, axis3D: .z)
      ]
    ).validated()
    let resolved = try #require(document.resolvedNodes(at: 1).first?.spatial3D?.transform)
    #expect(resolved.position.z == 3 && resolved.rotationDegrees.z == 90)
    #expect(document.nodes.first?.spatial3D?.transform.rotationDegrees.z == 0)
    var invalid = part
    invalid.bindings["spatial3D.transform.scale.x"] = .number(-1)
    #expect(throws: CoreError.self) { try SceneDocument(nodes: [invalid]).validated() }
    let wrongAxis = SceneDocument(
      nodes: [.init(id: "flat", kind: .rectangle)],
      animations: [
        .init(id: "bad", targetID: "flat", axis3D: .x)
      ])
    #expect(throws: CoreError.self) { try wrongAxis.validated() }
  }

  @Test func spatialPatchIsAtomicOmittedFieldsSurviveAndStaleRevisionRejects() throws {
    let part = mesh("part")
    let document = try SceneDocument(nodes: [part]).validated()
    let style = try document.applying(
      .init(
        baseDocumentRevision: 0,
        operations: [
          .patch(id: part.id, fields: .init(color: "#FFFFFF"))
        ]))
    #expect(style.nodes.first?.spatial3D == part.spatial3D)
    let replacement = SceneSpatial3D(geometry: .torus(ringRadius: 1, pipeRadius: 0.1))
    let changed = try style.applying(
      .init(
        baseDocumentRevision: 1,
        operations: [
          .patch(id: part.id, fields: .init(spatial3D: replacement))
        ]))
    #expect(changed.nodes.first?.spatial3D == replacement)
    #expect(throws: CoreError.self) {
      try changed.applying(.init(baseDocumentRevision: 1, operations: [.remove(id: part.id)]))
    }
    let invalid = SceneSpatial3D(transform: .init(scale: .zero), geometry: replacement.geometry)
    #expect(throws: CoreError.self) {
      try changed.applying(
        .init(
          baseDocumentRevision: 2,
          operations: [
            .patch(id: part.id, fields: .init(spatial3D: invalid))
          ]))
    }
    #expect(document.nodes == [part] && document.revision == 0)
  }

  @Test func removingAGroupRequiresRemovingItsDependentLabelInTheSameTransaction() throws {
    let group = SceneNode(id: "assembly", kind: .group, spatial3D: .init())
    var part = mesh("part")
    part.parentID = group.id
    let label = SceneNode(
      id: "label", kind: .text, text: "Part",
      spatial3D: .init(labelAnchor: .init(targetID: part.id)))
    let document = try SceneDocument(nodes: [part, label, group]).validated()
    #expect(throws: CoreError.self) {
      try document.applying(.init(baseDocumentRevision: 0, operations: [.remove(id: group.id)]))
    }
    let cleared = try document.applying(
      .init(
        baseDocumentRevision: 0,
        operations: [
          .remove(id: label.id), .remove(id: group.id),
        ]))
    #expect(cleared.nodes.isEmpty)
    #expect(document.nodes.count == 3)
  }

  @Test func aPatchCannotChangeRetainedNodeCoordinateDomainButRemoveCreateCan() throws {
    for kind: SceneNode.Kind in [.mesh, .group] {
      let original = SceneNode(id: "retained", kind: kind, width: 100, height: 100)
      let document = try SceneDocument(nodes: [original]).validated()
      let spatial = SceneSpatial3D(geometry: kind == .mesh ? .sphere(radius: 1) : nil)
      #expect(throws: CoreError.self) {
        try document.applying(
          .init(
            baseDocumentRevision: 0,
            operations: [
              .create(.init(id: "uncommitted", kind: .text, text: "Atomic")),
              .patch(id: original.id, fields: .init(spatial3D: spatial)),
            ]))
      }
      #expect(document.nodes == [original] && document.revision == 0)
      var replacement = original
      replacement.spatial3D = spatial
      let converted = try document.applying(
        .init(
          baseDocumentRevision: 0,
          operations: [
            .remove(id: original.id), .create(replacement),
          ]))
      #expect(converted.nodes == [replacement] && converted.revision == 1)
    }
  }

  @Test func typedFlowReservesItsWholeLocalRangeAndRejectsBoundPositionConflicts() throws {
    var part = mesh("moving")
    part.spatial3D?.transform.position.x = 900
    let bounded = try SceneDocument(
      nodes: [part],
      animations: [
        .init(id: "move", targetID: part.id, behavior: .flow, speed: 1, amplitude: 100)
      ]
    ).validated()
    let pose = try #require(bounded.spatialWorldPoses(at: .pi / 2).first)
    #expect(abs(pose.transform.applying(to: .zero).x - 1_000) < 0.000_001)

    #expect(throws: CoreError.self) {
      try SceneDocument(
        nodes: [part],
        animations: [
          .init(id: "move", targetID: part.id, behavior: .flow, speed: 1, amplitude: 101)
        ]
      ).validated()
    }
    part.spatial3D?.transform.position.x = 0
    for animations in [
      [
        SceneAnimation(
          id: "too-far", targetID: part.id, behavior: .flow, speed: 1, amplitude: 2_000)
      ],
      [
        SceneAnimation(id: "a", targetID: part.id, behavior: .flow, speed: 1, amplitude: 600),
        .init(id: "b", targetID: part.id, behavior: .flow, speed: 2, amplitude: -600),
      ],
    ] {
      #expect(throws: CoreError.self) {
        try SceneDocument(nodes: [part], animations: animations).validated()
      }
    }
    part.bindings["spatial3D.transform.position.x"] = .number(0)
    #expect(throws: CoreError.self) {
      try SceneDocument(
        nodes: [part],
        animations: [
          .init(id: "bound", targetID: part.id, behavior: .flow, speed: 1, amplitude: 1)
        ]
      ).validated()
    }
    let legacy = try SceneDocument(
      nodes: [.init(id: "flat", kind: .rectangle)],
      animations: [
        .init(id: "legacy", targetID: "flat", behavior: .flow, speed: 1, amplitude: 2_000)
      ]
    ).validated()
    #expect(abs(try #require(legacy.resolvedNodes(at: .pi / 2).first).x - 2_000) < 0.000_001)
  }

  @Test func animatedScaleCannotMovePrimitiveCornersOutsideWorldBounds() throws {
    let group = SceneNode(
      id: "assembly", kind: .group,
      spatial3D: .init(transform: .init(scale: .init(x: 10, y: 1, z: 1))))
    var body = mesh("body", geometry: .box(width: 1_000, height: 1, depth: 1))
    body.parentID = group.id
    body.bindings["spatial3D.transform.scale.x"] = animatedScale
    let document = try SceneDocument(nodes: [body, group]).validated()
    #expect(try document.spatialWorldPoses(at: 0).count == 2)
    // Local scale 100 and world basis 1000 are individually valid, but the
    // primitive's world-space half-extent becomes 500000 rather than 5000.
    #expect(throws: CoreError.invalidTransform) {
      try document.spatialWorldPoses(at: .pi / 2)
    }
    #expect(document.nodes.first?.spatial3D?.transform.scale == .one)
  }

  @Test func animatedScaleCannotMoveALabelAnchorOutsideWorldBounds() throws {
    let group = SceneNode(
      id: "assembly", kind: .group,
      spatial3D: .init(transform: .init(scale: .init(x: 10, y: 1, z: 1))))
    var body = mesh("body")
    body.parentID = group.id
    body.bindings["spatial3D.transform.scale.x"] = animatedScale
    let label = SceneNode(
      id: "label", kind: .text, text: "Part",
      spatial3D: .init(labelAnchor: .init(targetID: body.id, point: .init(x: 1_000, y: 0, z: 0))))
    let document = try SceneDocument(nodes: [body, group, label]).validated()
    #expect(try document.spatialWorldPoses(at: 0).count == 2)
    // The body stays inside the bound; only its target-local label anchor
    // grows from 10000 to 1000000 after the same valid composed scaling.
    #expect(throws: CoreError.invalidTransform) {
      try document.spatialWorldPoses(at: .pi / 2)
    }
  }

  private var animatedScale: SafeExpression {
    .operation(
      .add,
      [
        .number(1),
        .operation(.mul, [.number(99), .operation(.sin, [.reference("time")])]),
      ])
  }

  private func mesh(_ id: String, geometry: Geometry3D = .box(width: 1, height: 1, depth: 1))
    -> SceneNode
  {
    .init(id: id, kind: .mesh, spatial3D: .init(geometry: geometry))
  }
}
