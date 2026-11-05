import CompanionCore
import Foundation
import Testing

@testable import OpenCompanion

struct SpatialSurfaceCandidatesTests {
  @Test func everyPrimitiveCandidateBelongsToItsActualMaterialSurface() {
    for geometry in geometries {
      for hint in [Vector3D.zero, .init(x: 0.7, y: 1.1, z: 0.7), .init(x: -4, y: 6, z: -3)] {
        let points = SpatialSurfaceCandidates.points(for: geometry, hint: hint)
        #expect(!points.isEmpty && points.count <= 32)
        #expect(
          points.allSatisfy { $0.isFinite && onSurface($0, of: geometry) }, "\(geometry), \(hint)")
        #expect(Set(points).count == points.count)
      }
    }
  }

  @Test func closestPointUsesActualCutFacesInsteadOfTheEmptyBoreOrGap() throws {
    let geometry = Geometry3D.tube(
      innerRadius: 1.2, outerRadius: 1.42, height: 3.2, startAngleDegrees: 120,
      sweepAngleDegrees: 240)
    let point = try #require(
      SpatialSurfaceCandidates.points(for: geometry, hint: .init(x: 0.7, y: 1.1, z: 0.7), limit: 1)
        .first)
    #expect(near(point.x, 1.2) && near(point.y, 1.1) && near(point.z, 0))
    #expect(onSurface(point, of: geometry))
    let cut = Geometry3D.tube(
      innerRadius: 1, outerRadius: 2, height: 4, startAngleDegrees: 90, sweepAngleDegrees: 180)
    let projected = try #require(
      SpatialSurfaceCandidates.points(
        for: cut, hint: .init(x: 2.squareRoot(), y: 0, z: 2.squareRoot()), limit: 1
      ).first)
    #expect(near(projected.x, 0) && near(projected.z, 2.squareRoot()))
    #expect(onSurface(projected, of: cut))
  }

  @Test func closestPointsHandleInteriorCentersAndRoundedBoxCorners() throws {
    let cases: [(Geometry3D, Vector3D)] = [
      (.box(width: 2, height: 4, depth: 6), .init(x: 1, y: 0, z: 0)),
      (.sphere(radius: 2), .init(x: 2, y: 0, z: 0)),
      (.cylinder(radius: 1, height: 4), .init(x: 1, y: 0, z: 0)),
      (.torus(ringRadius: 2, pipeRadius: 0.5), .init(x: 1.5, y: 0, z: 0)),
      (.tube(innerRadius: 1, outerRadius: 2, height: 4), .init(x: 1, y: 0, z: 0)),
    ]
    for (geometry, expected) in cases {
      let point = try #require(
        SpatialSurfaceCandidates.points(for: geometry, hint: .zero, limit: 1).first)
      #expect(near(point.x, expected.x) && near(point.y, expected.y) && near(point.z, expected.z))
    }
    let rounded = Geometry3D.box(width: 2, height: 2, depth: 2, chamferRadius: 0.2)
    let corner = try #require(
      SpatialSurfaceCandidates.points(for: rounded, hint: .init(x: 3, y: 3, z: 3), limit: 1).first)
    let expected = 0.8 + 0.2 / 3.squareRoot()
    #expect(near(corner.x, expected) && near(corner.y, expected) && near(corner.z, expected))
    #expect(onSurface(corner, of: rounded))
  }

  @Test func resultsAreStableBoundedAndInvalidInputCannotAllocateFromTessellation() {
    for geometry in geometries {
      let hint = Vector3D(x: 0.3, y: -0.4, z: 0.6)
      let first = SpatialSurfaceCandidates.points(for: geometry, hint: hint, limit: Int.max)
      #expect(first == SpatialSurfaceCandidates.points(for: geometry, hint: hint))
      #expect(first.count <= 32)
      #expect(
        SpatialSurfaceCandidates.points(for: geometry, hint: hint, limit: 1)
          == Array(first.prefix(1)))
      #expect(SpatialSurfaceCandidates.points(for: geometry, hint: hint, limit: Int.min).isEmpty)
      #expect(
        SpatialSurfaceCandidates.points(for: geometry, hint: .init(x: .nan, y: 0, z: 0)).isEmpty)
      let extreme = SpatialSurfaceCandidates.points(
        for: geometry,
        hint: .init(
          x: .greatestFiniteMagnitude, y: .greatestFiniteMagnitude, z: -.greatestFiniteMagnitude))
      #expect(!extreme.isEmpty && extreme.allSatisfy { $0.isFinite && onSurface($0, of: geometry) })
    }
    for geometry in [
      Geometry3D.sphere(radius: 1, segments: Int.max), .box(width: .infinity, height: 1, depth: 1),
    ] {
      #expect(SpatialSurfaceCandidates.points(for: geometry, hint: .zero).isEmpty)
    }
  }

  private var geometries: [Geometry3D] {
    [
      .box(width: 2, height: 3, depth: 4),
      .box(width: 2, height: 3, depth: 4, chamferRadius: 0.2),
      .box(width: 2, height: 2, depth: 2, chamferRadius: 1),
      .sphere(radius: 1), .cylinder(radius: 1, height: 3),
      .torus(ringRadius: 2, pipeRadius: 0.4),
      .tube(innerRadius: 1.2, outerRadius: 1.42, height: 3.2),
      .tube(
        innerRadius: 1.2, outerRadius: 1.42, height: 3.2, startAngleDegrees: 120,
        sweepAngleDegrees: 240),
      .tube(
        innerRadius: 1.2, outerRadius: 1.42, height: 3.2, startAngleDegrees: -300,
        sweepAngleDegrees: 1),
    ]
  }

  private func onSurface(_ p: Vector3D, of geometry: Geometry3D) -> Bool {
    let radial = hypot(p.x, p.z)
    switch geometry {
    case .box(let width, let height, let depth, let chamfer):
      let half = Vector3D(x: width / 2, y: height / 2, z: depth / 2)
      guard abs(p.x) <= half.x + 1e-8, abs(p.y) <= half.y + 1e-8, abs(p.z) <= half.z + 1e-8 else {
        return false
      }
      if chamfer == 0 {
        return near(abs(p.x), half.x) || near(abs(p.y), half.y) || near(abs(p.z), half.z)
      }
      return near(
        hypot(
          hypot(max(0, abs(p.x) - half.x + chamfer), max(0, abs(p.y) - half.y + chamfer)),
          max(0, abs(p.z) - half.z + chamfer)), chamfer)
    case .sphere(let radius, _): return near(hypot(hypot(p.x, p.y), p.z), radius)
    case .cylinder(let radius, let height, _):
      return (near(radial, radius) && abs(p.y) <= height / 2 + 1e-8)
        || (near(abs(p.y), height / 2) && radial <= radius + 1e-8)
    case .torus(let ring, let pipe, _, _): return near(hypot(radial - ring, p.y), pipe)
    case .tube(let inner, let outer, let height, _, let start, let sweep):
      let angle = atan2(p.z, p.x) * 180 / .pi
      let raw = (angle - start).truncatingRemainder(dividingBy: 360)
      let offset = raw < 0 ? raw + 360 : raw
      let onCut = sweep < 360 && (near(offset, 0) || near(offset, 360) || near(offset, sweep))
      guard radial >= inner - 1e-8, radial <= outer + 1e-8, abs(p.y) <= height / 2 + 1e-8,
        sweep == 360 || offset <= sweep + 1e-8 || near(offset, 360)
      else { return false }
      return near(radial, inner) || near(radial, outer) || near(abs(p.y), height / 2) || onCut
    }
  }
  private func near(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 1e-8 }
}
