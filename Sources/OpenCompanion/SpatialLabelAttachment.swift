import AppKit
import CompanionCore
import SceneKit
import simd

/// Canonical requested coordinates are retained separately from host-verified
/// presentation endpoints. A resolved endpoint is a real closest triangle hit.
struct SpatialLabelAttachment: Codable, Equatable, Sendable {
  enum Status: String, Codable, Sendable {
    case requestedProjection, surfaceSearch, occluded, unresolved, noGeometry, missingTarget
    case budgetExhausted
    case staleGeneration
  }
  let labelID: String
  let targetID: String
  let requestedLocal: Vector3D
  let requestedWorld: Vector3D?
  let resolvedTargetLocal: Vector3D?
  let resolvedGeometryLocal: Vector3D?
  let resolvedWorld: Vector3D?
  let surfaceNodeID: String?
  let status: Status
  var reusedCachedSurface: Bool
  var rayTests: Int
  var candidateTests: Int
  var isResolved: Bool { resolvedWorld != nil && surfaceNodeID != nil }
}

struct SpatialLabelAttachmentDiagnostics: Codable, Sendable {
  let contextChanges: Int
  let rayTestsThisLayout: Int
  let candidateTestsThisLayout: Int
  let totalRayTests: Int
  let totalCacheHits: Int
  let unresolvedCount: Int
  let pendingCount: Int
}

@MainActor final class SpatialLabelAttachmentResolver {
  struct Request: Equatable {
    let labelID: String
    let anchor: LabelAnchor3D
  }
  static let maximumCandidatesPerLabel = 32
  static let maximumRayTestsPerLayout = 512

  private struct NodeStamp: Equatable {
    let id: String
    let object: ObjectIdentifier
    let geometry: ObjectIdentifier?
    let parent: ObjectIdentifier?
    let matrix: [Float]
    let opacity: Double
    let hidden: Bool
    let materialAlpha: Double
  }
  private struct Context: Equatable {
    let documentID: String
    let generation: UInt64
    let viewport: CGRect
    let window: ObjectIdentifier?
    let windowVisible: Bool
    let windowOcclusionVisible: Bool
    let stageHidden: Bool
    let camera: ObjectIdentifier?
    let cameraMatrix: [Float]
    let lens: [Double]
    let nodes: [NodeStamp]
  }
  private struct Entry {
    let anchor: LabelAnchor3D
    let target: ObjectIdentifier?
    let geometry: ObjectIdentifier?
    let contextToken: UUID
    let attachment: SpatialLabelAttachment
    let lastAttempt: UInt64
  }
  private struct Hit {
    let result: SCNHitTestResult
    let nodeID: String
  }
  private var entries: [String: Entry] = [:]
  private var context: Context?
  private var contextToken = UUID()
  private var contextChanges = 0
  private var rays = 0
  private var rayLimit = maximumRayTestsPerLayout
  private var candidates = 0
  private var totalRays = 0
  private var totalCacheHits = 0
  private var unresolved = 0
  private var pending = 0
  private var attemptSequence: UInt64 = 0
  var hasPendingWork: Bool { pending > 0 }

  var diagnostics: SpatialLabelAttachmentDiagnostics {
    .init(
      contextChanges: contextChanges, rayTestsThisLayout: rays,
      candidateTestsThisLayout: candidates, totalRayTests: totalRays,
      totalCacheHits: totalCacheHits, unresolvedCount: unresolved, pendingCount: pending)
  }

  func reset() {
    entries.removeAll(keepingCapacity: true)
    context = nil
    contextToken = UUID()
    rays = 0
    candidates = 0
    unresolved = 0
    pending = 0
    attemptSequence = 0
  }

  /// One native visibility edge may follow an early same-context hit miss.
  /// Keep verified surfaces, but let that owned edge recheck negative results.
  /// This does not schedule work or create a retry loop.
  func invalidateTransientMisses() {
    for id in Array(entries.keys) where entries[id]?.attachment.isResolved != true {
      entries.removeValue(forKey: id)
    }
  }

  func resolve(
    _ requests: [Request], documentID: String, generation: UInt64, stage: SCNView,
    nodes: [String: SCNNode], geometries: [String: Geometry3D],
    effectiveOpacities: [String: Double], rayLimit: Int = maximumRayTestsPerLayout
  ) -> [String: SpatialLabelAttachment] {
    self.rayLimit = min(Self.maximumRayTestsPerLayout, max(0, rayLimit))
    rays = 0
    candidates = 0
    if let context, context.documentID == documentID, generation < context.generation {
      var stale: [String: SpatialLabelAttachment] = [:]
      for request in requests.prefix(128) {
        stale[request.labelID] = unresolved(request, world: nil, status: .staleGeneration)
      }
      return stale
    }
    // The renderer owns these native nodes. Exclude invisible material from
    // ray queries without restricting the query to the requested target.
    var changedMasks = false
    for (id, node) in nodes {
      let mask =
        (effectiveOpacities[id] ?? 0) > 0 && !node.isHidden && materialAlpha(node) > 0 ? 1 : 0
      if node.categoryBitMask != mask {
        node.categoryBitMask = mask
        changedMasks = true
      }
    }
    // Native hit testing must see category changes made in this transaction,
    // including a part that has just become fully transparent.
    if changedMasks { SCNTransaction.flush() }
    let stamp = makeContext(
      documentID: documentID, generation: generation, stage: stage,
      nodes: nodes, effectiveOpacities: effectiveOpacities)
    if context?.documentID != documentID || context?.generation != generation {
      entries.removeAll(keepingCapacity: true)
    }
    if context != stamp {
      context = stamp
      contextToken = UUID()
      contextChanges = min(1_000_000, contextChanges + 1)
    }
    // Preserve fair service even when an animated camera/part changes the
    // context every frame. Static-context terminal entries still cost no rays.
    let requests = Array(requests.prefix(128)).sorted {
      let lhs = entries[$0.labelID]?.lastAttempt ?? 0
      let rhs = entries[$1.labelID]?.lastAttempt ?? 0
      return lhs == rhs ? $0.labelID < $1.labelID : lhs < rhs
    }
    let ids = Set(requests.map(\.labelID))
    for id in Array(entries.keys) where !ids.contains(id) { entries.removeValue(forKey: id) }
    var nativeIDs: [ObjectIdentifier: String] = [:]
    for id in nodes.keys.sorted() {
      if let node = nodes[id], nativeIDs[ObjectIdentifier(node)] == nil {
        nativeIDs[ObjectIdentifier(node)] = id
      }
    }
    var result: [String: SpatialLabelAttachment] = [:]
    for request in requests where result[request.labelID] == nil {
      let target = nodes[request.anchor.targetID]
      let targetID = target.map(ObjectIdentifier.init)
      if let entry = entries[request.labelID], entry.anchor == request.anchor,
        entry.target == targetID, entry.contextToken == contextToken,
        entry.attachment.status != .budgetExhausted
      {
        var attachment = entry.attachment
        attachment.reusedCachedSurface = true
        attachment.rayTests = 0
        attachment.candidateTests = 0
        result[request.labelID] = attachment
        totalCacheHits = min(1_000_000, totalCacheHits + 1)
        continue
      }
      let beforeRays = rays
      let beforeCandidates = candidates
      var attachment = resolveOne(
        request, target: target, stage: stage, nodes: nodes, geometries: geometries,
        nativeIDs: nativeIDs, effectiveOpacities: effectiveOpacities)
      attachment.rayTests = rays - beforeRays
      attachment.candidateTests = candidates - beforeCandidates
      let priorAttempt = entries[request.labelID]?.lastAttempt ?? 0
      if attachment.rayTests > 0 { attemptSequence &+= 1 }
      result[request.labelID] = attachment
      let geometry = attachment.surfaceNodeID.flatMap { nodes[$0]?.geometry }.map(
        ObjectIdentifier.init)
      entries[request.labelID] = Entry(
        anchor: request.anchor, target: targetID, geometry: geometry,
        contextToken: contextToken, attachment: attachment,
        lastAttempt: attachment.rayTests > 0 ? attemptSequence : priorAttempt)
    }
    unresolved = result.values.filter { !$0.isResolved }.count
    pending = result.values.filter { $0.status == .budgetExhausted }.count
    return result
  }

  /// Cached attachments may be borrowed only under the exact native context
  /// which verified them. This performs no triangle queries or cache mutation.
  func isCurrentContext(
    documentID: String, generation: UInt64, stage: SCNView,
    nodes: [String: SCNNode], effectiveOpacities: [String: Double]
  ) -> Bool {
    context
      == makeContext(
        documentID: documentID, generation: generation, stage: stage,
        nodes: nodes, effectiveOpacities: effectiveOpacities)
  }

  private func resolveOne(
    _ request: Request, target: SCNNode?, stage: SCNView, nodes: [String: SCNNode],
    geometries: [String: Geometry3D], nativeIDs: [ObjectIdentifier: String],
    effectiveOpacities: [String: Double]
  ) -> SpatialLabelAttachment {
    let point = request.anchor.point
    guard let target, point.isFinite, (effectiveOpacities[request.anchor.targetID] ?? 0) > 0 else {
      return unresolved(request, world: nil, status: .missingTarget)
    }
    let requested = target.convertPosition(native(point), to: nil)
    guard finite(requested) else { return unresolved(request, world: nil, status: .unresolved) }
    let world = vector(requested)
    var blocked = false
    if let entry = entries[request.labelID], entry.anchor == request.anchor,
      entry.target == ObjectIdentifier(target), let id = entry.attachment.surfaceNodeID,
      let mesh = nodes[id], let geometry = mesh.geometry,
      entry.geometry == ObjectIdentifier(geometry),
      let local = entry.attachment.resolvedGeometryLocal
    {
      let retainedWorld = mesh.convertPosition(native(local), to: nil)
      if let hit = closestHit(
        world: retainedWorld, stage: stage, nativeIDs: nativeIDs,
        effectiveOpacities: effectiveOpacities), belongs(hit.result.node, to: target)
      {
        return verified(
          request, requestedWorld: world, hit: hit, target: target,
          status: entry.attachment.status, reused: true)
      }
    }
    if let hit = closestHit(
      world: requested, stage: stage, nativeIDs: nativeIDs, effectiveOpacities: effectiveOpacities)
    {
      if belongs(hit.result.node, to: target) {
        return verified(
          request, requestedWorld: world, hit: hit, target: target, status: .requestedProjection)
      }
      blocked = true
    }
    let descendants = geometries.keys.sorted().compactMap { id -> (String, SCNNode, Geometry3D)? in
      guard let node = nodes[id], let geometry = geometries[id], belongs(node, to: target) else {
        return nil
      }
      return (id, node, geometry)
    }
    guard !descendants.isEmpty else {
      return unresolved(request, world: world, status: .noGeometry)
    }
    var samples: [(SCNNode, Vector3D)] = []
    let selected = descendants.prefix(Self.maximumCandidatesPerLabel)
    let perMesh = max(1, Self.maximumCandidatesPerLabel / selected.count)
    for (_, node, geometry) in selected {
      let localHint = node.convertPosition(requested, from: nil)
      for sample in SpatialSurfaceCandidates.points(
        for: geometry, hint: vector(localHint), limit: perMesh)
      {
        if samples.count == Self.maximumCandidatesPerLabel { break }
        samples.append((node, sample))
      }
    }
    let preferred = projected(requested, in: stage)
    var best: Hit?
    var bestDistance = Double.infinity
    var exhaustedBudget = false
    for (node, sample) in samples {
      guard rays < rayLimit else {
        exhaustedBudget = true
        break
      }
      candidates += 1
      let sampleWorld = node.convertPosition(native(sample), to: nil)
      guard
        let hit = closestHit(
          world: sampleWorld, stage: stage, nativeIDs: nativeIDs,
          effectiveOpacities: effectiveOpacities)
      else { continue }
      guard belongs(hit.result.node, to: target) else {
        blocked = true
        continue
      }
      let p = projected(hit.result.worldCoordinates, in: stage)
      let distance: Double
      if let preferred, let p {
        distance = Double(pow(p.x - preferred.x, 2) + pow(p.y - preferred.y, 2))
      } else {
        let delta =
          hit.result.simdWorldCoordinates
          - simd_float3(Float(requested.x), Float(requested.y), Float(requested.z))
        distance = Double(simd_length_squared(delta))
      }
      if distance < bestDistance {
        best = hit
        bestDistance = distance
      }
    }
    if let best {
      return verified(
        request, requestedWorld: world, hit: best, target: target, status: .surfaceSearch)
    }
    return unresolved(
      request, world: world,
      status: exhaustedBudget
        ? .budgetExhausted : (blocked ? .occluded : .unresolved))
  }

  private func closestHit(
    world: SCNVector3, stage: SCNView, nativeIDs: [ObjectIdentifier: String],
    effectiveOpacities: [String: Double]
  ) -> Hit? {
    guard rays < rayLimit, let point = projected(world, in: stage) else {
      return nil
    }
    rays += 1
    totalRays = min(1_000_000, totalRays + 1)
    // Never restrict rootNode to the target: another part may occlude it.
    guard
      let hit = stage.hitTest(
        point,
        options: [
          .searchMode: SCNHitTestSearchMode.closest.rawValue, .boundingBoxOnly: false,
          .clipToZRange: true, .backFaceCulling: true, .ignoreHiddenNodes: true,
          .categoryBitMask: 1,
        ]
      ).first,
      let id = nativeIDs[ObjectIdentifier(hit.node)],
      (effectiveOpacities[id] ?? 0) > 0, materialAlpha(hit.node) > 0,
      finite(hit.worldCoordinates), finite(hit.localCoordinates)
    else { return nil }
    return Hit(result: hit, nodeID: id)
  }

  private func verified(
    _ request: Request, requestedWorld: Vector3D, hit: Hit, target: SCNNode,
    status: SpatialLabelAttachment.Status, reused: Bool = false
  ) -> SpatialLabelAttachment {
    .init(
      labelID: request.labelID, targetID: request.anchor.targetID,
      requestedLocal: request.anchor.point, requestedWorld: requestedWorld,
      resolvedTargetLocal: vector(target.convertPosition(hit.result.worldCoordinates, from: nil)),
      resolvedGeometryLocal: vector(hit.result.localCoordinates),
      resolvedWorld: vector(hit.result.worldCoordinates),
      surfaceNodeID: hit.nodeID, status: status, reusedCachedSurface: reused, rayTests: 0,
      candidateTests: 0)
  }
  private func unresolved(
    _ request: Request, world: Vector3D?, status: SpatialLabelAttachment.Status
  ) -> SpatialLabelAttachment {
    .init(
      labelID: request.labelID, targetID: request.anchor.targetID,
      requestedLocal: request.anchor.point,
      requestedWorld: world, resolvedTargetLocal: nil, resolvedGeometryLocal: nil,
      resolvedWorld: nil, surfaceNodeID: nil, status: status, reusedCachedSurface: false,
      rayTests: 0, candidateTests: 0)
  }
  private func projected(_ point: SCNVector3, in stage: SCNView) -> CGPoint? {
    guard finite(point) else { return nil }
    let p = stage.projectPoint(point)
    guard finite(p), p.z >= 0, p.z <= 1 else { return nil }
    let result = CGPoint(x: CGFloat(p.x), y: CGFloat(p.y))
    return stage.bounds.contains(result) ? result : nil
  }
  private func belongs(_ node: SCNNode, to ancestor: SCNNode) -> Bool {
    var current: SCNNode? = node
    for _ in 0..<128 {
      guard let value = current else { return false }
      if value === ancestor { return true }
      current = value.parent
    }
    return false
  }
  private func makeContext(
    documentID: String, generation: UInt64, stage: SCNView,
    nodes: [String: SCNNode], effectiveOpacities: [String: Double]
  ) -> Context {
    let camera = stage.pointOfView
    let lens = camera?.camera
    return .init(
      documentID: documentID, generation: generation, viewport: stage.bounds,
      window: stage.window.map(ObjectIdentifier.init),
      windowVisible: stage.window?.isVisible == true,
      windowOcclusionVisible: stage.window?.occlusionState.contains(.visible) == true,
      stageHidden: stage.isHiddenOrHasHiddenAncestor,
      camera: camera.map(ObjectIdentifier.init),
      cameraMatrix: camera.map { elements($0.simdWorldTransform) } ?? [],
      lens: lens.map {
        let m = $0.projectionTransform
        return [
          Double($0.fieldOfView), $0.zNear, $0.zFar, $0.orthographicScale,
          $0.usesOrthographicProjection ? 1 : 0,
          Double(m.m11), Double(m.m12), Double(m.m13), Double(m.m14),
          Double(m.m21), Double(m.m22), Double(m.m23), Double(m.m24),
          Double(m.m31), Double(m.m32), Double(m.m33), Double(m.m34),
          Double(m.m41), Double(m.m42), Double(m.m43), Double(m.m44),
        ]
      } ?? [],
      nodes: nodes.keys.sorted().compactMap { id in
        guard let node = nodes[id] else { return nil }
        return NodeStamp(
          id: id, object: ObjectIdentifier(node),
          geometry: node.geometry.map(ObjectIdentifier.init),
          parent: node.parent.map(ObjectIdentifier.init), matrix: elements(node.simdWorldTransform),
          opacity: effectiveOpacities[id] ?? 0, hidden: node.isHidden,
          materialAlpha: materialAlpha(node))
      })
  }
  private func materialAlpha(_ node: SCNNode) -> Double {
    guard let material = node.geometry?.firstMaterial else { return 1 }
    return Double(material.transparency)
      * Double((material.diffuse.contents as? NSColor)?.alphaComponent ?? 1)
  }
  private func elements(_ m: simd_float4x4) -> [Float] {
    [
      m.columns.0.x, m.columns.0.y, m.columns.0.z, m.columns.0.w,
      m.columns.1.x, m.columns.1.y, m.columns.1.z, m.columns.1.w,
      m.columns.2.x, m.columns.2.y, m.columns.2.z, m.columns.2.w,
      m.columns.3.x, m.columns.3.y, m.columns.3.z, m.columns.3.w,
    ]
  }
  private func native(_ point: Vector3D) -> SCNVector3 {
    .init(Float(point.x), Float(point.y), Float(point.z))
  }
  private func vector(_ point: SCNVector3) -> Vector3D {
    .init(x: Double(point.x), y: Double(point.y), z: Double(point.z))
  }
  private func finite(_ point: SCNVector3) -> Bool {
    point.x.isFinite && point.y.isFinite && point.z.isFinite
  }
}
