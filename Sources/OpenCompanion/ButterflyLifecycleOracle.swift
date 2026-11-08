import CompanionCore
import Foundation
import simd

/// Fixed-public-case admission, not runtime biological classification or a pixel oracle.
/// Four distinct stages: https://www.floridamuseum.ufl.edu/educators/resource/butterfly-life-cycle/
/// Segmentation, head/thorax/abdomen and two wing pairs:
/// https://dnr.illinois.gov/education/wildaboutpages/wildaboutinvertebrates/wildaboutbutterflies.html
/// Labels identify roles; they cannot substitute for the geometric checks below.
enum ButterflyLifecycleOracle {
  private enum Stage: Int, CaseIterable {
    case egg, larva, pupa, adult

    static func identified(in text: String) -> Stage? {
      for word in text.lowercased().split(whereSeparator: { !$0.isLetter }) {
        switch word {
        case "egg", "eggs": return .egg
        case "larva", "larvae", "caterpillar": return .larva
        case "pupa", "pupae", "chrysalis": return .pupa
        case "adult", "butterfly": return .adult
        default: continue
        }
      }
      return nil
    }
  }

  private struct Part {
    let pose: ScenePose3D
    let geometry: Geometry3D
    let center: SIMD3<Double>
    let vectors: [SIMD3<Double>]
    let lengths: [Double]

    var radius: Double { lengths.max() ?? 0 }
    var orderedLengths: [Double] { lengths.sorted() }
    var longAxis: SIMD3<Double> {
      let index = lengths.indices.max { lengths[$0] < lengths[$1] } ?? 0
      return vectors[index] / max(lengths[index], 1e-12)
    }
    var rounded: Bool {
      switch geometry {
      case .sphere, .capsule, .lathe: return true
      default: return false
      }
    }
    var wing: Bool {
      let size = orderedLengths
      guard size[0] < size[1] * 0.45 else { return false }
      switch geometry {
      case .sphere, .extrusion, .lathe: return true
      default: return false
      }
    }
  }

  static func unmetChecks(document: SceneDocument) -> [String] {
    guard (try? document.validated()) != nil,
      let poses = try? document.spatialWorldPoses(at: 0)
    else { return ["content-schema"] }
    let lookup = Dictionary(uniqueKeysWithValues: document.nodes.map { ($0.id, $0) })
    let parts = poses.compactMap(makePart)
    let labels = document.nodes.filter {
      $0.kind == .text && $0.opacity > 0 && visibleColor($0.color)
        && $0.spatial3D?.labelAnchor != nil
    }.sorted { $0.id < $1.id }
    var targets: [Stage: String] = [:]
    var roleLabels: [Stage: [SceneNode]] = [:]
    for label in labels {
      guard let stage = Stage.identified(in: label.text),
        let target = label.spatial3D?.labelAnchor?.targetID
      else { continue }
      if let existing = targets[stage], existing != target {
        // Multiple labels may name parts in one assembly. Its stage anchor is
        // the first stable-ID label, independent of dictionary iteration.
        continue
      }
      targets[stage] = target
      roleLabels[stage, default: []].append(label)
    }
    guard targets.count == 4, Set(targets.values).count == 4 else {
      return ["butterfly-four-stage-roles"]
    }
    var centers: [Stage: SIMD3<Double>] = [:]
    for stage in Stage.allCases {
      guard let target = targets[stage] else { continue }
      let members = parts.filter { descends($0.pose.node.id, from: target, lookup: lookup) }
      guard !members.isEmpty else { return ["butterfly-four-stage-roles"] }
      centers[stage] =
        members.reduce(SIMD3<Double>.zero) { $0 + $1.center }
        / Double(members.count)
    }
    let stageCenters = Stage.allCases.compactMap { centers[$0] }
    guard stageCenters.count == 4 else { return ["butterfly-four-stage-roles"] }
    let separation = minimumSeparation(stageCenters)
    guard separation.isFinite, separation > 1e-5 else {
      return ["butterfly-distinct-stage-assemblies"]
    }
    var assemblies: [Stage: [Part]] = [:]
    for part in parts {
      let owners = Stage.allCases.filter { stage in
        guard let target = targets[stage] else { return false }
        // Prefer an exclusive enclosing group; a shared world root is not an
        // assembly and cannot give the same mesh four semantic roles.
        var owner = target
        for _ in 0..<32 {
          guard let parent = lookup[owner]?.parentID,
            !Stage.allCases.contains(where: { other in
              other != stage
                && targets[other].map {
                  descends($0, from: parent, lookup: lookup)
                } == true
            })
          else { break }
          owner = parent
        }
        return descends(part.pose.node.id, from: owner, lookup: lookup)
      }
      if owners.count == 1, let owner = owners.first {
        assemblies[owner, default: []].append(part)
      } else if owners.isEmpty,
        let nearest = Stage.allCases.min(by: {
          simd_distance_squared(part.center, centers[$0]!)
            < simd_distance_squared(part.center, centers[$1]!)
        }), simd_distance(part.center, centers[nearest]!) < separation * 0.7
      {
        assemblies[nearest, default: []].append(part)
      }
    }
    var unmet: [String] = []
    if !separatedAssemblies(assemblies, centers: centers) {
      unmet.append("butterfly-distinct-stage-assemblies")
    }
    if !egg(assemblies[.egg] ?? []) { unmet.append("butterfly-egg-form") }
    if !segmentedLarva(assemblies[.larva] ?? []) {
      unmet.append("butterfly-segmented-larva")
    }
    if !pupa(assemblies[.pupa] ?? []) { unmet.append("butterfly-pupa-form") }
    let adult = assemblies[.adult] ?? []
    if !adultStructure(adult) { unmet.append("butterfly-adult-head-and-body") }
    if !adultWings(adult) { unmet.append("butterfly-adult-wing-silhouette") }
    let numbered = Stage.allCases.allSatisfy { stage in
      roleLabels[stage, default: []].contains { label in
        let numbers = label.text.split { !$0.isNumber }.compactMap { Int($0) }
        return numbers.first == stage.rawValue + 1
      }
    }
    if !numbered && !directedCycle(parts: parts, centers: centers) {
      unmet.append("butterfly-visible-progression")
    }
    // Geometry cannot establish visual recognisability, species accuracy,
    // label readability, or direction legibility in the rendered camera.
    return unmet
  }

  private static func egg(_ parts: [Part]) -> Bool {
    parts.contains {
      let sizes = $0.orderedLengths
      return $0.rounded && sizes[2] <= sizes[0] * 2.5
    }
  }

  private static func segmentedLarva(_ parts: [Part]) -> Bool {
    let rounded = parts.filter {
      let sizes = $0.orderedLengths
      return $0.rounded && sizes[2] <= sizes[0] * 3
    }
    let thickness = rounded.map { $0.orderedLengths[1] }.max() ?? 0
    // Eyes or tiny surface beads cannot pad a smooth body's segment count.
    let body = rounded.filter { $0.orderedLengths[1] >= thickness * 0.4 }
    // A single turned surface may express actual repeated body lobes, unlike
    // a smooth capsule with a caterpillar label.
    for part in parts {
      if case .lathe(let profile, _) = part.geometry, profile.count >= 7 {
        var peaks = 0
        for i in 1..<(profile.count - 1) {
          if profile[i].radius > max(profile[i - 1].radius, profile[i + 1].radius) * 1.12 {
            peaks += 1
          }
        }
        if peaks >= 3, part.orderedLengths[2] > part.orderedLengths[1] * 2 {
          return true
        }
      }
    }
    guard body.count >= 4 else { return false }
    var pair: (Part, Part)?
    var span = 0.0
    for i in body.indices {
      for j in body.indices where j > i {
        let distance = simd_distance(body[i].center, body[j].center)
        if distance > span {
          span = distance
          pair = (body[i], body[j])
        }
      }
    }
    guard let pair, span > 0 else { return false }
    let axis = (pair.1.center - pair.0.center) / span
    let sizes = body.map { $0.orderedLengths[1] }.sorted()
    let median = sizes[sizes.count / 2]
    guard span >= median * 3 else { return false }
    let aligned = body.filter {
      let offset = $0.center - pair.0.center
      return simd_length(offset - axis * simd_dot(offset, axis)) <= median * 1.3
    }
    guard aligned.count >= 4 else { return false }
    let ordered = aligned.sorted {
      simd_dot($0.center, axis) < simd_dot($1.center, axis)
    }
    for index in 1..<ordered.count {
      let distance = simd_distance(ordered[index - 1].center, ordered[index].center)
      if distance < median * 0.25
        || distance > (ordered[index - 1].radius + ordered[index].radius) * 1.3
      {
        return false
      }
    }
    return true
  }

  private static func pupa(_ parts: [Part]) -> Bool {
    let bulk = parts.filter { part in
      if case .cone = part.geometry { return true }
      return part.rounded
    }
    let largest = bulk.map(\.radius).max() ?? 0
    return bulk.contains { part in
      guard part.radius >= largest * 0.4,
        part.orderedLengths[2] >= part.orderedLengths[1] * 1.4
      else { return false }
      if case .lathe(let profile, _) = part.geometry, profile.count >= 4,
        let maximum = profile.map(\.radius).max(), let first = profile.first,
        let last = profile.last
      {
        return maximum > max(first.radius, last.radius) * 1.3
      }
      guard case .cone(let top, let bottom, _, _) = part.geometry,
        min(top, bottom) < max(top, bottom) * 0.7
      else { return false }
      // A substantial native taper can stand alone or join a rounded body;
      // neither a tiny remote detail nor unrelated extra mesh supplies taper.
      return bulk.allSatisfy { other in
        if other.pose.node.id == part.pose.node.id || other.radius < largest * 0.4 { return true }
        return simd_distance(other.center, part.center) <= (other.radius + part.radius) * 1.2
          && abs(simd_dot(other.longAxis, part.longAxis)) > 0.8
      }
    }
  }

  private static func adultBody(_ parts: [Part]) -> Part? {
    parts.filter {
      $0.rounded && !$0.wing && $0.orderedLengths[2] >= $0.orderedLengths[1] * 2
    }.max { $0.radius < $1.radius }
  }

  private static func adultStructure(_ parts: [Part]) -> Bool {
    guard let body = adultBody(parts) else { return false }
    return parts.contains { head in
      let sizes = head.orderedLengths
      guard head.pose.node.id != body.pose.node.id, head.rounded,
        sizes[2] <= sizes[0] * 1.8, head.radius <= body.radius * 0.65,
        head.radius >= body.orderedLengths[1] * 0.35
      else { return false }
      let offset = head.center - body.center
      let along = abs(simd_dot(offset, body.longAxis))
      let across = simd_length(offset - body.longAxis * simd_dot(offset, body.longAxis))
      return along >= body.radius * 0.65 && along <= body.radius + head.radius * 1.5
        && across <= body.orderedLengths[1] + head.radius
    }
  }

  private static func adultWings(_ parts: [Part]) -> Bool {
    guard let body = adultBody(parts) else { return false }
    let wings = parts.filter {
      $0.wing && $0.orderedLengths[1] >= body.radius * 0.4
        && simd_distance($0.center, body.center) <= $0.radius + body.radius
    }
    guard wings.count >= 2 else { return false }
    let across = wings.map { wing -> SIMD3<Double> in
      let offset = wing.center - body.center
      return offset - body.longAxis * simd_dot(offset, body.longAxis)
    }
    guard let largest = across.max(by: { simd_length_squared($0) < simd_length_squared($1) }),
      simd_length(largest) > body.orderedLengths[1] * 0.5
    else { return false }
    let side = largest / simd_length(largest)
    let left = wings.filter {
      simd_dot($0.center - body.center, side) < -body.orderedLengths[1] * 0.3
    }
    let right = wings.filter {
      simd_dot($0.center - body.center, side) > body.orderedLengths[1] * 0.3
    }
    func differentiated(_ values: [Part]) -> Bool {
      if values.contains(where: { compoundWing($0.geometry) }) { return true }
      guard values.count >= 2 else { return false }
      let coordinates = values.map { simd_dot($0.center - body.center, body.longAxis) }
      return (coordinates.max() ?? 0) - (coordinates.min() ?? 0) >= body.radius * 0.3
    }
    return differentiated(left) && differentiated(right)
  }

  private static func compoundWing(_ geometry: Geometry3D) -> Bool {
    guard case .extrusion(let source, _, let rounding) = geometry,
      let profile = try? SpatialProfile3D.extrusionContour(source, cornerRounding: rounding),
      profile.count >= 6
    else { return false }
    let scale = max(
      (profile.map(\.x).max() ?? 0) - (profile.map(\.x).min() ?? 0),
      (profile.map(\.y).max() ?? 0) - (profile.map(\.y).min() ?? 0))
    var positive = 0.0
    var negative = 0.0
    for i in profile.indices {
      let a = profile[(i + profile.count - 1) % profile.count]
      let b = profile[i]
      let c = profile[(i + 1) % profile.count]
      let cross = (b.x - a.x) * (c.y - b.y) - (b.y - a.y) * (c.x - b.x)
      let dot = (b.x - a.x) * (c.x - b.x) + (b.y - a.y) * (c.y - b.y)
      let angle = atan2(cross, dot)
      if angle > 0 { positive += angle } else { negative -= angle }
    }
    let hull = convexHull(profile)
    guard hull.count >= 5, min(positive, negative) >= 0.35 else { return false }
    // Measure the actual outline after optional native corner rounding. Tiny
    // notches or an input notch rounded away cannot claim a fore/hind split.
    return profile.contains { point in
      var nearest = Double.infinity
      for index in hull.indices {
        let a = hull[index]
        let b = hull[(index + 1) % hull.count]
        let dx = b.x - a.x
        let dy = b.y - a.y
        let squared = dx * dx + dy * dy
        guard squared > 0 else { continue }
        let t = min(1, max(0, ((point.x - a.x) * dx + (point.y - a.y) * dy) / squared))
        nearest = min(nearest, hypot(point.x - a.x - t * dx, point.y - a.y - t * dy))
      }
      return nearest >= scale * 0.06
    }
  }

  private static func convexHull(_ values: [Point2D]) -> [Point2D] {
    let ordered = values.sorted { $0.x == $1.x ? $0.y < $1.y : $0.x < $1.x }
    func cross(_ a: Point2D, _ b: Point2D, _ c: Point2D) -> Double {
      (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)
    }
    var lower: [Point2D] = []
    var upper: [Point2D] = []
    for point in ordered {
      while lower.count >= 2 && cross(lower[lower.count - 2], lower[lower.count - 1], point) <= 0 {
        lower.removeLast()
      }
      lower.append(point)
    }
    for point in ordered.reversed() {
      while upper.count >= 2 && cross(upper[upper.count - 2], upper[upper.count - 1], point) <= 0 {
        upper.removeLast()
      }
      upper.append(point)
    }
    return Array(lower.dropLast()) + Array(upper.dropLast())
  }

  private static func directedCycle(parts: [Part], centers: [Stage: SIMD3<Double>]) -> Bool {
    for stage in Stage.allCases {
      let next = Stage(rawValue: (stage.rawValue + 1) % 4)!
      let start = centers[stage]!
      let end = centers[next]!
      let distance = simd_distance(start, end)
      let axis = (end - start) / distance
      let found = parts.contains { part in
        guard case .cone(let top, let bottom, _, _) = part.geometry,
          min(top, bottom) < max(top, bottom) * 0.2
        else { return false }
        let vector = part.vectors[1] * (top < bottom ? 1.0 : -1.0)
        guard simd_length(vector) > 0,
          simd_dot(vector / simd_length(vector), axis) > 0.75
        else { return false }
        let offset = part.center - start
        let fraction = simd_dot(offset, axis) / distance
        return (0.15...0.9).contains(fraction)
          && simd_length(offset - axis * simd_dot(offset, axis)) < distance * 0.25
      }
      if !found { return false }
    }
    return true
  }

  private static func descends(_ id: String, from ancestor: String, lookup: [String: SceneNode])
    -> Bool
  {
    var current: String? = id
    for _ in 0...32 {
      guard let value = current else { return false }
      if value == ancestor { return true }
      current = lookup[value]?.parentID
    }
    return false
  }

  private static func minimumSeparation(_ values: [SIMD3<Double>]) -> Double {
    var result = Double.infinity
    for i in values.indices {
      for j in values.indices where j > i {
        result = min(result, simd_distance(values[i], values[j]))
      }
    }
    return result
  }

  private static func separatedAssemblies(
    _ assemblies: [Stage: [Part]], centers: [Stage: SIMD3<Double>]
  ) -> Bool {
    for stage in Stage.allCases {
      for other in Stage.allCases where other.rawValue > stage.rawValue {
        guard let first = centers[stage], let second = centers[other] else { return false }
        let distance = simd_distance(first, second)
        guard distance > 1e-5 else { return false }
        let axis = (second - first) / distance
        func interval(_ parts: [Part]) -> (Double, Double)? {
          guard !parts.isEmpty else { return nil }
          var low = Double.infinity
          var high = -Double.infinity
          for part in parts {
            let extent = part.vectors.reduce(0.0) { $0 + abs(simd_dot($1, axis)) }
            let position = simd_dot(part.center, axis)
            low = min(low, position - extent)
            high = max(high, position + extent)
          }
          return (low, high)
        }
        guard let a = interval(assemblies[stage] ?? []),
          let b = interval(assemblies[other] ?? [])
        else { return false }
        let tolerance = min(a.1 - a.0, b.1 - b.0) * 0.1
        if a.1 > b.0 + tolerance { return false }
      }
    }
    return true
  }

  private static func makePart(_ pose: ScenePose3D) -> Part? {
    guard pose.node.kind == .mesh, pose.effectiveOpacity > 0, visibleColor(pose.node.fill),
      let geometry = pose.node.spatial3D?.geometry
    else { return nil }
    let low: SIMD3<Double>
    let high: SIMD3<Double>
    switch geometry {
    case .box(let w, let h, let d, _):
      high = .init(w / 2, h / 2, d / 2)
      low = -high
    case .sphere(let r, _):
      high = .init(repeating: r)
      low = -high
    case .cylinder(let r, let h, _), .capsule(let r, let h, _):
      high = .init(r, h / 2, r)
      low = -high
    case .cone(let top, let bottom, let h, _):
      high = .init(max(top, bottom), h / 2, max(top, bottom))
      low = -high
    case .torus(let ring, let pipe, _, _):
      high = .init(ring + pipe, pipe, ring + pipe)
      low = -high
    case .tube(_, let r, let h, _, _, _):
      high = .init(r, h / 2, r)
      low = -high
    case .lathe(let profile, _):
      let r = profile.map(\.radius).max() ?? 0
      low = .init(-r, profile.map(\.y).min() ?? 0, -r)
      high = .init(r, profile.map(\.y).max() ?? 0, r)
    case .extrusion(let source, let depth, let rounding):
      guard let profile = try? SpatialProfile3D.extrusionContour(source, cornerRounding: rounding)
      else { return nil }
      low = .init(profile.map(\.x).min() ?? 0, profile.map(\.y).min() ?? 0, -depth / 2)
      high = .init(profile.map(\.x).max() ?? 0, profile.map(\.y).max() ?? 0, depth / 2)
    }
    func point(_ value: SIMD3<Double>) -> SIMD3<Double> {
      let result = pose.transform.applying(to: .init(x: value.x, y: value.y, z: value.z))
      return .init(result.x, result.y, result.z)
    }
    let center = point((low + high) / 2)
    let half = (high - low) / 2
    let vectors = [
      point((low + high) / 2 + .init(half.x, 0, 0)) - center,
      point((low + high) / 2 + .init(0, half.y, 0)) - center,
      point((low + high) / 2 + .init(0, 0, half.z)) - center,
    ]
    return Part(
      pose: pose, geometry: geometry, center: center, vectors: vectors,
      lengths: vectors.map { simd_length($0) })
  }

  private static func visibleColor(_ text: String) -> Bool {
    let value = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if value == "transparent" { return false }
    if value.hasPrefix("#"), value.count == 9, let alpha = UInt8(value.suffix(2), radix: 16) {
      return alpha > 0
    }
    return true
  }
}
