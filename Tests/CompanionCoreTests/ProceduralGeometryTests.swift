import Foundation
import Testing

@testable import CompanionCore

struct ProceduralGeometryTests {
  @Test func expressiveShapesRoundTripAndOldDocumentsKeepTheirDefaults() throws {
    let shapes: [Geometry3D] = [
      .cone(topRadius: 0, bottomRadius: 1, height: 2),
      .cone(topRadius: 0.4, bottomRadius: 1, height: 2),
      .capsule(radius: 0.5, height: 3), .capsule(radius: 1, height: 2),
      .lathe(profile: vessel), .extrusion(profile: concave, depth: 0.4),
    ]
    for shape in shapes {
      let data = try JSONEncoder().encode(shape)
      let decoded = try JSONDecoder().decode(Geometry3D.self, from: data)
      #expect(decoded == shape)
      let budget = try shape.validatedBudget()
      #expect(budget.vertices > 0 && budget.vertices <= 32_768 && budget.triangles <= 65_536)
      let doc = SceneDocument(nodes: [
        .init(id: "part", kind: .mesh, spatial3D: .init(geometry: shape))
      ])
      _ = try doc.validated()
    }
    let legacy = try JSONDecoder().decode(
      Geometry3D.self, from: Data(#"{"type":"sphere","radius":1}"#.utf8))
    #expect(legacy == .sphere(radius: 1, segments: 24))
  }

  @Test func strictProfileDecodingRejectsForeignKeysAndStopsAtThePointBudget() throws {
    for raw in [
      #"{"type":"cone","topRadius":0,"bottomRadius":1,"height":2,"radius":1}"#,
      #"{"type":"capsule","radius":1,"height":3,"asset":"unused"}"#,
      #"{"type":"lathe","profile":[{"radius":1,"y":-1,"x":0},{"radius":1,"y":1}]}"#,
      #"{"type":"extrusion","depth":1,"profile":[{"x":0,"y":0,"z":0},{"x":1,"y":0},{"x":0,"y":1}]}"#,
    ] {
      #expect(throws: (any Error).self) {
        try JSONDecoder().decode(Geometry3D.self, from: Data(raw.utf8))
      }
    }
    let points = Array(repeating: #"{"radius":1,"y":0}"#, count: 33).joined(separator: ",")
    let tooMany = Data((#"{"type":"lathe","profile":["# + points + "]}").utf8)
    #expect(throws: CoreError.self) { try JSONDecoder().decode(Geometry3D.self, from: tooMany) }
  }

  @Test func concaveExtrusionTriangulationPreservesAreaForBothWindings() throws {
    for profile in [concave, Array(concave.reversed())] {
      let indices = try SpatialProfile3D.triangulation(profile)
      var area = 0.0
      for i in stride(from: 0, to: indices.count, by: 3) {
        let a = profile[indices[i]]
        let b = profile[indices[i + 1]]
        let c = profile[indices[i + 2]]
        let triangle = ((b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)) / 2
        #expect(triangle > 0)
        area += triangle
      }
      #expect(abs(area - abs(try SpatialProfile3D.signedArea(of: profile))) < 1e-9)
    }
  }

  @Test func materialProfilesRejectCrossingTouchingAndAdjacentBacktracking() throws {
    let badProfiles: [[Point2D]] = [
      [.init(x: 0, y: 0), .init(x: 2, y: 2), .init(x: 0, y: 2), .init(x: 2, y: 0)],
      [
        .init(x: 0, y: 0), .init(x: 2, y: 0), .init(x: 1, y: 0), .init(x: 2, y: 2),
        .init(x: 0, y: 2),
      ],
      [.init(x: 0, y: 0), .init(x: 2, y: 0), .init(x: 2, y: 2), .init(x: 0, y: 0)],
    ]
    for profile in badProfiles {
      #expect(throws: CoreError.self) { try SpatialProfile3D.triangulation(profile) }
    }
    let forward: [Point2D] = [
      .init(x: 0, y: 0), .init(x: 1, y: 0), .init(x: 2, y: 0), .init(x: 2, y: 2), .init(x: 0, y: 2),
    ]
    let indices = try SpatialProfile3D.triangulation(forward)
    var area = 0.0
    for index in stride(from: 0, to: indices.count, by: 3) {
      let a = forward[indices[index]]
      let b = forward[indices[index + 1]]
      let c = forward[indices[index + 2]]
      let triangle = ((b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)) / 2
      #expect(triangle > 0)
      area += triangle
    }
    #expect(abs(area - 4) < 1e-9)
    for profile in [vessel, Array(vessel.reversed())] {
      let contour = try SpatialProfile3D.latheContour(profile)
      #expect(contour.count <= 34)
      _ = try Geometry3D.lathe(profile: profile).validatedBudget()
    }
  }

  @Test func invalidDimensionsProfilesAndNativeBudgetsFailBeforeConstruction() {
    let invalid: [Geometry3D] = [
      .cone(topRadius: 0, bottomRadius: 0, height: 2),
      .cone(topRadius: -1, bottomRadius: 1, height: 2),
      .cone(topRadius: 0.000_001, bottomRadius: 1, height: 2),
      .capsule(radius: 1, height: 1.99), .capsule(radius: .infinity, height: 3),
      .lathe(profile: [.init(radius: -1, y: -1), .init(radius: 1, y: 1)]),
      .lathe(profile: [.init(radius: 1, y: 0), .init(radius: 2, y: 0)]),
      .extrusion(profile: concave, depth: -.infinity),
    ]
    for shape in invalid { #expect(throws: CoreError.self) { try shape.validatedBudget() } }
    var limits = SceneLimits()
    limits.maximumSpatialVertices = 10
    for shape: Geometry3D in [
      .capsule(radius: 1, height: 3), .lathe(profile: vessel),
      .extrusion(profile: concave, depth: 1),
    ] {
      #expect(throws: CoreError.self) { try shape.validatedBudget(limits: limits) }
    }
  }

  private var vessel: [LathePoint3D] {
    [
      .init(radius: 1, y: -1), .init(radius: 1, y: 1), .init(radius: 0.8, y: 1),
      .init(radius: 0.8, y: -0.8),
    ]
  }
  private var concave: [Point2D] {
    [.init(x: 0, y: 0), .init(x: 2, y: 0), .init(x: 1, y: 1), .init(x: 2, y: 2), .init(x: 0, y: 2)]
  }
}
