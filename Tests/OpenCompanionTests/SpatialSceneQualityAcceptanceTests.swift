import CompanionCore
import Testing

@testable import OpenCompanion

struct SpatialSceneQualityAcceptanceTests {
  @Test func flaskAndImpellerAcceptCoherentGeometryUnderComposedParentTransforms() throws {
    for transform in [
      Transform3D.identity,
      .init(
        position: .init(x: 2, y: -1, z: 3), rotationDegrees: .init(x: 28, y: 47, z: -19),
        scale: .init(x: 1.3, y: 0.8, z: 1.1)),
    ] {
      #expect(checks("rounded-flask", try flask(transform)) == [])
      #expect(checks("swept-impeller", try impeller(transform)) == [])
    }
  }

  @Test func flaskRejectsSolidBodyDespiteCorrectRoleAndLathePrimitive() throws {
    var document = try flask()
    let vessel = try #require(document.nodes.firstIndex { $0.id == "piece-a" })
    document.nodes[vessel].spatial3D?.geometry = .lathe(profile: [
      .init(radius: 0.45, y: 0), .init(radius: 0.9, y: 0.4),
      .init(radius: 0.8, y: 1.2), .init(radius: 0.35, y: 1.65), .init(radius: 0.35, y: 2),
    ])
    #expect(checks("rounded-flask", document).contains("flask-open-neck-and-bulb"))
  }

  @Test func flaskRejectsRemoteRimAndWrongStopperShape() throws {
    var remote = try flask()
    let rim = try #require(remote.nodes.firstIndex { $0.id == "piece-b" })
    remote.nodes[rim].spatial3D?.transform.position.x = 5
    #expect(checks("rounded-flask", remote).contains("flask-rim-assembled"))
    var wrong = try flask()
    let stopper = try #require(wrong.nodes.firstIndex { $0.id == "piece-c" })
    wrong.nodes[stopper].spatial3D?.geometry = .cylinder(radius: 0.3, height: 0.5)
    #expect(checks("rounded-flask", wrong).contains("flask-part-roles"))
  }

  @Test func flaskRejectsThinClosedLidDespiteAHollowNearTopCrossSection() throws {
    var document = try flask()
    let vessel = try #require(document.nodes.firstIndex { $0.id == "piece-a" })
    document.nodes[vessel].spatial3D?.geometry = .lathe(profile: [
      .init(radius: 0.45, y: 0), .init(radius: 0.9, y: 0.4),
      .init(radius: 0.8, y: 1.2), .init(radius: 0.35, y: 1.65),
      .init(radius: 0.35, y: 2), .init(radius: 0, y: 2),
      .init(radius: 0, y: 1.99), .init(radius: 0.25, y: 1.99),
      .init(radius: 0.25, y: 1.65), .init(radius: 0.7, y: 1.15),
      .init(radius: 0.8, y: 0.4), .init(radius: 0.35, y: 0.12),
    ])
    _ = try document.validated()
    #expect(checks("rounded-flask", document).contains("flask-open-neck-and-bulb"))
  }

  @Test func impellerRejectsDisconnectedBladeEvenWithTheCorrectGeometryType() throws {
    var document = try impeller()
    let blade = try #require(document.nodes.firstIndex { $0.id == "piece-b" })
    document.nodes[blade].spatial3D?.transform.position.x = 3
    #expect(checks("swept-impeller", document).contains("impeller-blades-join-hub"))
  }

  @Test func impellerRejectsCoincidentBladesAndRectangularImpostors() throws {
    var coincident = try impeller()
    let blade = try #require(coincident.nodes.firstIndex { $0.id == "piece-c" })
    coincident.nodes[blade].spatial3D?.transform.rotationDegrees.z = 0
    #expect(checks("swept-impeller", coincident).contains("impeller-radial-arrangement"))
    var rectangle = try impeller()
    rectangle.nodes[blade].spatial3D?.geometry = .extrusion(
      profile: [
        .init(x: 0.3, y: -0.1), .init(x: 1.8, y: -0.1),
        .init(x: 1.8, y: 0.1), .init(x: 0.3, y: 0.1),
      ], depth: 0.12)
    #expect(checks("swept-impeller", rectangle).contains("impeller-blade-outline"))
  }

  @Test func impellerRejectsFiveVertexRectangleWithACollinearExtraPoint() throws {
    var document = try impeller()
    let blade = try #require(document.nodes.firstIndex { $0.id == "piece-c" })
    document.nodes[blade].spatial3D?.geometry = .extrusion(
      profile: [
        .init(x: 0.3, y: -0.1), .init(x: 1.05, y: -0.1), .init(x: 1.8, y: -0.1),
        .init(x: 1.8, y: 0.1), .init(x: 0.3, y: 0.1),
      ], depth: 0.12)
    _ = try document.validated()
    #expect(checks("swept-impeller", document).contains("impeller-blade-outline"))
  }

  private func checks(_ id: String, _ document: SceneDocument) -> [String] {
    SpatialSceneContentOracle.unmetChecks(caseID: id, document: document)
  }

  private func flask(_ transform: Transform3D = .identity) throws -> SceneDocument {
    try SceneDocument(nodes: [
      .init(id: "root", kind: .group, spatial3D: .init(transform: transform)),
      mesh(
        "piece-a",
        .lathe(profile: [
          .init(radius: 0.45, y: 0), .init(radius: 0.9, y: 0.4),
          .init(radius: 0.8, y: 1.2), .init(radius: 0.35, y: 1.65),
          .init(radius: 0.35, y: 2), .init(radius: 0.25, y: 2),
          .init(radius: 0.25, y: 1.65), .init(radius: 0.7, y: 1.15),
          .init(radius: 0.8, y: 0.4), .init(radius: 0.35, y: 0.12),
        ])),
      mesh(
        "piece-b", .torus(ringRadius: 0.35, pipeRadius: 0.055),
        position: .init(x: 0, y: 2, z: 0)),
      mesh(
        "piece-c", .cone(topRadius: 0.32, bottomRadius: 0.2, height: 0.5),
        position: .init(x: 1.4, y: 1.85, z: 0)),
      label("Vessel", target: "piece-a"), label("Rim", target: "piece-b"),
      label("Stopper", target: "piece-c"),
    ]).validated()
  }

  private func impeller(_ transform: Transform3D = .identity) throws -> SceneDocument {
    let profile: [Point2D] = [
      .init(x: 0.3, y: -0.08), .init(x: 0.9, y: -0.1), .init(x: 1.6, y: 0.3),
      .init(x: 1.8, y: 0.65), .init(x: 1.1, y: 0.55), .init(x: 0.55, y: 0.12),
    ]
    return try SceneDocument(nodes: [
      .init(id: "root", kind: .group, spatial3D: .init(transform: transform)),
      mesh("piece-a", .cylinder(radius: 0.4, height: 0.25), rotation: .init(x: 90, y: 0, z: 0)),
      mesh("piece-b", .extrusion(profile: profile, depth: 0.12)),
      mesh(
        "piece-c", .extrusion(profile: profile, depth: 0.12), rotation: .init(x: 0, y: 0, z: 90)),
      mesh(
        "piece-d", .extrusion(profile: profile, depth: 0.12), rotation: .init(x: 0, y: 0, z: 180)),
      mesh(
        "piece-e", .extrusion(profile: profile, depth: 0.12), rotation: .init(x: 0, y: 0, z: 270)),
      label("Hub", target: "piece-a"), label("Blade", target: "piece-b"),
    ]).validated()
  }

  private func mesh(
    _ id: String, _ geometry: Geometry3D, position: Vector3D = .zero,
    rotation: Vector3D = .zero
  ) -> SceneNode {
    .init(
      id: id, kind: .mesh, fill: "#638AA8", parentID: "root",
      spatial3D: .init(
        transform: .init(position: position, rotationDegrees: rotation), geometry: geometry))
  }

  private func label(_ text: String, target: String) -> SceneNode {
    .init(
      id: "label-" + target, kind: .text, text: text,
      spatial3D: .init(labelAnchor: .init(targetID: target)))
  }
}
