import Foundation
import Testing

@testable import CompanionCore

struct DirectionalGeometryTests {
  @Test func upwardArrowKeepsItsSignedDirection() throws {
    let source = SceneNode(id: "left_force", kind: .arrow, x: 120, y: 280, width: 0, height: -65)
    let normalized = try source.canonicalizedDirectionalGeometry()
    #expect(normalized.x == 120)
    #expect(normalized.y == 280)
    #expect(normalized.width == 0 && normalized.height == 0)
    #expect(normalized.points == [Point2D(x: 0, y: 0), Point2D(x: 0, y: -65)])
    _ = try SceneDocument(nodes: [normalized]).validated()
  }

  @Test func existingPointsAndSeparateSubpathsArePreservedExactly() throws {
    let points = [Point2D(x: 15, y: 20), Point2D(x: -45, y: -80)]
    let subpaths = [
      [Point2D(x: -4, y: -4), Point2D(x: 4, y: 4)],
      [Point2D(x: -4, y: 4), Point2D(x: 4, y: -4)],
    ]
    for kind: SceneNode.Kind in [.line, .arrow, .path] {
      let source = SceneNode(
        id: kind.rawValue, kind: kind, width: -60, height: -100,
        points: points, subpaths: subpaths)
      let normalized = try source.canonicalizedDirectionalGeometry()
      #expect(normalized.points == points)
      #expect(normalized.subpaths == subpaths)
      #expect(normalized.width == 0 && normalized.height == 0)
      #expect(try normalized.canonicalizedDirectionalGeometry() == normalized)
      _ = try SceneDocument(nodes: [normalized]).validated()
    }
  }

  @Test func emptySubpathsDoNotHideSynthesizedVector() throws {
    let normalized = try SceneNode(
      id: "left", kind: .line, width: -80, height: 30,
      subpaths: [[], []]
    ).canonicalizedDirectionalGeometry()
    #expect(normalized.subpaths.isEmpty)
    #expect(normalized.points.last == Point2D(x: -80, y: 30))
  }

  @Test func areaPrimitivesKeepStrictDimensions() throws {
    for kind: SceneNode.Kind in [.rectangle, .ellipse, .text, .mesh, .group] {
      let invalid = SceneNode(id: kind.rawValue, kind: kind, width: -12, height: 30)
      #expect(throws: (any Error).self) { try invalid.canonicalizedDirectionalGeometry() }
      #expect(throws: (any Error).self) { try SceneDocument(nodes: [invalid]).validated() }
      let valid = SceneNode(id: kind.rawValue, kind: kind, width: 12, height: 30)
      #expect(try valid.canonicalizedDirectionalGeometry() == valid)
    }
  }

  @Test func ignoredDirectionalMetadataCannotBypassFiniteAndSizeBudgets() {
    let point = [Point2D(x: 0, y: 0), Point2D(x: 10, y: -10)]
    for value in [Double.nan, .infinity, -.infinity, 100_001, -100_001] {
      #expect(throws: (any Error).self) {
        try SceneNode(id: "invalid", kind: .arrow, width: value, points: point)
          .canonicalizedDirectionalGeometry()
      }
    }
    #expect(throws: (any Error).self) {
      try SceneNode(id: "bad-point", kind: .path, points: [.init(x: .nan, y: 0)])
        .canonicalizedDirectionalGeometry()
    }
    #expect(throws: (any Error).self) {
      try SceneNode(id: "large-point", kind: .line, points: [.init(x: 0, y: 100_001)])
        .canonicalizedDirectionalGeometry()
    }
    var limits = SceneLimits()
    limits.maximumPoints = 1
    #expect(throws: (any Error).self) {
      try SceneNode(id: "vector-budget", kind: .arrow, height: -20)
        .canonicalizedDirectionalGeometry(limits: limits)
    }
    #expect(throws: (any Error).self) {
      try SceneNode(id: "point-budget", kind: .path, points: point)
        .canonicalizedDirectionalGeometry(limits: limits)
    }
  }
}
