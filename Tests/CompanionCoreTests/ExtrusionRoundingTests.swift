import Foundation
import Testing

@testable import CompanionCore

struct ExtrusionRoundingTests {
  @Test func omittedAndExplicitZeroKeepTheExactLinearContourAndEncoding() throws {
    let shape = Geometry3D.extrusion(profile: square, depth: 0.4)
    let zero = try SpatialProfile3D.extrusionContour(square, cornerRounding: 0)
    #expect(zero == square)
    let encoded = try JSONEncoder().encode(shape)
    let fields = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    #expect(fields["cornerRounding"] == nil)
    let explicit = try JSONDecoder().decode(
      Geometry3D.self,
      from: Data(
        #"{"type":"extrusion","profile":[{"x":-1,"y":-1},{"x":1,"y":-1},{"x":1,"y":1},{"x":-1,"y":1}],"depth":0.4,"cornerRounding":0}"#
          .utf8))
    #expect(explicit == shape)
    #expect(try JSONEncoder().encode(explicit).count == encoded.count)
  }

  @Test func convexRoundingActuallyRemovesCornersAndPreservesWindingAndTriangulatedArea() throws {
    for source in [square, Array(square.reversed())] {
      let rounded = try SpatialProfile3D.extrusionContour(source, cornerRounding: 0.2)
      #expect(rounded.count > source.count && rounded.count <= 160)
      #expect(!rounded.contains(.init(x: -1, y: -1)))
      #expect(rounded.allSatisfy { abs($0.x) <= 1 && abs($0.y) <= 1 })
      let area = try SpatialProfile3D.signedArea(
        of: rounded, maximumPoints: 160, minimumEdgeLength: 0)
      let original = try SpatialProfile3D.signedArea(of: source)
      #expect(area * original > 0 && abs(area) < abs(original) && abs(area) > 3.5)
      let triangles = try SpatialProfile3D.triangulation(
        rounded, maximumPoints: 160, minimumEdgeLength: 0)
      var total = 0.0
      for i in stride(from: 0, to: triangles.count, by: 3) {
        let a = rounded[triangles[i]]
        let b = rounded[triangles[i + 1]]
        let c = rounded[triangles[i + 2]]
        let piece = ((b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)) / 2
        #expect(piece > 0)
        total += piece
      }
      #expect(abs(total - abs(area)) < 1e-8)
    }
  }

  @Test func explicitConcaveRoundingCanAddMaterialButDoesNotEraseTheNotch() throws {
    let profile: [Point2D] = [
      .init(x: -1, y: -1), .init(x: 1, y: -1), .init(x: 1, y: 0), .init(x: 0, y: 0),
      .init(x: 0, y: 1), .init(x: -1, y: 1),
    ]
    let rounded = try SpatialProfile3D.extrusionContour(profile, cornerRounding: 0.2)
    #expect(!contains(.init(x: 0.03, y: 0.03), in: profile))
    #expect(contains(.init(x: 0.03, y: 0.03), in: rounded))
    #expect(!contains(.init(x: 0.6, y: 0.6), in: rounded))
    #expect(contains(.init(x: -0.5, y: -0.5), in: rounded))
  }

  @Test func roundedShapePersistsAndBudgetUsesTheDerivedContour() throws {
    let shape = Geometry3D.extrusion(profile: square, depth: 0.4, cornerRounding: 0.2)
    let data = try JSONEncoder().encode(shape)
    let fields = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(fields["cornerRounding"] as? Double == 0.2)
    #expect(try JSONDecoder().decode(Geometry3D.self, from: data) == shape)
    let linear = try Geometry3D.extrusion(profile: square, depth: 0.4).validatedBudget()
    let rounded = try shape.validatedBudget()
    #expect(rounded.vertices > linear.vertices && rounded.triangles > linear.triangles)
    var limits = SceneLimits()
    limits.maximumSpatialVertices = linear.vertices
    #expect(throws: CoreError.self) { try shape.validatedBudget(limits: limits) }
    let original = (0..<32).map { index in
      let angle = Double(index) * 2 * Double.pi / 32
      return Point2D(x: cos(angle), y: sin(angle))
    }
    let expanded = try SpatialProfile3D.extrusionContour(original, cornerRounding: 0.25)
    #expect(expanded.count == 160)
    _ = try Geometry3D.extrusion(profile: original, depth: 0.1, cornerRounding: 0.25)
      .validatedBudget()
  }

  @Test func unsupportedFractionsAndNativePrecisionCollapseFailInsteadOfChangingTheContract() {
    for fraction in [-0.01, 0.2501, Double.nan, .infinity, .leastNonzeroMagnitude] {
      #expect(throws: CoreError.self) {
        try SpatialProfile3D.extrusionContour(square, cornerRounding: fraction)
      }
    }
    let small: [Point2D] = [
      .init(x: 999, y: 999), .init(x: 999.0011, y: 999), .init(x: 999.0011, y: 999.0011),
      .init(x: 999, y: 999.0011),
    ]
    #expect(throws: CoreError.self) {
      try SpatialProfile3D.extrusionContour(small, cornerRounding: 0.2)
    }
  }

  @Test func aSimpleSourceWhoseRoundingCrossesAnotherBoundaryIsRejected() throws {
    let thinNotch: [Point2D] = [
      .init(x: 0, y: 0), .init(x: 4, y: 0), .init(x: 4, y: 4), .init(x: 0, y: 4),
      .init(x: 0, y: 0.5), .init(x: 3.99, y: 0.5), .init(x: 3.99, y: 0.45), .init(x: 0, y: 0.45),
    ]
    _ = try SpatialProfile3D.signedArea(of: thinNotch)
    #expect(throws: CoreError.self) {
      try SpatialProfile3D.extrusionContour(thinNotch, cornerRounding: 0.25)
    }
  }

  @Test func smallRoundedConcaveCapsPreserveEveryBoundaryEdgeAndExactMaterialArea() throws {
    let source: [Point2D] = [
      .init(x: 0, y: 0), .init(x: 0.01, y: 0), .init(x: 0.01, y: 0.005), .init(x: 0.005, y: 0.005),
      .init(x: 0.005, y: 0.01), .init(x: 0, y: 0.01),
    ]
    for profile in [source, Array(source.reversed())] {
      for fraction in [0.001, 0.0002] {
        let contour = try SpatialProfile3D.extrusionContour(profile, cornerRounding: fraction)
        let triangles = try SpatialProfile3D.triangulation(
          contour, maximumPoints: 160, minimumEdgeLength: 0, preserveBoundary: true)
        #expect(triangles.count == (contour.count - 2) * 3)
        #expect(Set(triangles) == Set(contour.indices))
        var edges: [Edge: Int] = [:]
        var area = 0.0
        for i in stride(from: 0, to: triangles.count, by: 3) {
          let a = contour[triangles[i]]
          let b = contour[triangles[i + 1]]
          let c = contour[triangles[i + 2]]
          let piece = ((b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)) / 2
          #expect(piece > 0)
          area += piece
          for j in 0..<3 {
            edges[Edge(triangles[i + j], triangles[i + (j + 1) % 3]), default: 0] += 1
          }
        }
        let expected = abs(
          try SpatialProfile3D.signedArea(of: contour, maximumPoints: 160, minimumEdgeLength: 0))
        #expect(abs(area - expected) <= expected * 1e-12)
        for i in contour.indices { #expect(edges[Edge(i, (i + 1) % contour.count)] == 1) }
        #expect(edges.values.allSatisfy { $0 == 1 || $0 == 2 })
        _ = try Geometry3D.extrusion(profile: profile, depth: 0.01, cornerRounding: fraction)
          .validatedBudget()
      }
    }
  }

  private struct Edge: Hashable {
    let a, b: Int
    init(_ a: Int, _ b: Int) {
      self.a = min(a, b)
      self.b = max(a, b)
    }
  }

  private var square: [Point2D] {
    [.init(x: -1, y: -1), .init(x: 1, y: -1), .init(x: 1, y: 1), .init(x: -1, y: 1)]
  }
  private func contains(_ p: Point2D, in polygon: [Point2D]) -> Bool {
    var result = false
    for index in polygon.indices {
      let a = polygon[index]
      let b = polygon[(index + 1) % polygon.count]
      if (a.y > p.y) != (b.y > p.y), p.x < (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x {
        result.toggle()
      }
    }
    return result
  }
}
