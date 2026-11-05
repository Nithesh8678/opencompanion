import CompanionCore
import Foundation
import Testing

@testable import OpenCompanion

struct ProviderConnectorGrammarTests {
  @Test func labelInsideRecipesRejectsTheWholeLaterUnitWithoutLosingAcceptedParts() async throws {
    var decoder = ProviderTextStreamDecoder()
    let admission = ConnectorGrammarAdmission()
    try await decoder.append(
      Self.partsLine + "\n", onUnit: { try await admission.receive($0) })
    let accepted = await admission.snapshot()
    #expect(accepted.revision == 1 && accepted.nodes.count == 3)

    // The label is a valid scene node, but is deliberately in the wrong array.
    // Strict recipe decoding must fail before a connector or label can commit.
    let malformed =
      ##"{"type":"scene","nodes":[],"connectors":[{"id":"link","from":{"targetID":"part-a"},"to":{"targetID":"part-b"},"radius":0.05,"fill":"#AABBCC"},{"id":"link-label","kind":"text","text":"Link","color":"#FFFFFF","width":100,"height":30,"fontSize":16,"spatial3D":{"labelAnchor":{"targetID":"link","leader":true}}}],"removeIDs":[],"narration":"The link connects the two parts.","focusID":"link"}"##
    do {
      try await decoder.append(
        malformed + "\n", onUnit: { try await admission.receive($0) })
      Issue.record("A text node inside connector recipes unexpectedly reached admission")
    } catch let error as ProviderError {
      #expect(
        error.localizedDescription
          == "Model output did not match the line protocol. Accepted earlier content was retained.")
    } catch {
      Issue.record("Unexpected mixed-array error: \(error)")
    }
    try await decoder.finish(onUnit: { try await admission.receive($0) })
    let after = await admission.snapshot()
    #expect(after == accepted)
    #expect(await admission.acceptedScenes == 1)
    #expect(decoder.acceptedUnits == 1)
    #expect(!after.nodes.contains { $0.id == "link" || $0.id == "link-label" })
  }

  @Test func sharedPromptExampleAdmitsConnectorAndSeparateLabelInOneNativeTransaction() throws {
    let parts = try JSONDecoder().decode(ProviderUnit.self, from: Data(Self.partsLine.utf8))
    let initial = try ProviderSceneBoundary.applying(
      parts, to: SceneDocument(id: "connector-grammar"), baseRevision: 0)

    let startups: [CodexSceneStartMode] = [.introductionFirst, .geometryFirst]
    for editing in [false, true] {
      for startup in startups {
        let policy = ResponsePolicy(route: .notebook, includesExistingNotebook: editing)
        let prompt = ReasoningProvider.baseInstructions(for: policy, sceneStart: startup)
        // Decode the actual complete prompt sample, rather than a copied example.
        let examples = prompt.split(separator: "\n").compactMap { line -> ProviderUnit? in
          guard line.first == "{",
            let unit = try? JSONDecoder().decode(ProviderUnit.self, from: Data(line.utf8)),
            unit.type == "scene", !(unit.connectors ?? []).isEmpty
          else { return nil }
          return unit
        }
        #expect(examples.count == 1)
        let unit = try #require(examples.first)
        let labels = try #require(unit.nodes)
        let recipes = try #require(unit.connectors)
        #expect(labels.count == 1 && labels[0].kind == .text)
        #expect(recipes.count == 1 && labels[0].id != recipes[0].id)
        #expect(labels[0].spatial3D?.labelAnchor?.targetID == recipes[0].id)

        let result = try ProviderSceneBoundary.applying(
          unit, to: initial, baseRevision: initial.revision)
        #expect(initial.revision == 1 && initial.nodes.count == 3)
        #expect(result.revision == 2 && result.nodes.count == 5)
        #expect(result.nodes.prefix(initial.nodes.count).elementsEqual(initial.nodes))
        #expect(result.nodes.first { $0.id == labels[0].id } == labels[0])
        #expect(unit.focusID == recipes[0].id)
        #expect(try SceneFocus.validate(unit.focusID, in: result) == recipes[0].id)

        let poses = try result.spatialWorldPoses(at: 0)
        let rod = try #require(poses.first { $0.node.id == recipes[0].id })
        guard case .cylinder(let radius, let height, _)? = rod.node.spatial3D?.geometry else {
          Issue.record("Prompt recipe did not compile to native cylinder geometry")
          continue
        }
        #expect(radius == 0.05 && abs(height - 2) < 0.000_001)
        let from = rod.transform.applying(to: .init(x: 0, y: -height / 2, z: 0))
        let to = rod.transform.applying(to: .init(x: 0, y: height / 2, z: 0))
        #expect(abs(from.x + 1) < 0.000_001 && abs(to.x - 1) < 0.000_001)
        #expect(abs(from.y) + abs(from.z) + abs(to.y) + abs(to.z) < 0.000_001)
      }
    }
  }

  private static let partsLine =
    ##"{"type":"scene","nodes":[{"id":"assembly","kind":"group","spatial3D":{}},{"id":"part-a","kind":"mesh","parentID":"assembly","fill":"#4488CC","spatial3D":{"transform":{"position":{"x":-1,"y":0,"z":0}},"geometry":{"type":"sphere","radius":0.3,"segments":24}}},{"id":"part-b","kind":"mesh","parentID":"assembly","fill":"#CC8844","spatial3D":{"transform":{"position":{"x":1,"y":0,"z":0}},"geometry":{"type":"box","width":0.6,"height":0.6,"depth":0.6}}}],"removeIDs":[]}"##
}

private actor ConnectorGrammarAdmission {
  private var document = SceneDocument(id: "connector-grammar")
  private(set) var acceptedScenes = 0

  func receive(_ unit: ProviderUnit) throws {
    let accepted = try ProviderSceneBoundary.applying(
      unit, to: document, baseRevision: document.revision)
    document = accepted
    acceptedScenes += 1
  }

  func snapshot() -> SceneDocument { document }
}
