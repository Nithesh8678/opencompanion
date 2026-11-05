import CompanionCore
import Foundation
import SceneKit
import Testing

@testable import OpenCompanion

struct Spatial3DAdmissionTests {
  @Test func providerCreatesAndPatchesTypedGeometryThroughTheProductionBoundary() throws {
    let input = try unit(
      #"{"type":"scene","nodes":[{"id":"assembly","kind":"group","spatial3D":{}},{"id":"housing","kind":"mesh","parentID":"assembly","spatial3D":{"geometry":{"type":"tube","innerRadius":0.9,"outerRadius":1.1,"height":2,"sweepAngleDegrees":240}}},{"id":"label","kind":"text","text":"Housing","spatial3D":{"labelAnchor":{"targetID":"housing","point":{"x":1,"y":0,"z":0}}}}]}"#
    )
    let document = try ProviderSceneBoundary.applying(input, to: SceneDocument(), baseRevision: 0)
    #expect(document.usesSpatial3D && document.nodes.count == 3)
    let geometry = try #require(document.nodes.first { $0.id == "housing" }?.spatial3D?.geometry)
    #expect(
      geometry == .tube(innerRadius: 0.9, outerRadius: 1.1, height: 2, sweepAngleDegrees: 240))
    let patch = try unit(
      #"{"type":"scene","operations":[{"op":"node.patch","id":"housing","fields":{"spatial3D":{"geometry":{"type":"torus","ringRadius":1,"pipeRadius":0.1}}}}]}"#
    )
    let updated = try ProviderSceneBoundary.applying(patch, to: document, baseRevision: 1)
    #expect(
      updated.nodes.first { $0.id == "housing" }?.spatial3D?.geometry
        == .torus(ringRadius: 1, pipeRadius: 0.1))
    let style = try unit(
      ##"{"type":"scene","nodes":[{"id":"housing","kind":"mesh","parentID":"assembly","color":"#FFFFFF"}]}"##
    )
    let retained = try ProviderSceneBoundary.applying(style, to: updated, baseRevision: 2)
    #expect(
      retained.nodes.first { $0.id == "housing" }?.spatial3D
        == updated.nodes.first { $0.id == "housing" }?.spatial3D)
  }

  @Test func invalidTypedPayloadCannotPartiallyMutateAnExistingDocument() throws {
    let input = try unit(
      #"{"type":"scene","nodes":[{"id":"invalid","kind":"mesh","spatial3D":{"geometry":{"type":"sphere","radius":1,"segments":1000000}}}]}"#
    )
    let original = SceneDocument(nodes: [.init(id: "keep", kind: .text, text: "Keep")])
    #expect(throws: CoreError.self) {
      try ProviderSceneBoundary.applying(input, to: original, baseRevision: 0)
    }
    #expect(original.nodes.map(\.id) == ["keep"] && original.revision == 0)
  }

  @Test func neitherProviderReplacementNorOperationCanUpgradeARetainedLegacyMesh() throws {
    let source = SceneDocument(nodes: [.init(id: "retained", kind: .mesh, width: 100, height: 100)])
    for json in [
      #"{"type":"scene","nodes":[{"id":"retained","kind":"mesh","spatial3D":{"geometry":{"type":"sphere","radius":1}}}]}"#,
      #"{"type":"scene","operations":[{"op":"node.patch","id":"retained","fields":{"spatial3D":{"geometry":{"type":"sphere","radius":1}}}}]}"#,
    ] {
      let proposed = try unit(json)
      #expect(throws: CoreError.self) {
        try ProviderSceneBoundary.applying(proposed, to: source, baseRevision: 0)
      }
      #expect(source.revision == 0 && source.nodes.first?.spatial3D == nil)
    }
  }

  @Test @MainActor func nativeFactoryBuildsAllFiveBoundedPrimitiveKinds() throws {
    for shape in [
      Geometry3D.box(width: 2, height: 1, depth: 1, chamferRadius: 0.1),
      .sphere(radius: 1), .cylinder(radius: 0.2, height: 2),
      .torus(ringRadius: 1, pipeRadius: 0.1),
      .sphere(radius: 1, segments: 3),
      .cylinder(radius: 0.2, height: 2, segments: 3),
      .cylinder(radius: 0.2, height: 2, segments: 64),
      .torus(ringRadius: 1, pipeRadius: 0.1, ringSegments: 3, pipeSegments: 3),
      .sphere(radius: 1, segments: 64),
      .torus(ringRadius: 1, pipeRadius: 0.1, ringSegments: 64, pipeSegments: 64),
      .tube(innerRadius: 0.8, outerRadius: 1, height: 2, sweepAngleDegrees: 240),
    ] {
      let geometry = try Spatial3DGeometryFactory.make(shape)
      let budget = try shape.validatedBudget()
      for committed in [false, true] {
        // Native setters are transaction-backed: inspect both the constructor mesh and
        // the actual configured tessellation, including low and maximum segment counts.
        if committed { SCNTransaction.flush() }
        let vertices = geometry.sources(for: .vertex).reduce(0) { $0 + $1.vectorCount }
        let triangles = geometry.elements.reduce(0) { $0 + $1.primitiveCount }
        #expect(
          vertices > 0 && vertices <= budget.vertices,
          "\(shape), committed=\(committed): vertices \(vertices), budget \(budget.vertices)")
        #expect(
          triangles > 0 && triangles <= budget.triangles,
          "\(shape), committed=\(committed): triangles \(triangles), budget \(budget.triangles)")
        #expect(
          geometry.elements.allSatisfy { [.triangles, .triangleStrip].contains($0.primitiveType) })
        #expect(geometry.boundingBox.min.x.isFinite && geometry.boundingBox.max.z.isFinite)
      }
    }
    #expect(throws: CoreError.self) {
      try Spatial3DGeometryFactory.make(.sphere(radius: 1, segments: Int.max))
    }
  }

  @Test @MainActor func partialTubeFacesHaveFiniteConsistentOutwardNormalsWithinBudget() throws {
    let shape = Geometry3D.tube(
      innerRadius: 0.8, outerRadius: 1, height: 2, segments: 12, sweepAngleDegrees: 240)
    let geometry = try Spatial3DGeometryFactory.make(shape)
    let vertices = try vectors(try #require(geometry.sources(for: .vertex).first))
    let normals = try vectors(try #require(geometry.sources(for: .normal).first))
    let element = try #require(geometry.elements.first)
    let indices: [UInt32] = element.data.withUnsafeBytes { bytes in
      (0..<(bytes.count / MemoryLayout<UInt32>.size)).map {
        bytes.loadUnaligned(fromByteOffset: $0 * 4, as: UInt32.self)
      }
    }
    let budget = try shape.validatedBudget()
    #expect(vertices.count <= budget.vertices && indices.count / 3 <= budget.triangles)
    #expect(normals.count == vertices.count)
    for face in stride(from: 0, to: indices.count, by: 3) {
      let a = vertices[Int(indices[face])]
      let b = vertices[Int(indices[face + 1])]
      let c = vertices[Int(indices[face + 2])]
      let u = (b.x - a.x, b.y - a.y, b.z - a.z)
      let v = (c.x - a.x, c.y - a.y, c.z - a.z)
      let cross = (u.1 * v.2 - u.2 * v.1, u.2 * v.0 - u.0 * v.2, u.0 * v.1 - u.1 * v.0)
      let normal = normals[Int(indices[face])]
      let dot = cross.0 * normal.x + cross.1 * normal.y + cross.2 * normal.z
      #expect(dot.isFinite && dot > 0)
    }
  }

  private func vectors(_ source: SCNGeometrySource) throws -> [SIMD3<Float>] {
    try #require(
      source.usesFloatComponents && source.bytesPerComponent == 4 && source.componentsPerVector == 3
    )
    return source.data.withUnsafeBytes { bytes in
      (0..<source.vectorCount).map { index in
        let start = source.dataOffset + index * source.dataStride
        return SIMD3<Float>(
          (0..<3).map { bytes.loadUnaligned(fromByteOffset: start + $0 * 4, as: Float.self) })
      }
    }
  }
  private func unit(_ json: String) throws -> ProviderUnit {
    try JSONDecoder().decode(ProviderUnit.self, from: Data(json.utf8))
  }
}
