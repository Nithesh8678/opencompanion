import CompanionCore
import Foundation

/// Canonicalizes proposed provider geometry and compiles explicit connectors.
/// Stored documents, user edits and final transactions retain strict validation.
enum ProviderSceneBoundary {
  static func applying(
    _ unit: ProviderUnit, to document: SceneDocument, baseRevision: Int,
    limits: SceneLimits = .init()
  ) throws -> SceneDocument {
    if let narration = unit.narration, narration.utf8.count > 32_000 {
      throw ProviderError.message("Oversized scene narration.")
    }
    if let proposed = unit.baseDocumentRevision, proposed != baseRevision {
      throw CoreError.revisionConflict(expected: baseRevision, received: proposed)
    }
    var working = document.nodes
    var operations: [SceneOperation] = []

    func append(_ operation: SceneOperation) throws {
      guard operations.count < limits.maximumOperations else {
        throw CoreError.budgetExceeded("provider operations")
      }
      switch operation {
      case .create(let raw):
        guard !working.contains(where: { $0.id == raw.id }) else {
          throw CoreError.duplicateID(raw.id)
        }
        let node = try raw.canonicalizedDirectionalGeometry(limits: limits)
        working.append(node)
        operations.append(.create(node))
      case .patch(let id, let proposed):
        guard let index = working.firstIndex(where: { $0.id == id }) else {
          throw CoreError.missingReference(id)
        }
        let fields = try normalizedPatch(proposed, current: working[index], limits: limits)
        working[index] = fields.applying(to: working[index])
        operations.append(.patch(id: id, fields: fields))
      case .remove(let id):
        guard working.contains(where: { $0.id == id }) else { throw CoreError.missingReference(id) }
        var deleted: Set<String> = [id]
        for _ in 0...limits.maximumDepth {
          let children = working.filter { $0.parentID.map { deleted.contains($0) } ?? false }.map(
            \.id)
          let before = deleted.count
          deleted.formUnion(children)
          if before == deleted.count { break }
        }
        working.removeAll { deleted.contains($0.id) }
        operations.append(operation)
      default: operations.append(operation)
      }
    }

    for operation in unit.operations ?? [] { try append(operation) }
    for id in unit.removeIDs ?? [] { try append(.remove(id: id)) }
    for raw in unit.nodes ?? [] {
      let node = try raw.canonicalizedDirectionalGeometry(limits: limits)
      if let existing = working.first(where: { $0.id == node.id }) {
        guard existing.kind == node.kind, existing.parentID == node.parentID else {
          throw ProviderError.message(
            "Changing a retained part's kind or parent requires an explicit remove and create transaction."
          )
        }
        try append(.patch(id: node.id, fields: replacementFields(node)))
      } else {
        try append(.create(node))
      }
    }
    for animation in unit.animations ?? [] { try append(.defineAnimation(animation)) }
    for parameter in unit.parameters?.values ?? [String: SceneParameter]().values {
      try append(.defineParameter(parameter))
    }
    if let connectors = unit.connectors, !connectors.isEmpty {
      // Resolve against the complete proposed graph, including annotations
      // whose target is a connector created by this same atomic transaction.
      var context = document
      context.nodes = working
      // Keep every declaration visible to the static-construction guard, even
      // when an operation removes or reuses an earlier target's identity.
      context.animations =
        document.animations
        + operations.compactMap { operation in
          if case .defineAnimation(let animation) = operation { return animation }
          return nil
        }
      let generated = try SpatialConnectorCompiler.compile(connectors, in: context, limits: limits)
      for node in generated { try append(.create(node)) }
    }
    guard !operations.isEmpty else {
      throw ProviderError.message("The scene unit contained no substantive operations.")
    }
    var candidate = document
    if let title = unit.title { candidate.title = String(title.prefix(200)) }
    return try candidate.applying(
      SceneTransaction(
        baseDocumentRevision: baseRevision, operations: operations, surfaceID: document.id),
      limits: limits)
  }

  private static func replacementFields(_ node: SceneNode) -> ScenePatch {
    ScenePatch(
      x: node.x, y: node.y, width: node.width, height: node.height,
      rotation: node.rotation, opacity: node.opacity, scaleX: node.scaleX, scaleY: node.scaleY,
      fontSize: node.fontSize, strokeWidth: node.strokeWidth, text: node.text, color: node.color,
      fill: node.fill, accessibilityLabel: node.accessibilityLabel, points: node.points,
      subpaths: node.subpaths, bindings: node.bindings, spatial3D: node.spatial3D)
  }

  private static func normalizedPatch(
    _ fields: ScenePatch, current: SceneNode, limits: SceneLimits
  ) throws -> ScenePatch {
    guard [.line, .arrow, .path].contains(current.kind) else { return fields }
    let explicitGeometry = fields.points != nil || fields.subpaths != nil
    let signedVector = fields.width != nil || fields.height != nil
    // A color/text/position-only patch must not rewrite retained geometry metadata.
    guard explicitGeometry || signedVector else { return fields }
    var merged = fields.applying(to: current)
    if explicitGeometry {
      // Supplying one point representation replaces the other unless the caller
      // explicitly supplies both. Empty arrays deliberately clear geometry.
      if fields.points != nil && fields.subpaths == nil { merged.subpaths = [] }
      if fields.subpaths != nil && fields.points == nil { merged.points = [] }
    } else {
      // A size-only provider update is the legacy signed vector representation.
      merged.points = []
      merged.subpaths = []
    }
    let intentionallyEmpty =
      explicitGeometry && merged.points.isEmpty && merged.subpaths.allSatisfy(\.isEmpty)
    var canonical = try merged.canonicalizedDirectionalGeometry(limits: limits)
    if intentionallyEmpty {
      canonical.points = []
      canonical.subpaths = []
    }
    var result = fields
    result.width = canonical.width
    result.height = canonical.height
    result.points = canonical.points
    result.subpaths = canonical.subpaths
    return result
  }
}
