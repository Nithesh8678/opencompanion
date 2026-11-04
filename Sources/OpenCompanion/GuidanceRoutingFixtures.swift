import Foundation

/// Authored public UI data for opt-in acceptance. These are never real AX reads,
/// screen captures or application controls.
struct GuidanceRoutingFixture: Sendable {
  enum Layout: Sendable, Equatable {
    case workspaceExpanded, workspaceCollapsed, notes
    case profile, preferences, chart, reader, canvas, status, ambiguous, incompatible
  }
  enum Expectation: String, Sendable { case click, manual, clarification }

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
  var expectation: Expectation = .click
  var pixelSize: CGSize = imageSize

  var expectedControl: Control? { controls.first { $0.key == expectedControlKey } }
  var expectedCandidateID: String? {
    guard let index = controls.firstIndex(where: { $0.key == expectedControlKey }) else {
      return nil
    }
    return ScreenGrounding.candidateID(frameID: frameID, index: index)
  }

  var candidates: [ScreenGroundingCandidate] {
    guard usesAccessibilityCandidates else { return [] }
    let size = pixelSize
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
    func control(_ key: String, _ label: String, _ rect: CGRect, actionable: Bool = true) -> Control
    {
      .init(
        key: key, title: "", accessibilityDescription: label,
        role: actionable ? "AXButton" : "AXStaticText", rect: rect, actionable: actionable)
    }
    let profile = Self(
      id: "06-heldout-profile", foregroundName: "Member Portal",
      request: "how to check my profile, in the current screen", frameID: UUID(), layout: .profile,
      expectedControlKey: "avatar",
      controls: [
        control("avatar", "Profile", CGRect(x: 1_120, y: 28, width: 40, height: 40)),
        control("gear", "Preferences", CGRect(x: 1_060, y: 30, width: 36, height: 36)),
        control("edit", "Edit membership", CGRect(x: 1_076, y: 180, width: 32, height: 32)),
      ], usesAccessibilityCandidates: false)
    let preferences = Self(
      id: "07-heldout-appearance", foregroundName: "Canvas Studio",
      request: "How do I change this app's appearance?", frameID: UUID(), layout: .preferences,
      expectedControlKey: "gear",
      controls: [
        control("gear", "Preferences", CGRect(x: 1_112, y: 28, width: 40, height: 40)),
        control("help", "Help", CGRect(x: 1_052, y: 28, width: 40, height: 40)),
      ], usesAccessibilityCandidates: false)
    let chart = Self(
      id: "08-heldout-export", foregroundName: "Chart Desk",
      request: "How can I save this chart as a PNG file?", frameID: UUID(), layout: .chart,
      expectedControlKey: "export",
      controls: [
        control("export", "Export", CGRect(x: 1_000, y: 112, width: 132, height: 40)),
        control("share", "Share", CGRect(x: 886, y: 112, width: 92, height: 40)),
        control("upload", "Upload data", CGRect(x: 40, y: 112, width: 140, height: 40)),
      ], usesAccessibilityCandidates: false)
    let reader = Self(
      id: "09-heldout-next-page", foregroundName: "Reference Reader",
      request: "How do I go to the next page of this document?", frameID: UUID(), layout: .reader,
      expectedControlKey: "next-page",
      controls: [
        control("next-page", "Next page", CGRect(x: 1_122, y: 752, width: 40, height: 40)),
        control("previous-page", "Previous page", CGRect(x: 962, y: 752, width: 40, height: 40)),
        control("forward", "Forward", CGRect(x: 96, y: 28, width: 36, height: 36)),
        control("back", "Back", CGRect(x: 40, y: 28, width: 36, height: 36)),
      ], usesAccessibilityCandidates: false, pixelSize: CGSize(width: 1_360, height: 840))
    let canvas = Self(
      id: "10-heldout-custom-canvas", foregroundName: "Vector Lab",
      request: "Show me where to choose the triangle tool.", frameID: UUID(), layout: .canvas,
      expectedControlKey: "triangle-tool",
      controls: [
        control("square-tool", "", CGRect(x: 24, y: 154, width: 44, height: 44)),
        control("circle-tool", "", CGRect(x: 24, y: 214, width: 44, height: 44)),
        control("triangle-tool", "", CGRect(x: 24, y: 274, width: 44, height: 44)),
        control("line-tool", "", CGRect(x: 24, y: 334, width: 44, height: 44)),
      ], usesAccessibilityCandidates: false)
    let status = Self(
      id: "11-heldout-screen-question", foregroundName: "Metrics Console",
      request:
        "Explain what the failed job's status badge means on this screen, and point out that badge.",
      frameID: UUID(), layout: .status,
      expectedControlKey: "failed-status",
      controls: [
        control(
          "healthy-status", "Completed", CGRect(x: 850, y: 240, width: 180, height: 38),
          actionable: false),
        control(
          "waiting-status", "Queued", CGRect(x: 850, y: 320, width: 180, height: 38),
          actionable: false),
        control(
          "failed-status", "Upload failed", CGRect(x: 850, y: 400, width: 180, height: 38),
          actionable: false),
      ], usesAccessibilityCandidates: false, expectation: .manual)
    let ambiguous = Self(
      id: "12-ambiguous-selection", foregroundName: "File Desk",
      request: "Open the selected item on this screen.", frameID: UUID(), layout: .ambiguous,
      expectedControlKey: "", controls: [], usesAccessibilityCandidates: false,
      expectation: .clarification)
    let incompatible = Self(
      id: "13-incompatible-foreground", foregroundName: "Photo Board",
      request: "How do I send this email from this app?", frameID: UUID(), layout: .incompatible,
      expectedControlKey: "", controls: [], usesAccessibilityCandidates: false,
      expectation: .clarification)
    return [
      first, collapsed, revealed, notes, pixels, profile, preferences, chart, reader, canvas,
      status, ambiguous, incompatible,
    ]
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
  static func evaluate(
    units: [ProviderUnit], fixture: GuidanceRoutingFixture,
    candidates: [ScreenGroundingCandidate]
  ) throws -> GuidanceRoutingSelection? {
    guard fixture.expectation == .clarification else {
      return try validate(units: units, fixture: fixture, candidates: candidates)
    }
    // This verifies a safe clarification envelope, not the prose's meaning.
    guard !units.isEmpty, units.count <= 32, units.allSatisfy({ $0.type == "text" }),
      units.allSatisfy({ $0.target == nil && $0.nodes == nil && $0.operations == nil })
    else {
      throw ProviderError.message("An ambiguous fixture must not invent a target or Notebook.")
    }
    let text = units.compactMap(\.text).joined(separator: " ").trimmingCharacters(
      in: .whitespacesAndNewlines)
    guard units.allSatisfy({ $0.text != nil }), !text.isEmpty, text.count <= 600,
      text.utf8.count <= 2_400
    else { throw ProviderError.message("Expected one bounded, nonempty clarification response.") }
    return nil
  }

  static func validate(
    units: [ProviderUnit], fixture: GuidanceRoutingFixture,
    candidates: [ScreenGroundingCandidate]
  ) throws -> GuidanceRoutingSelection {
    guard !units.isEmpty, units.count <= 32,
      units.allSatisfy({ ["text", "target"].contains($0.type) })
    else {
      throw ProviderError.message("The guidance fixture received a scene or unsupported unit.")
    }
    for unit in units where unit.type == "text" {
      guard let text = unit.text, text.utf8.count <= 32_000 else {
        throw ProviderError.message("The provider emitted an invalid text unit.")
      }
    }
    let targetUnits = units.filter { $0.type == "target" }
    let targets = targetUnits.compactMap(\.target)
    let selected =
      fixture.expectation == .manual ? targets : targets.filter { $0.advanceOn == "click" }
    guard fixture.expectation != .clarification,
      targets.count == targetUnits.count, selected.count == 1,
      let raw = selected.first, let expected = fixture.expectedControl,
      expected.enabled, fixture.expectation != .click || expected.actionable,
      fixture.expectation != .manual || raw.advanceOn == "manual"
    else {
      throw ProviderError.message(
        "Expected one correctly grounded mark with the requested click/manual condition; text alone, disabled controls and distractors do not pass."
      )
    }
    // A correct primary target cannot hide a later unit that the production
    // acceptance boundary would reject. Validate every emitted mark first.
    for target in targets {
      let mark = GuidanceTargetPresentation.styled(
        try ScreenGrounding.resolve(
          target, candidates: candidates, frameID: fixture.frameID,
          imagePixelSize: fixture.pixelSize))
      guard mark.instruction.utf8.count <= 32_000,
        (mark.label?.prefix(81).count ?? 0) <= 80,
        [nil, "ellipse", "roundedRectangle"].contains(mark.shape),
        [nil, "click", "manual"].contains(mark.advanceOn),
        ScreenGuidancePolicy.targetRect(
          mark, in: CGRect(origin: .zero, size: fixture.pixelSize)) != nil
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
      raw, candidates: candidates, frameID: fixture.frameID, imagePixelSize: fixture.pixelSize)
    let presented = GuidanceTargetPresentation.styled(resolved)
    let permitted = expected.rect.insetBy(
      dx: -max(12, expected.rect.width * 0.5), dy: -max(12, expected.rect.height * 0.5))
    let pixelRect = CGRect(
      x: presented.x * fixture.pixelSize.width, y: presented.y * fixture.pixelSize.height,
      width: presented.width * fixture.pixelSize.width,
      height: presented.height * fixture.pixelSize.height)
    let supportedShape =
      fixture.expectation == .click
      ? presented.shape == "ellipse"
      : [nil, "ellipse", "roundedRectangle"].contains(presented.shape)
    guard supportedShape, presented.instruction.utf8.count <= 32_000,
      fixture.expectation != .manual
        || !presented.instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      let label = presented.label?.trimmingCharacters(in: .whitespacesAndNewlines),
      !label.isEmpty, label.prefix(81).count <= 80,
      let rect = ScreenGuidancePolicy.targetRect(
        presented, in: CGRect(origin: .zero, size: fixture.pixelSize)),
      presented.width <= 0.35, presented.height <= 0.2, permitted.contains(pixelRect),
      rect.width >= expected.rect.width * 0.4, rect.height >= expected.rect.height * 0.4,
      rect.width <= expected.rect.width * 3, rect.height <= expected.rect.height * 3,
      rect.contains(
        CGPoint(
          x: expected.rect.midX,
          y: fixture.pixelSize.height - expected.rect.midY))
    else {
      throw ProviderError.message(
        "The resolved native target did not cover the bounded expected control.")
    }
    return .init(raw: raw, resolved: resolved, presentation: presented)
  }
}
