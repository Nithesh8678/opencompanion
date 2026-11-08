import CompanionCore
import Foundation
import SceneKit
import Testing

@testable import OpenCompanion

struct ProceduralGeometryNativeTests {
  @Test @MainActor func actualIndexedTrianglesStayWithinBudgetAndHaveOutwardWinding() throws {
    let profile: [Point2D] = [
      .init(x: 0, y: 0), .init(x: 2, y: 0), .init(x: 1, y: 1), .init(x: 2, y: 2), .init(x: 0, y: 2),
    ]
    let shapes: [Geometry3D] = [
      .cone(topRadius: 0, bottomRadius: 1, height: 2, segments: 3),
      .cone(topRadius: 0.5, bottomRadius: 1, height: 2, segments: 64),
      .capsule(radius: 1, height: 2, segments: 3),
      .capsule(radius: 0.5, height: 3, segments: 64),
      .lathe(profile: vessel, segments: 64),
      .lathe(profile: Array(vessel.reversed()), segments: 24),
      .extrusion(profile: profile, depth: 0.4),
      .extrusion(profile: Array(profile.reversed()), depth: 0.4),
    ]
    for shape in shapes {
      let geometry = try Spatial3DGeometryFactory.make(shape)
      let budget = try shape.validatedBudget()
      let vertices = try vectors(try #require(geometry.sources(for: .vertex).first))
      let normals = try vectors(try #require(geometry.sources(for: .normal).first))
      let element = try #require(geometry.elements.first)
      let indices: [UInt32] = element.data.withUnsafeBytes { bytes in
        (0..<(bytes.count / 4)).map { bytes.loadUnaligned(fromByteOffset: $0 * 4, as: UInt32.self) }
      }
      #expect(!vertices.isEmpty && vertices.count <= budget.vertices)
      #expect(indices.count / 3 > 0 && indices.count / 3 <= budget.triangles)
      #expect(normals.count == vertices.count)
      for i in stride(from: 0, to: indices.count, by: 3) {
        let a = vertices[Int(indices[i])]
        let b = vertices[Int(indices[i + 1])]
        let c = vertices[Int(indices[i + 2])]
        let u = b - a
        let v = c - a
        let cross = SIMD3(u.y * v.z - u.z * v.y, u.z * v.x - u.x * v.z, u.x * v.y - u.y * v.x)
        let normal =
          normals[Int(indices[i])] + normals[Int(indices[i + 1])] + normals[Int(indices[i + 2])]
        let dot = cross.x * normal.x + cross.y * normal.y + cross.z * normal.z
        #expect(dot.isFinite && dot > 0, "\(shape): triangle \(i / 3)")
      }
    }
  }

  @Test @MainActor func hollowVesselHasAnOpenMouthRealFloorAndOppositeInnerOuterFaces() throws {
    for profile in [vessel, Array(vessel.reversed())] {
      let node = SCNNode(
        geometry: try Spatial3DGeometryFactory.make(.lathe(profile: profile, segments: 32)))
      let scene = SCNScene()
      scene.rootNode.addChildNode(node)
      SCNTransaction.flush()
      let options: [String: Any] = [SCNHitTestOption.backFaceCulling.rawValue: true]
      let mouth = scene.rootNode.hitTestWithSegment(
        from: SCNVector3(0, 2, 0), to: SCNVector3(0, 0, 0), options: options)
      #expect(mouth.isEmpty)
      let floor = try #require(
        scene.rootNode.hitTestWithSegment(
          from: SCNVector3(0.1, 0, 0), to: SCNVector3(0.1, -2, 0), options: options
        ).first)
      #expect(abs(floor.localCoordinates.y + 0.8) < 0.001 && floor.localNormal.y > 0.99)
      let inner = try #require(
        scene.rootNode.hitTestWithSegment(
          from: SCNVector3(0, 0, 0), to: SCNVector3(2, 0, 0), options: options
        ).first)
      #expect(abs(inner.localCoordinates.x - 0.8) < 0.001 && inner.localNormal.x < -0.9)
      let outer = try #require(
        scene.rootNode.hitTestWithSegment(
          from: SCNVector3(2, 0, 0), to: SCNVector3(0, 0, 0), options: options
        ).first)
      #expect(abs(outer.localCoordinates.x - 1) < 0.001 && outer.localNormal.x > 0.9)
      let rim = try #require(
        scene.rootNode.hitTestWithSegment(
          from: SCNVector3(0.9, 2, 0), to: SCNVector3(0.9, 0, 0), options: options
        ).first)
      #expect(abs(rim.localCoordinates.y - 1) < 0.001 && rim.localNormal.y > 0.99)
    }
  }

  @Test @MainActor func profileEndCapsPreserveSpecifiedYInsteadOfRecenteringOrClosingTheMouth()
    throws
  {
    let shape = Geometry3D.lathe(
      profile: [.init(radius: 0.7, y: 2), .init(radius: 1, y: 4)], segments: 24)
    let geometry = try Spatial3DGeometryFactory.make(shape)
    let vertices = try vectors(try #require(geometry.sources(for: .vertex).first))
    let minimumY = try #require(vertices.map(\.y).min())
    let maximumY = try #require(vertices.map(\.y).max())
    #expect(abs(minimumY - 2) < 0.001)
    #expect(abs(maximumY - 4) < 0.001)
    #expect(vertices.contains { abs($0.x) < 1e-6 && abs($0.z) < 1e-6 && abs($0.y - 2) < 1e-6 })
    #expect(vertices.contains { abs($0.x) < 1e-6 && abs($0.z) < 1e-6 && abs($0.y - 4) < 1e-6 })
  }

  private var vessel: [LathePoint3D] {
    [
      .init(radius: 1, y: -1), .init(radius: 1, y: 1), .init(radius: 0.8, y: 1),
      .init(radius: 0.8, y: -0.8),
    ]
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
}
