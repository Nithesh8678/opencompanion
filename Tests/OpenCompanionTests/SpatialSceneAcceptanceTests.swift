import CompanionCore
import Foundation
import Testing

@testable import OpenCompanion

struct SpatialSceneAcceptanceTests {
  @Test func onlyNewPhysicalPartsEstablishProgressiveAssembly() async throws {
    let collector = SpatialSceneAcceptanceCollector(started: ProcessInfo.processInfo.systemUptime)
    try await collector.receive(
      unit(
        #"{"type":"scene","nodes":[{"id":"body","kind":"mesh","spatial3D":{"geometry":{"type":"box","width":2,"height":1,"depth":1}}},{"id":"shaft","kind":"mesh","spatial3D":{"geometry":{"type":"cylinder","radius":0.1,"height":3}}}]}"#
      ))
    #expect(await collector.snapshot().progressiveGeometryUnits == 1)
    try await collector.receive(
      unit(
        #"{"type":"scene","operations":[{"op":"node.remove","id":"shaft"}]}"#))
    try await collector.receive(
      unit(
        #"{"type":"scene","nodes":[{"id":"shaft","kind":"mesh","spatial3D":{"geometry":{"type":"cylinder","radius":0.1,"height":3}}}]}"#
      ))
    try await collector.receive(
      unit(
        #"{"type":"scene","operations":[{"op":"node.patch","id":"body","fields":{"spatial3D":{"geometry":{"type":"box","width":2,"height":1,"depth":1},"transform":{"position":{"x":1,"y":0,"z":0}}}}}]}"#
      ))
    try await collector.receive(
      unit(
        #"{"type":"scene","nodes":[{"id":"body-label","kind":"text","text":"Housing","spatial3D":{"labelAnchor":{"targetID":"body","point":{"x":0,"y":0,"z":0}}}}]}"#
      ))
    #expect(await collector.snapshot().progressiveGeometryUnits == 1)
    try await collector.receive(
      unit(
        #"{"type":"scene","nodes":[{"id":"magnet","kind":"mesh","spatial3D":{"geometry":{"type":"box","width":1,"height":0.2,"depth":0.5}}}]}"#
      ))
    let snapshot = await collector.snapshot()
    #expect(snapshot.progressiveGeometryUnits == 2 && snapshot.sceneUnits == 6)
    #expect(snapshot.firstSceneMS != nil && snapshot.firstTypedMS != nil)
  }

  private func unit(_ json: String) throws -> ProviderUnit {
    try JSONDecoder().decode(ProviderUnit.self, from: Data(json.utf8))
  }

  @Test func waterConnectionsUseWorldEndpointsAndAnchoredSemanticLabels() throws {
    #expect(checks("water-molecule", try water()) == [])
    #expect(
      checks(
        "water-molecule",
        try water(
          group: .init(
            position: .init(x: 3, y: -2, z: 1),
            rotationDegrees: .init(x: 25, y: 60, z: 17), scale: .init(x: 1.6, y: 0.8, z: 1.1))))
        == [])
  }

  @Test func reproducedPublicWaterRotationSignErrorFailsConnectivity() throws {
    // Public minimal data reproduces the emitted layout; no captured/media assets are embedded.
    var document = try water()
    for index in document.nodes.indices {
      if document.nodes[index].id == "connection-a" {
        document.nodes[index].spatial3D?.transform = .init(
          position: .init(x: -0.76, y: 0.67, z: 0),
          rotationDegrees: .init(x: 0, y: 0, z: -48))
        document.nodes[index].spatial3D?.geometry = .cylinder(radius: 0.1, height: 1.75)
      } else if document.nodes[index].id == "connection-b" {
        document.nodes[index].spatial3D?.transform = .init(
          position: .init(x: 0.76, y: 0.67, z: 0),
          rotationDegrees: .init(x: 0, y: 0, z: 48))
        document.nodes[index].spatial3D?.geometry = .cylinder(radius: 0.1, height: 1.75)
      }
    }
    #expect(checks("water-molecule", document).contains("water-bonds-connect-atoms"))
  }

  @Test func waterRejectsShortDisconnectedBondsAndDuplicateBondAssignments() throws {
    var short = try water()
    for index in short.nodes.indices where short.nodes[index].id.hasPrefix("connection-") {
      short.nodes[index].spatial3D?.geometry = .cylinder(radius: 0.1, height: 0.05)
    }
    #expect(checks("water-molecule", short).contains("water-bonds-connect-atoms"))
    var duplicated = try water()
    let first = try #require(duplicated.nodes.first { $0.id == "connection-a" }?.spatial3D)
    let second = try #require(duplicated.nodes.firstIndex { $0.id == "connection-b" })
    duplicated.nodes[second].spatial3D = first
    #expect(checks("water-molecule", duplicated).contains("water-bonds-connect-atoms"))
    var excessive = try water()
    for index in excessive.nodes.indices where excessive.nodes[index].id.hasPrefix("connection-") {
      excessive.nodes[index].spatial3D?.geometry = .cylinder(radius: 0.1, height: 1_000)
    }
    #expect(checks("water-molecule", excessive).contains("water-bonds-connect-atoms"))
  }

  @Test func motorAcceptsCommonAxisAndWorldRotatedCameraFacingCutaway() throws {
    #expect(checks("brushed-dc-motor", try motor()) == [])
    #expect(
      checks(
        "brushed-dc-motor",
        try motor(group: .init(rotationDegrees: .init(x: 90, y: 0, z: 0)), start: 30)) == [])
  }

  @Test func reproducedPublicMotorAxisAndBackFacingCutawayErrorsFail() throws {
    var document = try motor(start: 35, sweep: 290)
    for index in document.nodes.indices
    where ["part-b", "part-c", "part-d"].contains(
      document.nodes[index].id)
    {
      document.nodes[index].spatial3D?.transform.rotationDegrees = .init(x: 90, y: 0, z: 0)
      if document.nodes[index].id == "part-d" {
        document.nodes[index].spatial3D?.transform.position = .init(x: 0, y: 0, z: -0.94)
      }
    }
    let failures = checks("brushed-dc-motor", document)
    #expect(failures.contains("motor-coaxial-axes"))
    #expect(failures.contains("motor-camera-facing-cutaway"))
  }

  @Test func motorRejectsClosedOrRearCutawayAndRemoteParallelParts() throws {
    #expect(
      checks("brushed-dc-motor", try motor(sweep: 360)).contains("motor-camera-facing-cutaway"))
    #expect(
      checks("brushed-dc-motor", try motor(start: 200)).contains("motor-camera-facing-cutaway"))
    var remote = try motor()
    let shaft = try #require(remote.nodes.firstIndex { $0.id == "part-c" })
    remote.nodes[shaft].spatial3D?.transform.position.y = 1_000
    #expect(checks("brushed-dc-motor", remote).contains("motor-assembled-axial-extents"))
  }

  @Test func pendulumAcceptsConnectedSolidPartsUnderComposedParentTransforms() throws {
    #expect(checks("simple-pendulum", try pendulum()) == [])
    #expect(
      checks(
        "simple-pendulum",
        try pendulum(
          group: .init(
            position: .init(x: 3, y: -2, z: 1),
            rotationDegrees: .init(x: 25, y: 60, z: 17),
            scale: .init(x: 1.6, y: 0.8, z: 1.1)))) == [])
  }

  @Test func pendulumRejectsDisconnectedAndOverlongRodEvenWhenItCrossesBothParts() throws {
    var short = try pendulum()
    let rod = try #require(short.nodes.firstIndex { $0.id == "piece-b" })
    short.nodes[rod].spatial3D?.geometry = .cylinder(radius: 0.05, height: 0.4)
    #expect(checks("simple-pendulum", short).contains("pendulum-rod-connects-parts"))
    var excessive = try pendulum()
    excessive.nodes[rod].spatial3D?.geometry = .cylinder(radius: 0.05, height: 6)
    #expect(checks("simple-pendulum", excessive).contains("pendulum-rod-connects-parts"))
  }

  @Test func pendulumRejectsAnimationEvenWhenItsRestPoseIsConnected() throws {
    var animated = try pendulum()
    #expect(checks("simple-pendulum", animated).isEmpty)
    animated.animations = [
      .init(id: "public-spin", targetID: "piece-b", behavior: .rotate, speed: 45, axis3D: .z)
    ]
    animated = try animated.validated()
    #expect(checks("simple-pendulum", animated) == ["pendulum-static"])
  }

  @Test func pendulumRejectsHollowBobWrongSemanticRolesAndInvisibleParts() throws {
    var hollow = try pendulum()
    let bob = try #require(hollow.nodes.firstIndex { $0.id == "piece-c" })
    hollow.nodes[bob].spatial3D?.geometry = .tube(innerRadius: 0.2, outerRadius: 0.45, height: 0.9)
    #expect(checks("simple-pendulum", hollow).contains("pendulum-part-roles"))
    var mislabeled = try pendulum()
    let supportLabel = try #require(mislabeled.nodes.firstIndex { $0.id == "label-piece-a" })
    let bobLabel = try #require(mislabeled.nodes.firstIndex { $0.id == "label-piece-c" })
    mislabeled.nodes[supportLabel].text = "Round Bob"
    mislabeled.nodes[bobLabel].text = "Fixed Support"
    #expect(checks("simple-pendulum", mislabeled).contains("pendulum-part-roles"))
    var hidden = try pendulum()
    hidden.nodes[bob].opacity = 0
    #expect(checks("simple-pendulum", hidden).contains("pendulum-part-roles"))
    var transparent = try pendulum()
    transparent.nodes[bob].fill = "#4488CC00"
    #expect(checks("simple-pendulum", transparent).contains("pendulum-visible-parts"))
  }

  private func checks(_ id: String, _ document: SceneDocument) -> [String] {
    SpatialSceneContentOracle.unmetChecks(caseID: id, document: document)
  }

  private func water(group: Transform3D = .identity) throws -> SceneDocument {
    let length = hypot(1.3, 1.16)
    let angle = atan2(1.3, 1.16) * 180 / Double.pi
    return try SceneDocument(nodes: [
      .init(id: "root", kind: .group, spatial3D: .init(transform: group)),
      mesh("atom-a", .sphere(radius: 0.7)),
      mesh("atom-b", .sphere(radius: 0.38), position: .init(x: -1.3, y: 1.16, z: 0)),
      mesh("atom-c", .sphere(radius: 0.38), position: .init(x: 1.3, y: 1.16, z: 0)),
      mesh(
        "connection-a", .cylinder(radius: 0.1, height: length),
        position: .init(x: -0.65, y: 0.58, z: 0), rotation: .init(x: 0, y: 0, z: angle)),
      mesh(
        "connection-b", .cylinder(radius: 0.1, height: length),
        position: .init(x: 0.65, y: 0.58, z: 0), rotation: .init(x: 0, y: 0, z: -angle)),
      label("Oxygen", target: "atom-a"), label("Hydrogen A", target: "atom-b"),
      label("Hydrogen B", target: "atom-c"),
    ]).validated()
  }

  private func motor(
    group: Transform3D = .identity, start: Double = 120, sweep: Double = 240
  ) throws -> SceneDocument {
    try SceneDocument(nodes: [
      .init(id: "root", kind: .group, spatial3D: .init(transform: group)),
      mesh(
        "part-a",
        .tube(
          innerRadius: 1.32, outerRadius: 1.48, height: 2.8,
          startAngleDegrees: start, sweepAngleDegrees: sweep)),
      mesh("part-b", .cylinder(radius: 0.38, height: 1.45)),
      mesh("part-c", .cylinder(radius: 0.12, height: 4.1)),
      mesh(
        "part-d", .cylinder(radius: 0.27, height: 0.42),
        position: .init(x: 0, y: -0.94, z: 0)),
      label("Curved housing", target: "part-a"), label("Rotor", target: "part-b"),
      label("Output shaft", target: "part-c"), label("Commutator", target: "part-d"),
    ]).validated()
  }

  private func pendulum(group: Transform3D = .identity) throws -> SceneDocument {
    try SceneDocument(nodes: [
      .init(id: "root", kind: .group, spatial3D: .init(transform: group)),
      mesh(
        "piece-a", .box(width: 2, height: 0.4, depth: 0.6, chamferRadius: 0.03),
        position: .init(x: 0, y: 1.7, z: 0)),
      mesh(
        "piece-b", .cylinder(radius: 0.05, height: 2.8),
        position: .init(x: 0, y: 0.3, z: 0)),
      mesh("piece-c", .sphere(radius: 0.45), position: .init(x: 0, y: -1, z: 0)),
      label("Fixed Support", target: "piece-a"), label("Solid Rod", target: "piece-b"),
      label("Round Bob", target: "piece-c"),
    ]).validated()
  }

  private func mesh(
    _ id: String, _ geometry: Geometry3D, position: Vector3D = .zero,
    rotation: Vector3D = .zero
  ) -> SceneNode {
    .init(
      id: id, kind: .mesh, parentID: "root",
      spatial3D: .init(
        transform: .init(position: position, rotationDegrees: rotation),
        geometry: geometry))
  }

  private func label(_ text: String, target: String) -> SceneNode {
    .init(
      id: "label-" + target, kind: .text, text: text,
      spatial3D: .init(labelAnchor: .init(targetID: target)))
  }
}
