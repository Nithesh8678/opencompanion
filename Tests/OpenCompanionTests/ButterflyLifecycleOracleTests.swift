import CompanionCore
import Testing

@testable import OpenCompanion

struct ButterflyLifecycleOracleTests {
  @Test func recognisableAssembliesPassWithoutDependingOnNamesOrWorldOrientation() throws {
    for grouped in [true, false] {
      for transform in [
        Transform3D.identity,
        .init(
          position: .init(x: 3, y: -2, z: 1),
          rotationDegrees: .init(x: 28, y: 61, z: -17),
          scale: .init(x: 1.2, y: 0.9, z: 1.1)),
      ] {
        #expect(
          ButterflyLifecycleOracle.unmetChecks(
            document: try lesson(grouped: grouped, transform: transform)
          ).isEmpty)
      }
    }
  }

  @Test func fourSemanticLabelsDoNotTurnFourSpheresIntoALifecycle() throws {
    var document = try lesson()
    document.nodes.removeAll { $0.kind == .mesh }
    for (index, target) in ["piece-a", "piece-b", "piece-c", "piece-d"].enumerated() {
      document.nodes.append(mesh(target, .sphere(radius: 0.3), parent: "stage-\(index)"))
    }
    document = try document.validated()
    let unmet = ButterflyLifecycleOracle.unmetChecks(document: document)
    #expect(unmet.contains("butterfly-segmented-larva"))
    #expect(unmet.contains("butterfly-pupa-form"))
    #expect(unmet.contains("butterfly-adult-head-and-body"))
    #expect(unmet.contains("butterfly-adult-wing-silhouette"))
  }

  @Test func smoothCapsuleLarvaAndTwoOvalWingsReproduceThePublicBaselineFailures() throws {
    // Authored minimal geometry reproduces the structural failure, not model
    // text, screenshots or a private artifact. Four stages and two wing pairs
    // are independently sourced in ButterflyLifecycleOracle's header.
    var document = try lesson()
    document.nodes.removeAll { node in
      node.parentID == "stage-1" || node.parentID == "stage-3"
    }
    document.nodes += [
      mesh(
        "piece-b", .capsule(radius: 0.24, height: 1.25), parent: "stage-1",
        rotation: .init(x: 0, y: 0, z: 90)),
      mesh("piece-d", .capsule(radius: 0.1, height: 0.8), parent: "stage-3"),
      mesh(
        "oval-a", .sphere(radius: 0.5), parent: "stage-3",
        position: .init(x: -0.36, y: 0.1, z: 0), scale: .init(x: 0.7, y: 1, z: 0.12)),
      mesh(
        "oval-b", .sphere(radius: 0.5), parent: "stage-3",
        position: .init(x: 0.36, y: 0.1, z: 0), scale: .init(x: 0.7, y: 1, z: 0.12)),
    ]
    let unmet = ButterflyLifecycleOracle.unmetChecks(document: try document.validated())
    #expect(unmet.contains("butterfly-segmented-larva"))
    #expect(unmet.contains("butterfly-adult-head-and-body"))
    #expect(unmet.contains("butterfly-adult-wing-silhouette"))
  }

  @Test func meshCountPaddingAndWingLabelsCannotReplaceHeadOrWingLobes() throws {
    var document = try lesson()
    document.nodes.removeAll { ["detail-head", "wing-c", "wing-d"].contains($0.id) }
    for index in 0..<6 {
      document.nodes.append(
        mesh(
          "padding-\(index)", .box(width: 0.05, height: 0.05, depth: 0.05),
          parent: "stage-3"))
    }
    let unmet = ButterflyLifecycleOracle.unmetChecks(document: try document.validated())
    #expect(unmet.contains("butterfly-adult-head-and-body"))
    #expect(unmet.contains("butterfly-adult-wing-silhouette"))
  }

  @Test func twoCompoundLobedWingOutlinesCanRepresentTheTwoWingPairs() throws {
    let left: [Point2D] = [
      .init(x: 0, y: 0), .init(x: -0.15, y: 0.55),
      .init(x: -0.6, y: 0.7), .init(x: -0.85, y: 0.4),
      .init(x: -0.5, y: 0.05), .init(x: -0.7, y: -0.22),
      .init(x: -0.5, y: -0.45), .init(x: -0.18, y: -0.35),
    ]
    for rounding in [0.0, 0.12] {
      var document = try lesson()
      document.nodes.removeAll { $0.id.hasPrefix("wing-") }
      document.nodes += [
        mesh(
          "compound-a", .extrusion(profile: left, depth: 0.08, cornerRounding: rounding),
          parent: "stage-3"),
        mesh(
          "compound-b",
          .extrusion(
            profile: left.map { .init(x: -$0.x, y: $0.y) }, depth: 0.08,
            cornerRounding: rounding), parent: "stage-3"),
      ]
      #expect(ButterflyLifecycleOracle.unmetChecks(document: try document.validated()).isEmpty)
    }
  }

  @Test func smallBeadsCannotPadASmoothLarvasBodySegmentCount() throws {
    var document = try lesson()
    document.nodes.removeAll { $0.parentID == "stage-1" }
    document.nodes.append(
      mesh(
        "piece-b", .capsule(radius: 0.22, height: 1.25), parent: "stage-1",
        rotation: .init(x: 0, y: 0, z: 90)))
    for index in 0..<6 {
      document.nodes.append(
        mesh(
          "bead-\(index)", .sphere(radius: 0.025), parent: "stage-1",
          position: .init(x: Double(index) * 0.1 - 0.3, y: 0, z: 0.23)))
    }
    #expect(
      ButterflyLifecycleOracle.unmetChecks(document: try document.validated())
        .contains("butterfly-segmented-larva"))
  }

  @Test func stagesMustBeDistinctAndProgressionMustBeVisible() throws {
    var overlapping = try lesson()
    for index in overlapping.nodes.indices where overlapping.nodes[index].kind == .group {
      overlapping.nodes[index].spatial3D?.transform.position = .zero
    }
    let overlap = ButterflyLifecycleOracle.unmetChecks(document: try overlapping.validated())
    #expect(overlap.contains("butterfly-distinct-stage-assemblies"))
    var unordered = try lesson()
    for index in unordered.nodes.indices where unordered.nodes[index].kind == .text {
      unordered.nodes[index].text = String(unordered.nodes[index].text.dropFirst(3))
    }
    #expect(
      ButterflyLifecycleOracle.unmetChecks(document: try unordered.validated())
        .contains("butterfly-visible-progression"))
  }

  @Test func hiddenAnatomyAndMisassignedStageLabelsCannotSatisfyRoles() throws {
    var hidden = try lesson()
    let head = try #require(hidden.nodes.firstIndex { $0.id == "detail-head" })
    hidden.nodes[head].fill = "#22558800"
    #expect(
      ButterflyLifecycleOracle.unmetChecks(document: hidden)
        .contains("butterfly-adult-head-and-body"))
    var mislabeled = try lesson()
    let label = try #require(mislabeled.nodes.firstIndex { $0.id == "label-1" })
    mislabeled.nodes[label].spatial3D?.labelAnchor?.targetID = "piece-a"
    #expect(
      ButterflyLifecycleOracle.unmetChecks(document: mislabeled)
        == ["butterfly-four-stage-roles"])
  }

  @Test func duplicateNumberedLabelsOnTheEggCannotSupplyOtherStagesProgression() throws {
    var document = try lesson()
    for index in document.nodes.indices where document.nodes[index].kind == .text {
      document.nodes[index].text = String(document.nodes[index].text.dropFirst(3))
    }
    for (index, text) in ["1. Egg", "2. Caterpillar", "3. Chrysalis", "4. Adult"].enumerated() {
      document.nodes.append(
        .init(
          id: "z-duplicate-\(index)", kind: .text, text: text,
          spatial3D: .init(labelAnchor: .init(targetID: "piece-a"))))
    }
    #expect(
      ButterflyLifecycleOracle.unmetChecks(document: try document.validated())
        .contains("butterfly-visible-progression"))
  }

  @Test func pupaNeedsSubstantialGeometricTaperRatherThanAnExtraSphere() throws {
    var document = try lesson()
    let index = try #require(document.nodes.firstIndex { $0.id == "piece-c" })
    document.nodes[index].spatial3D?.geometry = .capsule(radius: 0.25, height: 1.1)
    document.nodes.append(
      mesh(
        "tiny-detail", .sphere(radius: 0.02), parent: "stage-2",
        position: .init(x: 0, y: 0.55, z: 0)))
    #expect(
      ButterflyLifecycleOracle.unmetChecks(document: try document.validated())
        .contains("butterfly-pupa-form"))
    document.nodes[index].spatial3D?.geometry = .cone(
      topRadius: 0.04, bottomRadius: 0.28, height: 1.1)
    #expect(
      !ButterflyLifecycleOracle.unmetChecks(document: try document.validated())
        .contains("butterfly-pupa-form"))
  }

  @Test func descriptiveStageLabelsFollowTheFirstExplicitRoleWord() throws {
    var document = try lesson()
    let egg = try #require(document.nodes.firstIndex { $0.id == "label-0" })
    let adult = try #require(document.nodes.firstIndex { $0.id == "label-3" })
    document.nodes[egg].text = "1. Egg laid by an adult"
    document.nodes[adult].text = "4. Adult butterfly lays eggs"
    #expect(ButterflyLifecycleOracle.unmetChecks(document: try document.validated()).isEmpty)
  }

  private func lesson(grouped: Bool = true, transform: Transform3D = .identity) throws
    -> SceneDocument
  {
    let positions: [Vector3D] = [
      .init(x: -1.6, y: 1.25, z: 0), .init(x: 1.6, y: 1.25, z: 0),
      .init(x: 1.6, y: -1.25, z: 0), .init(x: -1.6, y: -1.25, z: 0),
    ]
    var nodes: [SceneNode] = [
      .init(id: "world", kind: .group, spatial3D: .init(transform: transform))
    ]
    for index in positions.indices {
      nodes.append(
        .init(
          id: "stage-\(index)", kind: .group, parentID: "world",
          spatial3D: .init(transform: .init(position: positions[index]))))
    }
    nodes += [
      mesh(
        "piece-a", .sphere(radius: 0.24), parent: "stage-0",
        scale: .init(x: 0.85, y: 1.15, z: 0.85))
    ]
    for (index, x) in [-0.54, -0.18, 0.18, 0.54].enumerated() {
      nodes.append(
        mesh(
          index == 0 ? "piece-b" : "segment-\(index)", .sphere(radius: 0.22),
          parent: "stage-1", position: .init(x: x, y: 0, z: 0)))
    }
    nodes += [
      mesh(
        "piece-c",
        .lathe(profile: [
          .init(radius: 0.03, y: -0.55), .init(radius: 0.24, y: -0.3),
          .init(radius: 0.28, y: 0.15), .init(radius: 0.16, y: 0.48),
          .init(radius: 0.04, y: 0.55),
        ]), parent: "stage-2"),
      mesh("piece-d", .capsule(radius: 0.1, height: 0.9), parent: "stage-3"),
      mesh(
        "detail-head", .sphere(radius: 0.14), parent: "stage-3",
        position: .init(x: 0, y: 0.53, z: 0)),
    ]
    for (index, point) in [(-0.38, 0.18), (0.38, 0.18), (-0.31, -0.18), (0.31, -0.18)]
      .enumerated()
    {
      nodes.append(
        mesh(
          "wing-\(["a", "b", "c", "d"][index])", .sphere(radius: 0.42),
          parent: "stage-3", position: .init(x: point.0, y: point.1, z: 0),
          scale: .init(x: index < 2 ? 0.95 : 0.8, y: index < 2 ? 1 : 0.8, z: 0.12)))
    }
    for (index, item) in [
      ("1. Egg", "piece-a"), ("2. Caterpillar", "piece-b"),
      ("3. Chrysalis", "piece-c"), ("4. Adult", "piece-d"),
    ].enumerated() {
      nodes.append(
        .init(
          id: "label-\(index)", kind: .text, text: item.0,
          spatial3D: .init(labelAnchor: .init(targetID: item.1))))
    }
    if !grouped {
      for index in nodes.indices where nodes[index].kind == .mesh {
        let parent = nodes[index].parentID ?? ""
        if let stage = Int(parent.replacingOccurrences(of: "stage-", with: "")),
          positions.indices.contains(stage)
        {
          let position = nodes[index].spatial3D!.transform.position
          nodes[index].spatial3D?.transform.position = .init(
            x: position.x + positions[stage].x, y: position.y + positions[stage].y,
            z: position.z + positions[stage].z)
          nodes[index].parentID = "world"
        }
      }
      nodes.removeAll { $0.id.hasPrefix("stage-") }
    }
    return try SceneDocument(nodes: nodes).validated()
  }

  private func mesh(
    _ id: String, _ geometry: Geometry3D, parent: String,
    position: Vector3D = .zero, rotation: Vector3D = .zero, scale: Vector3D = .one
  ) -> SceneNode {
    .init(
      id: id, kind: .mesh, fill: "#638AA8", parentID: parent,
      spatial3D: .init(
        transform: .init(position: position, rotationDegrees: rotation, scale: scale),
        geometry: geometry))
  }
}
