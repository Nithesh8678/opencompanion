import Foundation
import Testing

@testable import OpenCompanion

struct GuidanceRoutingFixtureTests {
  @Test func semanticFixtureUsesEmptyTitleDescriptionAndKeepsDistractorDistinct() throws {
    let fixture = try #require(GuidanceRoutingFixture.scenarios().first)
    #expect(fixture.request == "How do I create a new chat in ChatGPT?")
    #expect(fixture.foregroundName == "Assistant Workspace")
    let expected = try #require(fixture.expectedControl)
    #expect(expected.title.isEmpty)
    #expect(expected.accessibilityDescription == "New task")
    let selected = try #require(fixture.candidates.first { $0.id == fixture.expectedCandidateID })
    #expect(selected.label == "New task")
    #expect(selected.width == 36.0 / 1_200)
    let edit = try #require(fixture.candidates.first { $0.label == "Edit note" })
    #expect(edit.id != selected.id)
    #expect(edit.x > selected.x + selected.width)
  }

  @Test func collapsedFrameOmitsHiddenComposeAndFreshFrameUsesNewIDs() throws {
    let fixtures = GuidanceRoutingFixture.scenarios()
    let collapsed = try #require(fixtures.first { $0.id == "02-collapsed-sidebar" })
    let revealed = try #require(fixtures.first { $0.id == "03-fresh-revealed-sidebar" })
    #expect(collapsed.candidates.allSatisfy { $0.label != "New task" })
    #expect(collapsed.expectedControl?.accessibilityDescription == "Show sidebar")
    #expect(revealed.expectedControl?.accessibilityDescription == "New task")
    #expect(revealed.previousFixtureID == collapsed.id)
    #expect(revealed.frameID != collapsed.frameID)
    #expect(Set(revealed.candidates.map(\.id)).isDisjoint(with: collapsed.candidates.map(\.id)))
  }

  @Test func semanticSelectionUsesNativeBoundsRatherThanGuessedModelGeometry() throws {
    let fixture = try #require(GuidanceRoutingFixture.scenarios().first)
    var raw = try target(for: fixture)
    raw.x = 0.8
    raw.y = 0.6
    raw.width = 0.1
    raw.height = 0.1
    raw.shape = "roundedRectangle"
    let selection = try GuidanceRoutingOracle.validate(
      units: [unit(raw)], fixture: fixture, candidates: fixture.candidates)
    let candidate = try #require(fixture.candidates.first { $0.id == fixture.expectedCandidateID })
    #expect(selection.raw.x == 0.8)
    #expect(selection.resolved.x == candidate.x)
    #expect(selection.resolved.y == candidate.y)
    #expect(selection.presentation.shape == "ellipse")
    #expect(selection.presentation.width == candidate.width)
  }

  @Test func shortcutTextMissingIDsAndWrongOrDisabledPencilsDoNotPass() throws {
    let fixture = try #require(GuidanceRoutingFixture.scenarios().first)
    var missing = try target(for: fixture)
    missing.candidateID = nil
    let wrongID = try #require(fixture.candidates.first { $0.label == "Edit note" }?.id)
    var wrong = try target(for: fixture)
    wrong.candidateID = wrongID
    var disabled = try target(for: fixture)
    disabled.candidateID = try #require(fixture.candidates.first { !$0.enabled }?.id)
    for units in [
      [ProviderUnit(type: "text", text: "Use the keyboard shortcut to start a new conversation.")],
      [unit(missing)], [unit(wrong)], [unit(disabled)], [ProviderUnit(type: "target")],
    ] {
      #expect(throws: (any Error).self) {
        try GuidanceRoutingOracle.validate(
          units: units, fixture: fixture, candidates: fixture.candidates)
      }
    }
  }

  @Test func multipleAdvancingTargetsOrNotebookOutputFailButManualMarkIsAllowed() throws {
    let fixture = try #require(GuidanceRoutingFixture.scenarios().first)
    let primary = try target(for: fixture)
    #expect(throws: (any Error).self) {
      try GuidanceRoutingOracle.validate(
        units: [unit(primary), unit(primary)], fixture: fixture, candidates: fixture.candidates)
    }
    #expect(throws: (any Error).self) {
      try GuidanceRoutingOracle.validate(
        units: [unit(primary), ProviderUnit(type: "scene", title: "Unrequested notebook")],
        fixture: fixture, candidates: fixture.candidates)
    }
    var manual = primary
    manual.advanceOn = "manual"
    _ = try GuidanceRoutingOracle.validate(
      units: [unit(primary), unit(manual)], fixture: fixture, candidates: fixture.candidates)
  }

  @Test func previousFrameCandidateCannotPassTheRevealedFrame() throws {
    let fixtures = GuidanceRoutingFixture.scenarios()
    let collapsed = try #require(fixtures.first { $0.id == "02-collapsed-sidebar" })
    let revealed = try #require(fixtures.first { $0.id == "03-fresh-revealed-sidebar" })
    let stale = try target(for: collapsed)
    #expect(throws: (any Error).self) {
      try GuidanceRoutingOracle.validate(
        units: [unit(stale)], fixture: revealed, candidates: revealed.candidates)
    }
    _ = try GuidanceRoutingOracle.validate(
      units: [unit(try target(for: revealed))], fixture: revealed, candidates: revealed.candidates)
  }

  @Test func correctPrimaryCannotHideAnInvalidSecondaryMark() throws {
    let fixture = try #require(GuidanceRoutingFixture.scenarios().first)
    let primary = try target(for: fixture)
    var stale = primary
    stale.advanceOn = "manual"
    stale.candidateID = ScreenGrounding.candidateID(frameID: UUID(), index: 0)
    var malformed = stale
    malformed.candidateID = nil
    malformed.width = -0.1
    var badShape = primary
    badShape.advanceOn = "manual"
    badShape.shape = "triangle"
    for secondary in [stale, malformed, badShape] {
      #expect(throws: (any Error).self) {
        try GuidanceRoutingOracle.validate(
          units: [unit(primary), unit(secondary)], fixture: fixture, candidates: fixture.candidates)
      }
    }
  }

  @Test func pixelOnlyOracleNeedsActualCompactGeometryAndRejectsInventedCandidate() throws {
    let fixture = try #require(
      GuidanceRoutingFixture.scenarios().first { !$0.usesAccessibilityCandidates })
    #expect(fixture.candidates.isEmpty)
    let valid = try target(for: fixture)
    _ = try GuidanceRoutingOracle.validate(units: [unit(valid)], fixture: fixture, candidates: [])
    var wrong = valid
    wrong.x = 0.8
    var large = valid
    large.width = 1
    large.height = 1
    var tiny = valid
    tiny.width = 0.0001
    var invalid = valid
    invalid.y = .nan
    var invented = valid
    invented.candidateID = fixture.expectedCandidateID
    for target in [wrong, large, tiny, invalid, invented] {
      #expect(throws: (any Error).self) {
        try GuidanceRoutingOracle.validate(units: [unit(target)], fixture: fixture, candidates: [])
      }
    }
  }

  @Test func secondGenericApplicationUsesIndependentIntentAndControl() throws {
    let fixture = try #require(GuidanceRoutingFixture.scenarios().first { $0.layout == .notes })
    let policy = ResponsePolicy.resolve(text: fixture.request, screenGuidanceEnabled: true)
    #expect(policy.route == .screenGuidance)
    #expect(!policy.allowsNotebook)
    #expect(fixture.foregroundName == "Notes Workspace")
    #expect(fixture.expectedControl?.accessibilityDescription == "New note")
    _ = try GuidanceRoutingOracle.validate(
      units: [unit(try target(for: fixture))], fixture: fixture, candidates: fixture.candidates)
  }

  private func target(for fixture: GuidanceRoutingFixture) throws -> ProviderTarget {
    let control = try #require(fixture.expectedControl)
    let size = GuidanceRoutingFixture.imageSize
    return ProviderTarget(
      x: control.rect.minX / size.width, y: control.rect.minY / size.height,
      width: control.rect.width / size.width, height: control.rect.height / size.height,
      instruction: "Choose the visible control.", label: "Next", shape: "ellipse",
      advanceOn: "click",
      candidateID: fixture.usesAccessibilityCandidates ? fixture.expectedCandidateID : nil)
  }

  private func unit(_ target: ProviderTarget) -> ProviderUnit {
    ProviderUnit(type: "target", target: target)
  }
}
