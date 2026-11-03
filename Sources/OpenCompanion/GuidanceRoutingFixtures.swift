import Foundation

/// Authored public UI data for opt-in acceptance. These are never real AX reads,
/// screen captures or application controls.
struct GuidanceRoutingFixture: Sendable {
  enum Layout: Sendable, Equatable { case workspaceExpanded, workspaceCollapsed, notes }

  struct Control: Sendable {
    let key: String
    let title: String
    let accessibilityDescription: String
    let role: String
    let rect: CGRect
    var enabled = true
    var actionable = true
  }

  static let imageSize = CGSize(width: 1_200, height: 780)
  static let newChatRequest = "How do I create a new chat in ChatGPT?"

  let id: String
  let foregroundName: String
  let request: String
  let frameID: UUID
  let layout: Layout
  let expectedControlKey: String
  let controls: [Control]
  var previousFixtureID: String? = nil
  var usesAccessibilityCandidates = true

  var expectedControl: Control? { controls.first { $0.key == expectedControlKey } }
  var expectedCandidateID: String? {
    guard let index = controls.firstIndex(where: { $0.key == expectedControlKey }) else {
      return nil
    }
    return ScreenGrounding.candidateID(frameID: frameID, index: index)
  }

  var candidates: [ScreenGroundingCandidate] {
    guard usesAccessibilityCandidates else { return [] }
    let size = Self.imageSize
    let entries = controls.enumerated().map { index, control in
      ScreenGroundingCandidate(
        id: ScreenGrounding.candidateID(frameID: frameID, index: index), source: .accessibility,
        role: control.role,
        label: ScreenGrounding.firstNonemptyLabel([
          control.title, control.accessibilityDescription,
        ]),
        enabled: control.enabled, actionable: control.actionable,
        x: control.rect.minX / size.width, y: control.rect.minY / size.height,
        width: control.rect.width / size.width, height: control.rect.height / size.height)
    }
    return ScreenGrounding.boundedCandidates(entries, frameID: frameID)
  }

  static func scenarios() -> [Self] {
    func workspaceControls(collapsed: Bool) -> [Control] {
      var controls: [Control] = [
        .init(
          key: "sidebar", title: "",
          accessibilityDescription: collapsed ? "Show sidebar" : "Hide sidebar",
          role: "AXButton", rect: CGRect(x: 16, y: 28, width: 36, height: 36))
      ]
      if !collapsed {
        controls.append(
          .init(
            key: "compose", title: "", accessibilityDescription: "New task", role: "AXButton",
            rect: CGRect(x: 184, y: 28, width: 36, height: 36)))
        controls.append(
          .init(
            key: "search", title: "", accessibilityDescription: "Search tasks", role: "AXTextField",
            rect: CGRect(x: 16, y: 92, width: 208, height: 36)))
      }
      controls.append(
        .init(
          key: "edit", title: "", accessibilityDescription: "Edit note", role: "AXButton",
          rect: CGRect(x: 1_076, y: 180, width: 32, height: 32)))
      if !collapsed {
        controls.append(
          .init(
            key: "disabled-compose", title: "", accessibilityDescription: "New task",
            role: "AXButton",
            rect: CGRect(x: 1_120, y: 28, width: 36, height: 36), enabled: false))
      }
      controls.append(
        .init(
          key: "message", title: "", accessibilityDescription: "Message", role: "AXTextArea",
          rect: CGRect(x: 322, y: 658, width: 790, height: 60)))
      return controls
    }
    let first = Self(
      id: "01-icon-only-compose", foregroundName: "Assistant Workspace", request: newChatRequest,
      frameID: UUID(), layout: .workspaceExpanded, expectedControlKey: "compose",
      controls: workspaceControls(collapsed: false))
    let collapsed = Self(
      id: "02-collapsed-sidebar", foregroundName: "Assistant Workspace", request: newChatRequest,
      frameID: UUID(), layout: .workspaceCollapsed, expectedControlKey: "sidebar",
      controls: workspaceControls(collapsed: true))
    let revealed = Self(
      id: "03-fresh-revealed-sidebar", foregroundName: "Assistant Workspace",
      request: newChatRequest,
      frameID: UUID(), layout: .workspaceExpanded, expectedControlKey: "compose",
      controls: workspaceControls(collapsed: false), previousFixtureID: collapsed.id)
    let notes = Self(
      id: "04-generic-new-note", foregroundName: "Notes Workspace",
      request: "How do I create a new note in this app?", frameID: UUID(), layout: .notes,
      expectedControlKey: "new-note",
      controls: [
        .init(
          key: "new-note", title: "", accessibilityDescription: "New note", role: "AXButton",
          rect: CGRect(x: 182, y: 28, width: 36, height: 36)),
        .init(
          key: "edit", title: "", accessibilityDescription: "Edit selected note", role: "AXButton",
          rect: CGRect(x: 1_076, y: 180, width: 32, height: 32)),
        .init(
          key: "search", title: "", accessibilityDescription: "Search notes", role: "AXTextField",
          rect: CGRect(x: 16, y: 92, width: 208, height: 36)),
        .init(
          key: "body", title: "", accessibilityDescription: "Note text", role: "AXTextArea",
          rect: CGRect(x: 328, y: 250, width: 760, height: 350)),
      ])
    let pixels = Self(
      id: "05-pixel-only-sidebar", foregroundName: "Assistant Workspace", request: newChatRequest,
      frameID: UUID(), layout: .workspaceCollapsed, expectedControlKey: "sidebar",
      controls: workspaceControls(collapsed: true), usesAccessibilityCandidates: false)
    return [first, collapsed, revealed, notes, pixels]
  }
}

struct GuidanceRoutingSelection: Sendable {
  let raw: ProviderTarget
  let resolved: ProviderTarget
  let presentation: ProviderTarget
}

/// Independent answer key: production candidate resolution remains responsible
/// for trusted geometry. The answer key never enters the provider's context.
enum GuidanceRoutingOracle {
  static func validate(
    units: [ProviderUnit], fixture: GuidanceRoutingFixture,
    candidates: [ScreenGroundingCandidate]
  ) throws -> GuidanceRoutingSelection {
    guard !units.isEmpty, units.count <= 32,
      units.allSatisfy({ ["text", "target"].contains($0.type) })
    else {
      throw ProviderError.message("The guidance fixture received a scene or unsupported unit.")
    }
    let targetUnits = units.filter { $0.type == "target" }
    let targets = targetUnits.compactMap(\.target)
    let advancing = targets.filter { $0.advanceOn == "click" }
    guard targets.count == targetUnits.count, advancing.count == 1,
      let raw = advancing.first, let expected = fixture.expectedControl,
      expected.enabled, expected.actionable
    else {
      throw ProviderError.message(
        "Expected exactly one click target bound to the current frame's correct accessible control; shortcuts, text alone, disabled controls and distractors do not pass."
      )
    }
    // A correct primary target cannot hide a later unit that the production
    // acceptance boundary would reject. Validate every emitted mark first.
    for target in targets {
      let mark = GuidanceTargetPresentation.styled(
        try ScreenGrounding.resolve(target, candidates: candidates, frameID: fixture.frameID))
      guard mark.instruction.utf8.count <= 32_000,
        (mark.label?.prefix(81).count ?? 0) <= 80,
        [nil, "ellipse", "roundedRectangle"].contains(mark.shape),
        [nil, "click", "manual"].contains(mark.advanceOn),
        ScreenGuidancePolicy.targetRect(
          mark, in: CGRect(origin: .zero, size: GuidanceRoutingFixture.imageSize)) != nil
      else {
        throw ProviderError.message("The provider emitted an invalid secondary guidance mark.")
      }
    }
    if fixture.usesAccessibilityCandidates {
      guard let expectedID = fixture.expectedCandidateID, raw.candidateID == expectedID else {
        throw ProviderError.message(
          "The semantic fixture did not select the correct current-frame candidate.")
      }
    } else if raw.candidateID != nil {
      throw ProviderError.message("The image-only fixture invented a grounding candidate ID.")
    }
    let resolved = try ScreenGrounding.resolve(
      raw, candidates: candidates, frameID: fixture.frameID)
    let presented = GuidanceTargetPresentation.styled(resolved)
    guard presented.shape == "ellipse", presented.instruction.utf8.count <= 32_000,
      (presented.label?.prefix(81).count ?? 0) <= 80,
      let rect = ScreenGuidancePolicy.targetRect(
        presented, in: CGRect(origin: .zero, size: GuidanceRoutingFixture.imageSize)),
      presented.width <= 0.12, presented.height <= 0.12,
      rect.width >= expected.rect.width * 0.4, rect.height >= expected.rect.height * 0.4,
      rect.width <= expected.rect.width * 3, rect.height <= expected.rect.height * 3,
      rect.contains(
        CGPoint(
          x: expected.rect.midX,
          y: GuidanceRoutingFixture.imageSize.height - expected.rect.midY))
    else {
      throw ProviderError.message(
        "The resolved native target did not cover the bounded expected control.")
    }
    return .init(raw: raw, resolved: resolved, presentation: presented)
  }
}
