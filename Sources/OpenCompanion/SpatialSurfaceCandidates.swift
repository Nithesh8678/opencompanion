import CompanionCore
import Foundation

/// Local material-surface proposals only. The native resolver still checks
/// actual triangles and scene occlusion before presenting an attachment.
enum SpatialSurfaceCandidates {
  static func points(for geometry: Geometry3D, hint: Vector3D, limit: Int = 32) -> [Vector3D] {
    let count = min(32, max(0, limit))
    guard count > 0, hint.isFinite, (try? geometry.validatedBudget()) != nil else { return [] }
    var samples: [Vector3D] = []
    let closest: Vector3D
    switch geometry {
    case .box(let width, let height, let depth, let chamfer):
      let half = Vector3D(x: width / 2, y: height / 2, z: depth / 2)
      let inner = Vector3D(x: half.x - chamfer, y: half.y - chamfer, z: half.z - chamfer)
      closest = boxPoint(hint, half: half, inner: inner, chamfer: chamfer)
      for direction in directions {
        let unit = normalized(direction, fallback: .init(x: 1, y: 0, z: 0))
        samples.append(
          .init(
            x: sign(direction.x) * inner.x + unit.x * chamfer,
            y: sign(direction.y) * inner.y + unit.y * chamfer,
            z: sign(direction.z) * inner.z + unit.z * chamfer))
      }
    case .sphere(let radius, _):
      closest = scaled(normalized(hint, fallback: .init(x: 1, y: 0, z: 0)), by: radius)
      samples = directions.map {
        scaled(normalized($0, fallback: .init(x: 1, y: 0, z: 0)), by: radius)
      }
    case .cylinder(let radius, let height, _):
      let halfHeight = height / 2
      let radial = radialDirection(hint)
      let diskRadius = min(radius, hypot(hint.x, hint.z))
      closest = nearest(
        [
          .init(
            x: radial.x * radius, y: clamped(hint.y, -halfHeight, halfHeight), z: radial.z * radius),
          .init(x: radial.x * diskRadius, y: halfHeight, z: radial.z * diskRadius),
          .init(x: radial.x * diskRadius, y: -halfHeight, z: radial.z * diskRadius),
        ], to: hint)
      for index in 0..<8 {
        let angle = Double(index) * .pi / 4
        for y in [-halfHeight, 0, halfHeight] {
          samples.append(.init(x: radius * cos(angle), y: y, z: radius * sin(angle)))
        }
      }
      samples.append(contentsOf: [
        .init(x: 0, y: halfHeight, z: 0), .init(x: 0, y: -halfHeight, z: 0),
      ])
    case .cone(let top, let bottom, let height, _):
      guard
        let contour = try? SpatialProfile3D.latheContour([
          .init(radius: bottom, y: -height / 2), .init(radius: top, y: height / 2),
        ])
      else { return [] }
      (closest, samples) = revolutionPoints(contour, hint: hint)
    case .capsule(let radius, let height, _):
      let halfStraight = (height - 2 * radius) / 2
      let center = Vector3D(x: 0, y: clamped(hint.y, -halfStraight, halfStraight), z: 0)
      let unit = normalized(
        .init(x: hint.x, y: hint.y - center.y, z: hint.z), fallback: .init(x: 1, y: 0, z: 0))
      closest = .init(x: unit.x * radius, y: center.y + unit.y * radius, z: unit.z * radius)
      samples = directions.map { direction in
        let unit = normalized(direction, fallback: .init(x: 1, y: 0, z: 0))
        return .init(
          x: unit.x * radius, y: sign(unit.y) * halfStraight + unit.y * radius, z: unit.z * radius)
      }
    case .lathe(let profile, _):
      guard let contour = try? SpatialProfile3D.latheContour(profile) else { return [] }
      (closest, samples) = revolutionPoints(contour, hint: hint)
    case .extrusion(let profile, let depth):
      (closest, samples) = extrusionPoints(profile, depth: depth, hint: hint)
    case .torus(let ringRadius, let pipeRadius, _, _):
      let radial = radialDirection(hint)
      let center = Vector3D(x: radial.x * ringRadius, y: 0, z: radial.z * ringRadius)
      let pipe = normalized(
        .init(x: hint.x - center.x, y: hint.y, z: hint.z - center.z), fallback: radial)
      closest = .init(
        x: center.x + pipe.x * pipeRadius, y: pipe.y * pipeRadius,
        z: center.z + pipe.z * pipeRadius)
      for ring in 0..<8 {
        let angle = Double(ring) * .pi / 4
        for pipe in 0..<4 {
          let crossSection = Double(pipe) * .pi / 2
          let radius = ringRadius + pipeRadius * cos(crossSection)
          samples.append(
            .init(x: radius * cos(angle), y: pipeRadius * sin(crossSection), z: radius * sin(angle))
          )
        }
      }
    case .tube(let inner, let outer, let height, _, let startDegrees, let sweepDegrees):
      let halfHeight = height / 2
      let start = positiveAngle(startDegrees * .pi / 180)
      let sweep = sweepDegrees * .pi / 180
      let full = sweepDegrees == 360
      let angle = tubeAngle(hint, start: start, sweep: sweep, full: full)
      let y = clamped(hint.y, -halfHeight, halfHeight)
      let planar = tubePlanarPoint(
        hint, inner: inner, outer: outer, start: start, sweep: sweep, full: full)
      var boundary: [Vector3D] = [
        .init(x: inner * cos(angle), y: y, z: inner * sin(angle)),
        .init(x: outer * cos(angle), y: y, z: outer * sin(angle)),
        .init(x: planar.x, y: halfHeight, z: planar.z),
        .init(x: planar.x, y: -halfHeight, z: planar.z),
      ]
      if !full {
        for cut in [start, start + sweep] {
          let radius = clamped(hint.x * cos(cut) + hint.z * sin(cut), inner, outer)
          boundary.append(.init(x: radius * cos(cut), y: y, z: radius * sin(cut)))
        }
      }
      closest = nearest(boundary, to: hint)
      let middleRadius = (inner + outer) / 2
      var angles: [Double] = []
      if full {
        for index in 0..<8 {
          let offset: Double = Double(index) * Double.pi / 4.0
          angles.append(start + offset)
        }
      } else {
        for index in 0..<5 {
          let offset: Double = sweep * Double(index) / 4.0
          angles.append(start + offset)
        }
      }
      for angle in angles {
        for radius in [inner, outer] {
          samples.append(.init(x: radius * cos(angle), y: 0, z: radius * sin(angle)))
        }
        for y in [-halfHeight, halfHeight] {
          samples.append(.init(x: middleRadius * cos(angle), y: y, z: middleRadius * sin(angle)))
        }
      }
      if !full {
        for cut in [start, start + sweep] {
          samples.append(.init(x: middleRadius * cos(cut), y: 0, z: middleRadius * sin(cut)))
        }
        for angle in [start + sweep / 4, start + 3 * sweep / 4] {
          for radius in [inner, outer] {
            for y in [-halfHeight, halfHeight] {
              samples.append(.init(x: radius * cos(angle), y: y, z: radius * sin(angle)))
            }
          }
        }
      }
    }
    guard closest.isFinite else { return [] }
    var result = [closest]
    let ordered = samples.enumerated().sorted {
      let a = distance($0.element, to: hint)
      let b = distance($1.element, to: hint)
      return a == b ? $0.offset < $1.offset : a < b
    }
    for (_, point) in ordered where result.count < count && point.isFinite {
      if !result.contains(where: { same($0, point) }) { result.append(point) }
    }
    return result
  }

  private static let directions: [Vector3D] = {
    var result: [Vector3D] = []
    for x in -1...1 {
      for y in -1...1 {
        for z in -1...1 where x != 0 || y != 0 || z != 0 {
          result.append(.init(x: Double(x), y: Double(y), z: Double(z)))
        }
      }
    }
    return result
  }()

  /// Profile sizes are admitted at <=34 vertices including implicit axis caps.
  /// An axis-to-axis edge is internal material, not a candidate surface.
  private static func revolutionPoints(_ contour: [Point2D], hint: Vector3D) -> (
    Vector3D, [Vector3D]
  ) {
    let radial = radialDirection(hint)
    let query = Point2D(x: min(1e9, hypot(hint.x, hint.z)), y: clamped(hint.y, -1e9, 1e9))
    var boundary: [Vector3D] = []
    var samples: [Vector3D] = []
    for index in contour.indices {
      let a = contour[index]
      let b = contour[(index + 1) % contour.count]
      if a.x == 0, b.x == 0 { continue }
      let p = segmentPoint(query, a, b)
      boundary.append(.init(x: radial.x * p.x, y: p.y, z: radial.z * p.x))
      for value in [a, .init(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2), b] {
        for angle in [0.0, .pi / 2, .pi, 3 * .pi / 2] {
          samples.append(.init(x: value.x * cos(angle), y: value.y, z: value.x * sin(angle)))
        }
      }
    }
    return (nearest(boundary, to: hint), samples)
  }

  private static func extrusionPoints(_ profile: [Point2D], depth: Double, hint: Vector3D) -> (
    Vector3D, [Vector3D]
  ) {
    let query = Point2D(x: clamped(hint.x, -1e9, 1e9), y: clamped(hint.y, -1e9, 1e9))
    var boundary: [Vector3D] = []
    var samples: [Vector3D] = []
    var inside = false
    for index in profile.indices {
      let a = profile[index]
      let b = profile[(index + 1) % profile.count]
      let p = segmentPoint(query, a, b)
      boundary.append(.init(x: p.x, y: p.y, z: clamped(hint.z, -depth / 2, depth / 2)))
      if (a.y > query.y) != (b.y > query.y),
        query.x < (b.x - a.x) * (query.y - a.y) / (b.y - a.y) + a.x
      {
        inside.toggle()
      }
      for z in [-depth / 2, depth / 2] {
        samples.append(.init(x: a.x, y: a.y, z: z))
        samples.append(.init(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2, z: z))
      }
    }
    if inside {
      for z in [-depth / 2, depth / 2] { boundary.append(.init(x: query.x, y: query.y, z: z)) }
    }
    if let triangles = try? SpatialProfile3D.triangulation(profile) {
      for index in stride(from: 0, to: triangles.count, by: 3) {
        let a = profile[triangles[index]]
        let b = profile[triangles[index + 1]]
        let c = profile[triangles[index + 2]]
        for z in [-depth / 2, depth / 2] {
          samples.append(.init(x: (a.x + b.x + c.x) / 3, y: (a.y + b.y + c.y) / 3, z: z))
        }
      }
    }
    return (nearest(boundary, to: hint), samples)
  }

  private static func segmentPoint(_ query: Point2D, _ a: Point2D, _ b: Point2D) -> Point2D {
    let dx = b.x - a.x
    let dy = b.y - a.y
    let t = clamped(((query.x - a.x) * dx + (query.y - a.y) * dy) / (dx * dx + dy * dy), 0, 1)
    return .init(x: a.x + t * dx, y: a.y + t * dy)
  }

  private static func boxPoint(
    _ hint: Vector3D, half: Vector3D, inner: Vector3D, chamfer: Double
  ) -> Vector3D {
    let center = Vector3D(
      x: clamped(hint.x, -inner.x, inner.x), y: clamped(hint.y, -inner.y, inner.y),
      z: clamped(hint.z, -inner.z, inner.z))
    let delta = Vector3D(x: hint.x - center.x, y: hint.y - center.y, z: hint.z - center.z)
    if delta != .zero {
      let unit = normalized(delta, fallback: .init(x: 1, y: 0, z: 0))
      return .init(
        x: center.x + unit.x * chamfer, y: center.y + unit.y * chamfer,
        z: center.z + unit.z * chamfer)
    }
    let distances = [half.x - abs(hint.x), half.y - abs(hint.y), half.z - abs(hint.z)]
    let axis = distances.indices.min { distances[$0] < distances[$1] } ?? 0
    var point = hint
    switch axis {
    case 0: point.x = hint.x < 0 ? -half.x : half.x
    case 1: point.y = hint.y < 0 ? -half.y : half.y
    default: point.z = hint.z < 0 ? -half.z : half.z
    }
    return point
  }

  private static func tubeAngle(_ hint: Vector3D, start: Double, sweep: Double, full: Bool)
    -> Double
  {
    guard hint.x != 0 || hint.z != 0 else { return full ? start : start + sweep / 2 }
    let angle = atan2(hint.z, hint.x)
    if full || positiveAngle(angle - start) <= sweep { return angle }
    let radial = radialDirection(hint)
    let a = radial.x * cos(start) + radial.z * sin(start)
    let b = radial.x * cos(start + sweep) + radial.z * sin(start + sweep)
    return a >= b ? start : start + sweep
  }

  private static func tubePlanarPoint(
    _ hint: Vector3D, inner: Double, outer: Double, start: Double, sweep: Double, full: Bool
  ) -> Vector3D {
    let angle = atan2(hint.z, hint.x)
    if (hint.x == 0 && hint.z == 0) || full || positiveAngle(angle - start) <= sweep {
      let selected = tubeAngle(hint, start: start, sweep: sweep, full: full)
      let radius = clamped(hypot(hint.x, hint.z), inner, outer)
      return .init(x: radius * cos(selected), y: 0, z: radius * sin(selected))
    }
    return nearest(
      [start, start + sweep].map { angle in
        let radius = clamped(hint.x * cos(angle) + hint.z * sin(angle), inner, outer)
        return .init(x: radius * cos(angle), y: 0, z: radius * sin(angle))
      }, to: .init(x: hint.x, y: 0, z: hint.z))
  }

  private static func radialDirection(_ hint: Vector3D) -> Vector3D {
    normalized(.init(x: hint.x, y: 0, z: hint.z), fallback: .init(x: 1, y: 0, z: 0))
  }
  private static func normalized(_ value: Vector3D, fallback: Vector3D) -> Vector3D {
    let scale = max(abs(value.x), max(abs(value.y), abs(value.z)))
    guard scale > 0, scale.isFinite else { return fallback }
    let a = Vector3D(x: value.x / scale, y: value.y / scale, z: value.z / scale)
    let length = hypot(hypot(a.x, a.y), a.z)
    return .init(x: a.x / length, y: a.y / length, z: a.z / length)
  }
  private static func scaled(_ point: Vector3D, by value: Double) -> Vector3D {
    .init(x: point.x * value, y: point.y * value, z: point.z * value)
  }
  private static func nearest(_ points: [Vector3D], to hint: Vector3D) -> Vector3D {
    points.enumerated().min {
      let a = distance($0.element, to: hint)
      let b = distance($1.element, to: hint)
      return a == b ? $0.offset < $1.offset : a < b
    }?.element ?? .zero
  }
  /// A shared scaling factor keeps ordering finite even for extreme finite hints.
  private static func distance(_ point: Vector3D, to hint: Vector3D) -> Double {
    let scale = max(1, max(abs(hint.x), max(abs(hint.y), abs(hint.z))))
    let x = point.x / scale - hint.x / scale
    let y = point.y / scale - hint.y / scale
    let z = point.z / scale - hint.z / scale
    return x * x + y * y + z * z
  }
  private static func same(_ a: Vector3D, _ b: Vector3D) -> Bool {
    abs(a.x - b.x) <= 1e-9 && abs(a.y - b.y) <= 1e-9 && abs(a.z - b.z) <= 1e-9
  }
  private static func sign(_ value: Double) -> Double { value < 0 ? -1 : value > 0 ? 1 : 0 }
  private static func clamped(_ value: Double, _ low: Double, _ high: Double) -> Double {
    min(high, max(low, value))
  }
  private static func positiveAngle(_ angle: Double) -> Double {
    let value = angle.truncatingRemainder(dividingBy: .pi * 2)
    return value < 0 ? value + .pi * 2 : value
  }
}
