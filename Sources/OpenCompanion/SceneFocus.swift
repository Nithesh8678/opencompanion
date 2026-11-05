import CompanionCore
import Foundation

/// Model output supplies only a retained node ID. Native projection separately
/// decides whether that part currently has a visible point on the own surface.
enum SceneFocus {
  /// Additional focus semantics for an already native-admitted posttransaction
  /// document. This does not replace scene/transaction or native visibility checks.
  static func validate(
    _ focusID: String?, in document: SceneDocument, limits: SceneLimits = .init()
  ) throws -> String? {
    guard let focusID else { return nil }
    _ = try snapshot(focusID, in: document, limits: limits, requireVisibleSyntax: true)
    return focusID
  }

  fileprivate struct Snapshot: Equatable, Sendable {
    let target: SceneNode
    /// Immediate parent first; exact rendering properties remain authoritative.
    let ancestors: [SceneNode]
  }

  fileprivate static func snapshot(
    _ focusID: String, in document: SceneDocument, limits: SceneLimits,
    requireVisibleSyntax: Bool
  ) throws -> Snapshot {
    guard validIdentifier(focusID), validIdentifier(document.id, requireNonblank: false),
      document.revision >= 0
    else {
      throw invalid("identifier or document revision")
    }
    guard document.nodes.count <= min(1_024, limits.maximumNodes), limits.maximumDepth >= 0 else {
      throw CoreError.budgetExceeded("scene focus graph")
    }
    var lookup: [String: SceneNode] = [:]
    for node in document.nodes {
      guard validIdentifier(node.id, requireNonblank: false) else {
        throw invalid("node identifier")
      }
      guard lookup.updateValue(node, forKey: node.id) == nil else {
        throw CoreError.duplicateID(node.id)
      }
    }
    guard let target = lookup[focusID] else { throw CoreError.missingReference(focusID) }
    var ancestors: [SceneNode] = []
    var visited: Set<String> = [focusID]
    var parentID = target.parentID
    while let id = parentID {
      guard ancestors.count < min(32, limits.maximumDepth) else {
        throw CoreError.budgetExceeded("scene focus depth")
      }
      guard visited.insert(id).inserted else { throw invalid("parent cycle") }
      guard let parent = lookup[id], parent.kind == .group else {
        throw invalid("parent must be an existing group")
      }
      ancestors.append(parent)
      parentID = parent.parentID
    }
    if requireVisibleSyntax {
      // Bindings may make the admitted T0 opacity different from the raw value.
      // Future animated state/occlusion remains the native projector's decision.
      let resolved = try document.resolvedNodes(at: 0)
      let resolvedByID = Dictionary(uniqueKeysWithValues: resolved.map { ($0.id, $0) })
      guard let visibleTarget = resolvedByID[focusID], drawable(visibleTarget) else {
        throw invalid("node is not a supported drawable part")
      }
      var effectiveOpacity = 1.0
      for original in [target] + ancestors {
        guard let node = resolvedByID[original.id], node.opacity.isFinite,
          node.opacity > 0, node.opacity <= 1,
          node.spatial3D != nil
            || (node.scaleX.isFinite && node.scaleY.isFinite && node.scaleX != 0
              && node.scaleY != 0)
        else { throw invalid("node or ancestry is hidden") }
        effectiveOpacity *= node.opacity
      }
      guard effectiveOpacity > 0 else { throw invalid("ancestry has zero effective opacity") }
    }
    return Snapshot(target: target, ancestors: ancestors)
  }

  private static func drawable(_ node: SceneNode) -> Bool {
    switch node.kind {
    case .group:
      return false
    case .mesh:
      guard node.spatial3D?.geometry != nil, node.spatial3D?.labelAnchor == nil else {
        return false
      }
      return hasInk(node.fill == "transparent" ? node.color : node.fill)
    case .text:
      // Anchored labels depend on another part's projection and are deliberately
      // unsupported in this first focus contract; never infer that target by name.
      return node.spatial3D == nil
        && !node.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        && hasInk(node.color)
    case .rectangle, .ellipse:
      return node.spatial3D == nil && node.width.isFinite && node.height.isFinite
        && node.width > 0 && node.height > 0
        && (hasInk(node.fill) || (node.strokeWidth > 0 && hasInk(node.color)))
    case .line, .arrow:
      return node.spatial3D == nil && node.strokeWidth.isFinite && node.strokeWidth > 0
        && hasInk(node.color) && hasPath(node)
    case .path:
      return node.spatial3D == nil && hasPath(node)
        && (hasInk(node.fill) || (node.strokeWidth > 0 && hasInk(node.color)))
    }
  }

  private static func hasPath(_ node: SceneNode) -> Bool {
    node.points.count >= 2 || node.subpaths.contains { $0.count >= 2 }
  }

  private static func hasInk(_ color: String) -> Bool {
    let bytes = Array(color.utf8.prefix(10))
    guard bytes.count == 7 || bytes.count == 9, bytes.first == 35,
      bytes.dropFirst().allSatisfy({
        (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
      })
    else { return false }
    return bytes.count == 7 || bytes[7] != 48 || bytes[8] != 48
  }

  private static func validIdentifier(_ id: String, requireNonblank: Bool = true) -> Bool {
    !id.isEmpty && id.utf8.prefix(257).count <= 256
      && (!requireNonblank || !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
  }

  private static func invalid(_ detail: String) -> CoreError {
    .invalidDocument("scene focus: " + detail)
  }
}

/// Presentation authority is independent of screen-capture evidence. There is
/// no image frame ID, guessed screen coordinate or fabricated evidence TTL.
struct SceneFocusAuthority: Equatable, Sendable {
  let presentationLease: UUID
  let generation: UInt64
  let beatID: UUID
  let documentID: String
  let documentRevision: Int
  let focusID: String
  private let snapshot: SceneFocus.Snapshot
  private let nodeLimit: Int
  private let depthLimit: Int

  static func make(
    presentationLease: UUID, generation: UInt64, beatID: UUID,
    document: SceneDocument, focusID: String, limits: SceneLimits = .init()
  ) throws -> Self {
    let snapshot = try SceneFocus.snapshot(
      focusID, in: document, limits: limits, requireVisibleSyntax: true)
    return Self(
      presentationLease: presentationLease, generation: generation, beatID: beatID,
      documentID: document.id, documentRevision: document.revision, focusID: focusID,
      snapshot: snapshot, nodeLimit: min(1_024, limits.maximumNodes),
      depthLimit: min(32, limits.maximumDepth))
  }

  /// Exact raw target/ancestor equality catches same-ID replacement even if a
  /// caller accidentally reuses a revision. Animation time does not rewrite it.
  func matches(document: SceneDocument) -> Bool {
    guard document.id == documentID, document.revision == documentRevision else { return false }
    var limits = SceneLimits()
    limits.maximumNodes = nodeLimit
    limits.maximumDepth = depthLimit
    guard
      let current = try? SceneFocus.snapshot(
        focusID, in: document, limits: limits, requireVisibleSyntax: false)
    else { return false }
    return current == snapshot
  }
}
