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

  @Test func correctTargetCannotHideNilOrOversizedText() throws {
    let fixtures = GuidanceRoutingFixture.scenarios()
    for expectation in [GuidanceRoutingFixture.Expectation.click, .manual] {
      let fixture = try #require(fixtures.first { $0.expectation == expectation })
      let primary = unit(try target(for: fixture))
      for text in [
        String?.none, String(repeating: "a", count: 32_001), String(repeating: "é", count: 16_001),
      ] {
        for units in [
          [primary, ProviderUnit(type: "text", text: text)],
          [ProviderUnit(type: "text", text: text), primary],
        ] {
          #expect(throws: (any Error).self) {
            try GuidanceRoutingOracle.validate(
              units: units, fixture: fixture, candidates: fixture.candidates)
          }
        }
      }
      for text in ["", String(repeating: "é", count: 16_000)] {
        _ = try GuidanceRoutingOracle.validate(
          units: [primary, ProviderUnit(type: "text", text: text)], fixture: fixture,
          candidates: fixture.candidates)
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

  @Test func heldoutCasesArePixelOnlyAndIncludeTheExactProfileRequest() throws {
    let fixtures = GuidanceRoutingFixture.scenarios()
    #expect(fixtures.count == 13)
    #expect(Set(fixtures.map(\.id)).count == fixtures.count)
    let heldout = Array(fixtures.dropFirst(5))
    #expect(heldout.count == 8)
    #expect(heldout.allSatisfy { !$0.usesAccessibilityCandidates && $0.candidates.isEmpty })
    let profile = try #require(heldout.first)
    #expect(profile.layout == .profile)
    #expect(profile.foregroundName == "Member Portal")
    #expect(profile.request == "how to check my profile, in the current screen")
    #expect(profile.expectedControlKey == "avatar")
    #expect(profile.controls.contains { $0.key == "gear" })
    #expect(profile.controls.contains { $0.key == "edit" })
    for fixture in heldout {
      let envelope = ScreenGrounding.evidenceContext(
        candidates: fixture.candidates, frameID: fixture.frameID)
      #expect(!envelope.contains("oracle"))
      #expect(
        fixture.controls.allSatisfy {
          $0.accessibilityDescription.isEmpty || !envelope.contains($0.accessibilityDescription)
        })
    }
  }

  @Test func genericHeldoutMarksHaveStrictIndependentGeometry() throws {
    for fixture in GuidanceRoutingFixture.scenarios().dropFirst(5)
    where fixture.expectation != .clarification {
      let valid = try target(for: fixture)
      let result = try GuidanceRoutingOracle.evaluate(
        units: [unit(valid)], fixture: fixture, candidates: [])
      #expect(result != nil)
      var broad = valid
      broad.x = 0
      broad.y = 0
      broad.width = 1
      broad.height = 1
      var wrong = valid
      wrong.x = 0.5
      wrong.y = 0.5
      var missingLabel = valid
      missingLabel.label = "  "
      var inventedCandidate = valid
      inventedCandidate.candidateID = ScreenGrounding.candidateID(
        frameID: fixture.frameID, index: 0)
      for invalid in [broad, wrong, missingLabel, inventedCandidate] {
        #expect(throws: (any Error).self) {
          try GuidanceRoutingOracle.evaluate(
            units: [unit(invalid)], fixture: fixture, candidates: [])
        }
      }
    }
  }

  @Test func manualScreenQuestionNeverPassesAsAClick() throws {
    let fixture = try #require(
      GuidanceRoutingFixture.scenarios().first { $0.expectation == .manual })
    #expect(fixture.request.lowercased().contains("explain"))
    #expect(fixture.request.lowercased().contains("status badge"))
    #expect(fixture.request.lowercased().contains("point out that badge"))
    #expect(fixture.expectedControl?.rect == CGRect(x: 850, y: 400, width: 180, height: 38))
    let valid = try target(for: fixture)
    #expect(valid.advanceOn == "manual")
    _ = try GuidanceRoutingOracle.validate(units: [unit(valid)], fixture: fixture, candidates: [])
    var clicking = valid
    clicking.advanceOn = "click"
    #expect(throws: (any Error).self) {
      try GuidanceRoutingOracle.validate(units: [unit(clicking)], fixture: fixture, candidates: [])
    }
    var emptyInstruction = valid
    emptyInstruction.instruction = "  \n "
    #expect(throws: (any Error).self) {
      try GuidanceRoutingOracle.validate(
        units: [unit(emptyInstruction)], fixture: fixture, candidates: [])
    }
  }

  @Test func readerUsesItsOwnImageDimensionsAndRejectsOldSizeCoordinates() throws {
    let fixture = try #require(GuidanceRoutingFixture.scenarios().first { $0.layout == .reader })
    #expect(fixture.pixelSize == CGSize(width: 1_360, height: 840))
    let valid = try target(for: fixture)
    #expect(valid.x == 1_122.0 / 1_360)
    #expect(valid.y == 752.0 / 840)
    _ = try GuidanceRoutingOracle.validate(units: [unit(valid)], fixture: fixture, candidates: [])
    var wrongSize = valid
    wrongSize.x = 1_122.0 / 1_200
    wrongSize.y = 752.0 / 780
    #expect(throws: (any Error).self) {
      try GuidanceRoutingOracle.validate(units: [unit(wrongSize)], fixture: fixture, candidates: [])
    }
  }

  @Test func ambiguousScreensAcceptOnlyBoundedTextWithoutInventedMarksOrNotebook() throws {
    for fixture in GuidanceRoutingFixture.scenarios() where fixture.expectation == .clarification {
      let valid = [ProviderUnit(type: "text", text: "Which item or application did you mean?")]
      #expect(
        try GuidanceRoutingOracle.evaluate(units: valid, fixture: fixture, candidates: []) == nil)
      let invented = ProviderTarget(
        x: 0.1, y: 0.1, width: 0.1, height: 0.1, instruction: "Choose this.", label: "Next",
        shape: "ellipse", advanceOn: "click")
      for invalid in [
        [], [ProviderUnit(type: "text", text: "   ")],
        [ProviderUnit(type: "text", text: String(repeating: "a", count: 601))],
        [ProviderUnit(type: "text")],
        valid + [unit(invented)], valid + [ProviderUnit(type: "scene", title: "Notebook")],
      ] {
        #expect(throws: (any Error).self) {
          try GuidanceRoutingOracle.evaluate(units: invalid, fixture: fixture, candidates: [])
        }
      }
    }
  }

  @MainActor @Test func everyAuthoredBitmapHasItsDeclaredCoordinateDimensions() throws {
    for fixture in GuidanceRoutingFixture.scenarios() {
      let image = try GuidanceRoutingAcceptance.makeFixture(fixture)
      #expect(image.width == Int(fixture.pixelSize.width))
      #expect(image.height == Int(fixture.pixelSize.height))
    }
  }

  @Test func collectorRecordsActualRoutingAndDistinctFirstUnitAndValidTargetTimes() async throws {
    let fixture = try #require(GuidanceRoutingFixture.scenarios().first { $0.layout == .profile })
    let collector = GuidanceRoutingUnits(
      startedAt: ProcessInfo.processInfo.systemUptime, fixture: fixture, candidates: [])
    let actual = CodexRoutingSelection(
      model: "catalog-terra-model", effort: "low", reason: .terraGuidance)
    await collector.route(actual)
    await collector.route(
      .init(model: "ignored-late-selection", effort: nil, reason: .conversation))
    try await collector.accept(ProviderUnit(type: "text", text: "I can point that out."))
    var invalid = try target(for: fixture)
    invalid.x = 0
    try await collector.accept(unit(invalid))
    let beforeValid = await collector.timing()
    #expect(beforeValid.routing == actual)
    #expect(beforeValid.firstUnitMS != nil)
    #expect(beforeValid.firstTargetMS != nil)
    #expect(beforeValid.firstOracleTargetMS == nil)
    try await collector.accept(unit(try target(for: fixture)))
    let timing = await collector.timing()
    let routingMS = try #require(timing.routingMS)
    let unitMS = try #require(timing.firstUnitMS)
    let targetMS = try #require(timing.firstTargetMS)
    let validMS = try #require(timing.firstOracleTargetMS)
    #expect(routingMS >= 0 && routingMS <= unitMS)
    #expect(unitMS <= targetMS && targetMS <= validMS)
    #expect(await collector.snapshot().count == 3)
  }

  private func target(for fixture: GuidanceRoutingFixture) throws -> ProviderTarget {
    let control = try #require(fixture.expectedControl)
    let size = fixture.pixelSize
    return ProviderTarget(
      x: control.rect.minX / size.width, y: control.rect.minY / size.height,
      width: control.rect.width / size.width, height: control.rect.height / size.height,
      instruction: "Choose the visible control.", label: "Next", shape: "ellipse",
      advanceOn: fixture.expectation == .manual ? "manual" : "click",
      candidateID: fixture.usesAccessibilityCandidates ? fixture.expectedCandidateID : nil)
  }

  private func unit(_ target: ProviderTarget) -> ProviderUnit {
    ProviderUnit(type: "target", target: target)
  }
}
