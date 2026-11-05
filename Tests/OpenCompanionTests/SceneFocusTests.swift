import CompanionCore
import Foundation
import Testing

@testable import OpenCompanion

struct SceneFocusTests {
  @Test func absentFocusAddsNoCapabilityAndExactIDsRemainUnmodified() throws {
    let document = try fixture().validated()
    #expect(try SceneFocus.validate(nil, in: document) == nil)
    #expect(try SceneFocus.validate("part", in: document) == "part")
    var named = document
    named.nodes[0].id = " retained part "
    #expect(try SceneFocus.validate(" retained part ", in: named) == " retained part ")
    #expect(throws: CoreError.self) { try SceneFocus.validate("retained part", in: named) }
    #expect(document.nodes[0].id == "part" && document.revision == 3)
  }

  @Test func drawableRoleAndMaterialSemanticsMatchTheNativeContract() throws {
    let nodes: [SceneNode] = [
      .init(id: "box", kind: .rectangle, width: 20, height: 10, fill: "#112233"),
      .init(id: "oval", kind: .ellipse, width: 20, height: 10, fill: "transparent"),
      .init(id: "line", kind: .line, points: [.init(x: 0, y: 0), .init(x: 30, y: 10)]),
      .init(id: "arrow", kind: .arrow, points: [.init(x: 0, y: 0), .init(x: 0, y: -30)]),
      .init(id: "path", kind: .path, subpaths: [[.init(x: 0, y: 0), .init(x: 20, y: 10)]]),
      .init(id: "text", kind: .text, text: "Explanatory text"),
      mesh("mesh"),
    ]
    let document = try SceneDocument(nodes: nodes).validated()
    for node in nodes { #expect(try SceneFocus.validate(node.id, in: document) == node.id) }
    // Native typed meshes use color when fill is literally transparent.
    #expect(document.nodes.last?.fill == "transparent")
  }

  @Test func unsupportedEmptyTransparentAndHiddenTargetsRejectWithoutSemanticSubstitution() throws {
    let unsupported: [SceneNode] = [
      .init(id: "focus", kind: .group, spatial3D: .init()),
      .init(id: "focus", kind: .mesh, width: 50, height: 50, text: "sphere"),
      .init(id: "focus", kind: .text, text: " \n\t"),
      .init(id: "focus", kind: .rectangle, width: 0, height: 20),
      .init(id: "focus", kind: .path, points: [.init(x: 0, y: 0)]),
      .init(
        id: "focus", kind: .line, strokeWidth: 0, points: [.init(x: 0, y: 0), .init(x: 2, y: 2)]),
      .init(
        id: "focus", kind: .rectangle, width: 20, height: 20, color: "#11223300", fill: "#11223300"),
      .init(id: "focus", kind: .text, text: "Hidden", color: "#11223300"),
    ]
    for node in unsupported {
      let document = try SceneDocument(nodes: [node]).validated()
      #expect(throws: CoreError.self) { try SceneFocus.validate(node.id, in: document) }
    }
    var invisibleMesh = mesh("part")
    invisibleMesh.fill = "#FFFFFF00"
    #expect(throws: CoreError.self) {
      try SceneFocus.validate("part", in: SceneDocument(nodes: [invisibleMesh]))
    }
    let label = SceneNode(
      id: "label", kind: .text, text: "Part",
      spatial3D: .init(labelAnchor: .init(targetID: "part")))
    let anchored = try SceneDocument(nodes: [mesh("part"), label]).validated()
    #expect(throws: CoreError.self) { try SceneFocus.validate("label", in: anchored) }
    #expect(try SceneFocus.validate("part", in: anchored) == "part")
  }

  @Test func invisibleAncestryAndZeroFlatScaleRejectButBoundOpacityUsesAdmittedState() throws {
    let parent = SceneNode(id: "assembly", kind: .group, spatial3D: .init())
    var child = mesh("part")
    child.parentID = parent.id
    for index in [0, 1] {
      var nodes = [child, parent]
      nodes[index].opacity = 0
      let document = try SceneDocument(nodes: nodes).validated()
      #expect(throws: CoreError.self) { try SceneFocus.validate("part", in: document) }
    }
    var bound = child
    bound.opacity = 0
    bound.bindings["opacity"] = .number(1)
    let visible = try SceneDocument(nodes: [bound, parent]).validated()
    #expect(try SceneFocus.validate("part", in: visible) == "part")
    let collapsed = SceneNode(id: "text", kind: .text, text: "Collapsed", scaleX: 0)
    #expect(throws: CoreError.self) {
      try SceneFocus.validate("text", in: SceneDocument(nodes: [collapsed]))
    }
  }

  @Test func identifiersAreByteBoundedAndBlankOrMissingReferencesFail() throws {
    let document = fixture()
    for id in ["", " \t\n", "missing", String(repeating: "é", count: 129)] {
      #expect(throws: CoreError.self) { try SceneFocus.validate(id, in: document) }
    }
    let exact = String(repeating: "é", count: 128)
    #expect(try SceneFocus.validate(exact, in: SceneDocument(nodes: [mesh(exact)])) == exact)
    var duplicate = document
    duplicate.nodes.append(duplicate.nodes[0])
    #expect(throws: CoreError.self) { try SceneFocus.validate("part", in: duplicate) }
  }

  @Test func ancestryCyclesMissingParentsAndCustomDepthNeverAcquireAuthority() throws {
    let root = SceneNode(id: "root", kind: .group, spatial3D: .init())
    let inner = SceneNode(id: "inner", kind: .group, parentID: root.id, spatial3D: .init())
    var child = mesh("part")
    child.parentID = inner.id
    let document = try SceneDocument(nodes: [child, inner, root]).validated()
    var limits = SceneLimits()
    limits.maximumDepth = 1
    #expect(throws: CoreError.self) {
      try SceneFocus.validate("part", in: document, limits: limits)
    }
    limits.maximumDepth = 2
    #expect(try SceneFocus.validate("part", in: document, limits: limits) == "part")
    var cycle = document
    cycle.nodes[2].parentID = "inner"
    #expect(throws: CoreError.self) { try SceneFocus.validate("part", in: cycle) }
    var missing = document
    missing.nodes.removeLast()
    #expect(throws: CoreError.self) { try SceneFocus.validate("part", in: missing) }
    limits.maximumNodes = 2
    #expect(throws: CoreError.self) {
      try SceneFocus.validate("part", in: document, limits: limits)
    }
  }

  @Test func presentationAuthorityIncludesEveryLifecycleAndDocumentIdentity() throws {
    let document = fixture()
    let lease = UUID()
    let beat = UUID()
    let authority = try SceneFocusAuthority.make(
      presentationLease: lease, generation: 11, beatID: beat, document: document, focusID: "part")
    let same = try SceneFocusAuthority.make(
      presentationLease: lease, generation: 11, beatID: beat, document: document, focusID: "part")
    #expect(authority == same && authority.matches(document: document))
    #expect(
      authority.presentationLease == lease && authority.generation == 11 && authority.beatID == beat
    )
    #expect(authority.documentID == document.id && authority.documentRevision == document.revision)
    #expect(authority.focusID == "part")
    #expect(
      try authority
        != SceneFocusAuthority.make(
          presentationLease: UUID(), generation: 11, beatID: beat, document: document,
          focusID: "part"))
    #expect(
      try authority
        != SceneFocusAuthority.make(
          presentationLease: lease, generation: 12, beatID: beat, document: document,
          focusID: "part"))
    #expect(
      try authority
        != SceneFocusAuthority.make(
          presentationLease: lease, generation: 11, beatID: UUID(), document: document,
          focusID: "part"))
    var changed = document
    changed.revision += 1
    #expect(!authority.matches(document: changed))
    changed = document
    changed.id = "different-document"
    #expect(!authority.matches(document: changed))
  }

  @Test func sameIDSameRevisionTargetAndAncestorReplacementsRevokeAuthority() throws {
    let group = SceneNode(id: "assembly", kind: .group, spatial3D: .init())
    var part = mesh("part")
    part.parentID = group.id
    let document = try SceneDocument(id: "fixed", revision: 4, nodes: [part, group]).validated()
    let authority = try SceneFocusAuthority.make(
      presentationLease: UUID(), generation: 4, beatID: UUID(), document: document, focusID: "part")
    var changed = document
    changed.nodes[0].fill = "#AABBCC"
    #expect(!authority.matches(document: changed))
    changed = document
    changed.nodes[0].spatial3D?.geometry = .box(width: 1, height: 1, depth: 1)
    #expect(!authority.matches(document: changed))
    changed = document
    changed.nodes[0].accessibilityLabel = "Replacement"
    #expect(!authority.matches(document: changed))
    changed = document
    changed.nodes[1].spatial3D?.transform.rotationDegrees.z = 10
    #expect(!authority.matches(document: changed))
    changed = document
    changed.nodes[1].opacity = 0.5
    #expect(!authority.matches(document: changed))
    changed = document
    changed.nodes.removeFirst()
    #expect(!authority.matches(document: changed))
    changed = document
    changed.nodes.append(part)
    #expect(!authority.matches(document: changed))
    #expect(authority.matches(document: document) && document.nodes == [part, group])
  }

  @Test func unrelatedChangesRemainNativeVisibilityWorkRatherThanSemanticRetargeting() throws {
    let document = fixture()
    let authority = try SceneFocusAuthority.make(
      presentationLease: UUID(), generation: 1, beatID: UUID(), document: document, focusID: "part")
    var changed = document
    changed.nodes.append(mesh("possible-occluder"))
    changed.title = "Metadata does not choose a different part"
    #expect(authority.matches(document: changed))
    // This proves identity only. The native projector must independently check
    // the whole scene and decline a newly occluded point.
    #expect(authority.focusID == "part")
  }

  private func fixture() -> SceneDocument {
    SceneDocument(id: "public-focus", revision: 3, nodes: [mesh("part")])
  }

  private func mesh(_ id: String) -> SceneNode {
    .init(id: id, kind: .mesh, spatial3D: .init(geometry: .sphere(radius: 0.5)))
  }
}
