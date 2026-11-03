import CompanionCore
import Foundation
import Testing

@testable import OpenCompanion

@Suite struct ProviderSceneBoundaryTests {
  private func unit(_ json: String) throws -> ProviderUnit {
    try JSONDecoder().decode(ProviderUnit.self, from: Data(json.utf8))
  }

  @Test func operationCreateAndSequentialPatchCanonicalizeSignedVectors() throws {
    let input = try unit(
      ##"{"type":"scene","operations":[{"op":"node.create","node":{"id":"force","kind":"arrow","height":-65}},{"op":"node.patch","id":"force","fields":{"height":-90,"color":"#123456"}}]}"##
    )
    let result = try ProviderSceneBoundary.applying(input, to: SceneDocument(), baseRevision: 0)
    let node = try #require(result.nodes.first)
    #expect(node.points == [Point2D(x: 0, y: 0), Point2D(x: 0, y: -90)])
    #expect(node.width == 0 && node.height == 0)
    #expect(node.color == "#123456")
  }

  @Test func stylePatchPreservesEveryOmittedFieldAndExistingSubpaths() throws {
    let node = SceneNode(
      id: "force", kind: .arrow, x: 40, y: 50, width: 12, height: 30,
      points: [.init(x: 0, y: 0), .init(x: 0, y: -10)],
      subpaths: [[.init(x: 2, y: 3), .init(x: 4, y: 5)]])
    let source = SceneDocument(nodes: [node])
    let input = try unit(
      ##"{"type":"scene","operations":[{"op":"node.patch","id":"force","fields":{"color":"#123456"}}]}"##
    )
    let result = try ProviderSceneBoundary.applying(input, to: source, baseRevision: 0)
    var expected = node
    expected.color = "#123456"
    #expect(result.nodes == [expected])
    #expect(source.nodes == [node])
  }

  @Test func explicitPointsReplaceMaskingSubpathsAndSubpathsReplacePoints() throws {
    let old = SceneNode(
      id: "force", kind: .arrow, x: 40, y: 50,
      subpaths: [[.init(x: 0, y: 0), .init(x: 10, y: 20)]])
    let points = try unit(
      ##"{"type":"scene","operations":[{"op":"node.patch","id":"force","fields":{"points":[{"x":0,"y":0},{"x":0,"y":-80}]}}]}"##
    )
    let first = try ProviderSceneBoundary.applying(
      points, to: SceneDocument(nodes: [old]), baseRevision: 0)
    #expect(first.nodes[0].subpaths.isEmpty)
    #expect(first.nodes[0].points.last?.y == -80)
    #expect(first.nodes[0].x == 40 && first.nodes[0].y == 50)
    let subpaths = try unit(
      ##"{"type":"scene","operations":[{"op":"node.patch","id":"force","fields":{"subpaths":[[{"x":0,"y":0},{"x":60,"y":0}]]}}]}"##
    )
    let second = try ProviderSceneBoundary.applying(subpaths, to: first, baseRevision: 1)
    #expect(second.nodes[0].points.isEmpty)
    #expect(second.nodes[0].subpaths.first?.last?.x == 60)
    let clear = try unit(
      ##"{"type":"scene","operations":[{"op":"node.patch","id":"force","fields":{"subpaths":[]}}]}"##
    )
    let empty = try ProviderSceneBoundary.applying(clear, to: second, baseRevision: 2)
    #expect(empty.nodes[0].points.isEmpty && empty.nodes[0].subpaths.isEmpty)
  }

  @Test func legacyReplacementCarriesNewSubpathsAndKeepsUnrelatedParts() throws {
    let arrow = SceneNode(
      id: "force", kind: .arrow, subpaths: [[.init(x: 0, y: 0), .init(x: 10, y: 20)]])
    let note = SceneNode(id: "note", kind: .text, text: "User note")
    let input = try unit(
      ##"{"type":"scene","nodes":[{"id":"force","kind":"arrow","subpaths":[[{"x":0,"y":0},{"x":-80,"y":0}]]}]}"##
    )
    let result = try ProviderSceneBoundary.applying(
      input, to: SceneDocument(nodes: [arrow, note]), baseRevision: 0)
    #expect(result.nodes[0].subpaths.first?.last?.x == -80)
    #expect(result.nodes[1] == note)
  }

  @Test func ordinaryTransactionsStayStrictAndFailedProviderUnitsAreAtomic() throws {
    let source = SceneDocument(nodes: [SceneNode(id: "note", kind: .text, text: "Kept")])
    let negative = SceneNode(id: "bad", kind: .arrow, height: -65)
    #expect(throws: (any Error).self) {
      try source.applying(
        SceneTransaction(baseDocumentRevision: 0, operations: [.create(negative)]))
    }
    let input = try unit(
      ##"{"type":"scene","operations":[{"op":"node.create","node":{"id":"force","kind":"arrow","height":-65}},{"op":"node.patch","id":"missing","fields":{"color":"#123456"}}]}"##
    )
    #expect(throws: (any Error).self) {
      try ProviderSceneBoundary.applying(input, to: source, baseRevision: 0)
    }
    #expect(source.nodes.count == 1 && source.nodes[0].text == "Kept")
  }

  @Test func oldPatchPayloadDecodesWithoutSubpathsAndNewFieldRoundTrips() throws {
    let old = try JSONDecoder().decode(ScenePatch.self, from: Data(##"{"color":"#123456"}"##.utf8))
    #expect(old.subpaths == nil && old.points == nil)
    let updated = ScenePatch(subpaths: [[.init(x: 0, y: 0), .init(x: 4, y: 5)]])
    #expect(
      try JSONDecoder().decode(ScenePatch.self, from: JSONEncoder().encode(updated)) == updated)
  }
}
