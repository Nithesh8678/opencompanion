import CompanionCore
import Foundation
import Testing

@testable import OpenCompanion

struct ProviderSpatialConnectorTests {
  @Test func arbitraryNamesTransformedEndpointsAndSameUnitLabelCommitOneRevision() throws {
    let note = SceneNode(id: "retained-note", kind: .text, text: "Preserve this edit")
    let original = try SceneDocument(
      id: "public-construction", title: "Original", revision: 7,
      nodes: [note], notes: "Public fixture notes", citations: ["public fixture"]
    ).validated()
    let before = original
    let connector = recipe(parentID: "frame-a")
    var nodes = bodies()
    nodes.insert(
      .init(
        id: "edge-label", kind: .text, text: "Connection",
        spatial3D: .init(labelAnchor: .init(targetID: connector.id))), at: 0)
    let input = ProviderUnit(
      type: "scene", title: "Connected parts", nodes: nodes, connectors: [connector])
    let result = try ProviderSceneBoundary.applying(input, to: original, baseRevision: 7)
    #expect(result.revision == 8 && result.id == original.id)
    #expect(result.notes == original.notes && result.citations == original.citations)
    #expect(result.nodes.first == note && original == before)
    #expect(
      result.nodes.first { $0.id == "edge-label" }?.spatial3D?.labelAnchor?.targetID == connector.id
    )
    try assertEndpoints(connector, in: result)
    let generated = try #require(result.nodes.first { $0.id == connector.id })
    #expect(generated.kind == .mesh && generated.parentID == "frame-a")
    let encoded = try JSONEncoder().encode(result)
    #expect(!String(decoding: encoded, as: UTF8.self).contains("\"connectors\""))
    #expect(try JSONDecoder().decode(SceneDocument.self, from: encoded) == result)
  }

  @Test func connectorUsesPostOperationAndReplacementNodePositions() throws {
    let original = try SceneDocument(id: "public-post-proposal", nodes: bodies()).validated()
    let before = original
    let index = try #require(original.nodes.firstIndex { $0.id == "vertex-a" })
    var relocated = original.nodes[index]
    relocated.spatial3D?.transform.position = .init(x: -1.8, y: 0.9, z: 0.6)
    let patch = ScenePatch(spatial3D: relocated.spatial3D)
    let second = try #require(original.nodes.first { $0.id == "vertex-b" })
    var replaced = second
    replaced.spatial3D?.transform.position = .init(x: 1.7, y: -1.1, z: -0.4)
    let connector = recipe()
    let input = ProviderUnit(
      type: "scene", nodes: [replaced],
      operations: [.patch(id: "vertex-a", fields: patch)], connectors: [connector])
    let result = try ProviderSceneBoundary.applying(input, to: original, baseRevision: 0)
    try assertEndpoints(connector, in: result)
    #expect(result.revision == 1 && original == before)
    #expect(result.nodes.first { $0.id == "vertex-a" }?.spatial3D == relocated.spatial3D)
    #expect(result.nodes.first { $0.id == "vertex-b" }?.spatial3D == replaced.spatial3D)
  }

  @Test func missingRemovedAndCollidingReferencesRejectWithoutPartialMutation() throws {
    let original = try SceneDocument(id: "public-atomic", nodes: bodies()).validated()
    let before = original
    let missing = SpatialConnector(
      id: "edge-z", from: .init(targetID: "missing"), to: .init(targetID: "vertex-b"),
      radius: 0.04, fill: "#8899AA")
    let colliding = SpatialConnector(
      id: "vertex-a", from: .init(targetID: "vertex-a"), to: .init(targetID: "vertex-b"),
      radius: 0.04, fill: "#8899AA")
    let proposals = [
      ProviderUnit(type: "scene", connectors: [missing]),
      ProviderUnit(type: "scene", removeIDs: ["vertex-a"], connectors: [recipe()]),
      ProviderUnit(type: "scene", connectors: [colliding]),
      ProviderUnit(
        type: "scene", nodes: [.init(id: "edge-z", kind: .text, text: "Conflict")],
        connectors: [recipe()]),
    ]
    for proposal in proposals {
      #expect(throws: (any Error).self) {
        try ProviderSceneBoundary.applying(proposal, to: original, baseRevision: 0)
      }
      #expect(original == before)
    }
  }

  @Test func explicitRemovalAllowsRecreationButOrdinaryCollisionDoesNot() throws {
    let base = try SceneDocument(id: "public-recreation", nodes: bodies()).validated()
    let first = try ProviderSceneBoundary.applying(
      .init(type: "scene", connectors: [recipe()]), to: base, baseRevision: 0)
    let replacement = recipe(radius: 0.08)
    let recreated = try ProviderSceneBoundary.applying(
      .init(type: "scene", removeIDs: [replacement.id], connectors: [replacement]),
      to: first, baseRevision: 1)
    #expect(recreated.revision == 2 && first.revision == 1)
    #expect(recreated.nodes.filter { $0.id == replacement.id }.count == 1)
    let node = try #require(recreated.nodes.first { $0.id == replacement.id })
    guard case .cylinder(let radius, _, _)? = node.spatial3D?.geometry else {
      Issue.record("Recreated connector was not a native cylinder")
      return
    }
    #expect(radius == 0.08)
    try assertEndpoints(replacement, in: recreated)
    #expect(throws: (any Error).self) {
      try ProviderSceneBoundary.applying(
        .init(type: "scene", connectors: [replacement]), to: first, baseRevision: 1)
    }
  }

  @Test func originalAndEverySameUnitAnimationSourceCannotBypassStaticAncestry() throws {
    for source in 0..<4 {
      var original = SceneDocument(id: "public-static-\(source)", nodes: bodies())
      let animation = SceneAnimation(
        id: "motion", targetID: source == 3 ? "edge-z" : "frame-a", speed: 45, axis3D: .y)
      var input = ProviderUnit(type: "scene", connectors: [recipe()])
      switch source {
      case 0: original.animations = [animation]
      case 1: input.operations = [.defineAnimation(animation)]
      default: input.animations = [animation]
      }
      original = try original.validated()
      let before = original
      #expect(throws: (any Error).self) {
        try ProviderSceneBoundary.applying(input, to: original, baseRevision: 0)
      }
      #expect(original == before)
    }
  }

  @Test func generatedGeometryAndOperationsCannotExceedTheFinalTransactionBudgets() throws {
    let original = try SceneDocument(id: "public-budget", nodes: bodies()).validated()
    let before = original
    let input = ProviderUnit(type: "scene", connectors: [recipe()])
    var geometryLimits = SceneLimits()
    let existingCost = try original.nodes.compactMap { $0.spatial3D?.geometry }.reduce(0) {
      try $0 + $1.validatedBudget().triangles
    }
    geometryLimits.maximumSpatialTriangles = existingCost
    #expect(throws: (any Error).self) {
      try ProviderSceneBoundary.applying(
        input, to: original, baseRevision: 0, limits: geometryLimits)
    }
    var operationLimits = SceneLimits()
    operationLimits.maximumOperations = 1
    let extraNode = SceneNode(id: "new-note", kind: .text, text: "Pending note")
    #expect(throws: (any Error).self) {
      try ProviderSceneBoundary.applying(
        .init(type: "scene", nodes: [extraNode], connectors: [recipe()]),
        to: original, baseRevision: 0, limits: operationLimits)
    }
    #expect(original == before)
  }

  @Test func unrelatedProposedBindingsStillUseFullFinalTransactionAdmission() throws {
    let original = try SceneDocument(id: "public-metadata", nodes: bodies()).validated()
    let note = SceneNode(
      id: "bound-note", kind: .text, text: "Public bound note",
      bindings: ["x": .reference("new-value")])
    let valid = ProviderUnit(
      type: "scene", nodes: [note],
      operations: [.defineExpression(name: "new-value", expression: .number(7))],
      connectors: [recipe()])
    let result = try ProviderSceneBoundary.applying(valid, to: original, baseRevision: 0)
    #expect(try result.resolvedNodes(at: 0).first { $0.id == "bound-note" }?.x == 7)
    try assertEndpoints(recipe(), in: result)
    var missingExpression = valid
    missingExpression.operations = nil
    #expect(throws: (any Error).self) {
      try ProviderSceneBoundary.applying(missingExpression, to: original, baseRevision: 0)
    }
    #expect(original.revision == 0 && original.nodes.count == 4)
  }

  @Test func oldDocumentWithoutConnectorPayloadPreservesVersionAndMetadata() throws {
    let data = Data(
      #"{"specVersion":"opencompanion.scene/1","id":"old","title":"Kept","revision":4,"nodes":[{"id":"old-note","kind":"text","text":"Old content"}],"notes":"Existing notes","citations":["public fixture"]}"#
        .utf8)
    let original = try JSONDecoder().decode(SceneDocument.self, from: data).validated()
    let result = try ProviderSceneBoundary.applying(
      .init(type: "scene", nodes: [.init(id: "new-note", kind: .text, text: "Added content")]),
      to: original, baseRevision: 4)
    #expect(original.revision == 4 && original.nodes.count == 1)
    #expect(result.revision == 5 && result.nodes.first == original.nodes.first)
    #expect(result.notes == original.notes && result.citations == original.citations)
    let object = try #require(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(result)) as? [String: Any])
    #expect(object["specVersion"] as? String == SceneDocument.schemaVersion)
  }

  @Test func publicCollectorCountsOnlyCommittedConnectorUnitsAndPreservesPartialScene() async throws
  {
    let collector = SpatialSceneAcceptanceCollector(started: ProcessInfo.processInfo.systemUptime)
    let second = SpatialConnector(
      id: "edge-q", from: .init(targetID: "vertex-a"), to: .init(targetID: "vertex-b"),
      radius: 0.03, fill: "#6688AA")
    try await collector.receive(
      .init(type: "scene", nodes: bodies(), connectors: [recipe(), second]))
    let accepted = await collector.snapshot()
    #expect(accepted.connectorUnits == 1 && accepted.compiledConnectorCount == 2)
    #expect(accepted.sceneUnits == 1 && accepted.document.revision == 1)
    #expect(accepted.document.nodes.contains { $0.id == "edge-z" })
    #expect(accepted.document.nodes.contains { $0.id == "edge-q" })
    let invalid = SpatialConnector(
      id: "missing-edge", from: .init(targetID: "missing"), to: .init(targetID: "vertex-b"),
      radius: 0.04, fill: "#8899AA")
    do {
      try await collector.receive(
        .init(
          type: "scene", nodes: [.init(id: "pending-note", kind: .text, text: "Uncommitted")],
          connectors: [invalid]))
      Issue.record("Invalid later connector unit unexpectedly committed")
    } catch {}
    let failed = await collector.snapshot()
    #expect(failed.connectorUnits == accepted.connectorUnits)
    #expect(failed.compiledConnectorCount == accepted.compiledConnectorCount)
    #expect(failed.sceneUnits == accepted.sceneUnits)
    #expect(failed.document == accepted.document)
  }

  private func recipe(parentID: String? = nil, radius: Double = 0.04) -> SpatialConnector {
    .init(
      id: "edge-z", from: .init(targetID: "vertex-a", point: .init(x: 0.1, y: 0, z: 0)),
      to: .init(targetID: "vertex-b", point: .init(x: -0.1, y: 0.1, z: 0.1)),
      radius: radius, fill: "#8899AA", parentID: parentID)
  }

  private func bodies() -> [SceneNode] {
    [
      .init(
        id: "frame-a", kind: .group,
        spatial3D: .init(
          transform: .init(
            position: .init(x: 1, y: -2, z: 0.5), rotationDegrees: .init(x: 20, y: 35, z: 12),
            scale: .init(x: 1.3, y: 0.8, z: 1.1)))),
      .init(
        id: "frame-b", kind: .group, parentID: "frame-a",
        spatial3D: .init(
          transform: .init(
            position: .init(x: -0.5, y: 0.4, z: 0), rotationDegrees: .init(x: -15, y: 5, z: 42)))),
      .init(
        id: "vertex-a", kind: .mesh, parentID: "frame-b",
        spatial3D: .init(
          transform: .init(position: .init(x: -1, y: 0.5, z: 0.2)),
          geometry: .sphere(radius: 0.3))),
      .init(
        id: "vertex-b", kind: .mesh, parentID: "frame-a",
        spatial3D: .init(
          transform: .init(position: .init(x: 1.3, y: -0.7, z: -0.2)),
          geometry: .box(width: 0.4, height: 0.4, depth: 0.4))),
    ]
  }

  private func assertEndpoints(_ connector: SpatialConnector, in document: SceneDocument) throws {
    let poses = try document.spatialWorldPoses(at: 0)
    let first = try #require(poses.first { $0.node.id == connector.from.targetID })
      .transform.applying(to: connector.from.point)
    let second = try #require(poses.first { $0.node.id == connector.to.targetID })
      .transform.applying(to: connector.to.point)
    let rod = try #require(poses.first { $0.node.id == connector.id })
    guard case .cylinder(_, let height, _)? = rod.node.spatial3D?.geometry else {
      Issue.record("Connector was not compiled to cylinder geometry")
      return
    }
    let a = rod.transform.applying(to: .init(x: 0, y: -height / 2, z: 0))
    let b = rod.transform.applying(to: .init(x: 0, y: height / 2, z: 0))
    #expect(distance(a, first) < 0.000_001 && distance(b, second) < 0.000_001)
  }

  private func distance(_ a: Vector3D, _ b: Vector3D) -> Double {
    hypot(hypot(a.x - b.x, a.y - b.y), a.z - b.z)
  }
}
