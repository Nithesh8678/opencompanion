import CompanionCore
import Foundation
import Testing

@testable import OpenCompanion

struct GuidanceLatencyEnvelopeTests {
  @Test func diagnosticModelOverrideIsExplicitExactAndKeepsDefaultTerraSelection() throws {
    let normal = try GuidanceLatencyModelProfile(model: "conversation-canary", modelOverride: nil)
    #expect(normal.requestedModel == nil && normal.preference == .terra)
    #expect(normal.configuredModel == "conversation-canary")
    let luna = try GuidanceLatencyModelProfile(
      model: "ignored-default", modelOverride: " gpt-6-luna ")
    #expect(luna.requestedModel == "gpt-6-luna" && luna.configuredModel == "gpt-6-luna")
    #expect(luna.preference == .conversation && luna.label.contains("gpt-6-luna"))
    #expect(!luna.label.contains("terra-catalog"))
    let results: [(actual: Bool, expected: Bool)] = [
      (normal.matches(.init(model: "gpt-6-terra", effort: "low", reason: .terraGuidance)), true),
      (
        normal.matches(
          .init(model: "gpt-6-luna", effort: "low", reason: .terraUnavailableFallback)), false
      ),
      (luna.matches(.init(model: "gpt-6-luna", effort: "low", reason: .configuredGuidance)), true),
      (
        luna.matches(.init(model: "gpt-6-terra", effort: "low", reason: .configuredGuidance)), false
      ),
      (
        luna.matches(.init(model: "gpt-6-luna", effort: "medium", reason: .configuredGuidance)),
        false
      ),
      (luna.matches(.init(model: "gpt-6-luna", effort: "low", reason: .conversation)), false),
      (
        GuidanceLatencyModelProfile.isTerraLow(
          .init(model: "gpt-6-luna", effort: "low", reason: .configuredGuidance)), false
      ),
    ]
    for result in results { #expect(result.actual == result.expected) }

  }

  @Test func malformedDiagnosticModelOverridesRefuseBeforeAnyRun() throws {
    for value in ["", "  ", "gpt-6\nluna", "gpt-6\u{0}luna", String(repeating: "x", count: 201)] {
      #expect(throws: (any Error).self) {
        try GuidanceLatencyModelProfile(model: "default", modelOverride: value)
      }
    }
    #expect(
      try GuidanceLatencyModelProfile(
        model: "default", modelOverride: String(repeating: "x", count: 200)
      ).configuredModel.utf8.count == 200)
  }

  @Test(arguments: ProviderGuidanceAssessment.Status.allCases)
  func oneValidAssessmentIsProjectedWithoutChangingTheTargetOrOracle(
    _ status: ProviderGuidanceAssessment.Status
  ) throws {
    let fixture = try fixture()
    let target = try targetUnit(fixture)
    let units = [assessment(status), target]
    // Preserve the old oracle as a target oracle; the current protocol's
    // assessment envelope is validated independently before this projection.
    #expect(throws: (any Error).self) {
      try GuidanceRoutingOracle.validate(
        units: units, fixture: fixture, candidates: fixture.candidates)
    }
    let projected = try GuidanceLatencyEnvelope.project(units)
    #expect(projected.count == 1 && projected[0].type == "target")
    #expect(
      try GuidanceLatencyEnvelope.publicUnitsJSON(projected)
        == GuidanceLatencyEnvelope.publicUnitsJSON([target]))
    let selected = try GuidanceRoutingOracle.validate(
      units: projected, fixture: fixture, candidates: fixture.candidates)
    #expect(selected.raw.candidateID == fixture.expectedCandidateID)
    #expect(selected.raw.shape == target.target?.shape)
    #expect(selected.raw.instruction == target.target?.instruction)
  }

  @Test func invalidAssessmentPayloadsDoNotDisappearBehindProjection() throws {
    let valid = assessment(.progress)
    var malformed = [ProviderUnit]()
    var value = valid
    value.guidance = nil
    malformed.append(value)
    value = assessment(.progress, summary: " \n\t")
    malformed.append(value)
    value = assessment(.progress, summary: String(repeating: "é", count: 1_025))
    malformed.append(value)
    value = valid
    value.text = "Unexpected text"
    malformed.append(value)
    value = valid
    value.title = "Unexpected title"
    malformed.append(value)
    value = valid
    value.nodes = []
    malformed.append(value)
    value = valid
    value.removeIDs = []
    malformed.append(value)
    value = valid
    value.operations = []
    malformed.append(value)
    value = valid
    value.baseDocumentRevision = 0
    malformed.append(value)
    value = valid
    value.animations = []
    malformed.append(value)
    value = valid
    value.parameters = [:]
    malformed.append(value)
    value = valid
    value.connectors = []
    malformed.append(value)
    value = valid
    value.narration = ""
    malformed.append(value)
    value = valid
    value.focusID = ""
    malformed.append(value)
    value = valid
    value.target = try targetUnit(fixture()).target
    malformed.append(value)
    for unit in malformed {
      #expect(throws: GuidanceLatencyEnvelope.Failure.malformedStatus) {
        try GuidanceLatencyEnvelope.project([unit])
      }
    }
  }

  @Test func duplicateUnknownAndMixedKindsAreRejected() throws {
    #expect(throws: GuidanceLatencyEnvelope.Failure.duplicateStatus) {
      try GuidanceLatencyEnvelope.project([assessment(.progress), assessment(.uncertain)])
    }
    #expect(throws: (any Error).self) {
      try JSONDecoder().decode(
        ProviderUnit.self,
        from: Data(
          #"{"type":"guidanceStatus","guidance":{"status":"invented","summary":"Public summary"}}"#
            .utf8))
    }
    var scene = assessment(.progress)
    scene.type = "scene"
    let validTarget = try targetUnit(fixture())
    #expect(throws: GuidanceLatencyEnvelope.Failure.unexpectedUnit) {
      try GuidanceLatencyEnvelope.project([validTarget, scene])
    }
    var target = try targetUnit(fixture())
    target.guidance = assessment(.progress).guidance
    #expect(throws: GuidanceLatencyEnvelope.Failure.malformedTarget) {
      try GuidanceLatencyEnvelope.project([target])
    }
    let text = ProviderUnit(
      type: "text", text: "Public reply", title: nil, nodes: nil,
      removeIDs: nil, target: nil, guidance: assessment(.progress).guidance)
    #expect(throws: GuidanceLatencyEnvelope.Failure.malformedText) {
      try GuidanceLatencyEnvelope.project([text])
    }
  }

  @Test func wrongCandidateStillFailsTheUnchangedGroundingOracle() throws {
    let fixture = try fixture()
    var target = try targetUnit(fixture)
    let wrongIndex = try #require(fixture.controls.firstIndex { $0.key == "edit" })
    target.target?.candidateID = ScreenGrounding.candidateID(
      frameID: fixture.frameID, index: wrongIndex)
    let projected = try GuidanceLatencyEnvelope.project([assessment(.progress), target])
    do {
      _ = try GuidanceRoutingOracle.validate(
        units: projected, fixture: fixture, candidates: fixture.candidates)
      Issue.record("A valid status must not hide a target on the wrong control")
    } catch {
      #expect(
        GuidanceLatencyEnvelope.groundingFailureCode(error) == "target-oracle-wrong-candidate")
    }
    #expect(
      GuidanceLatencyEnvelope.groundingFailureCode(
        ProviderError.message("PRIVATE_ERROR_CANARY")) == "target-oracle-rejected")
  }

  @Test func statusAloneNeverSatisfiesTheTargetOracleAndBudgetsRemainBounded() throws {
    let fixture = try fixture()
    let projected = try GuidanceLatencyEnvelope.project([assessment(.complete)])
    #expect(projected.isEmpty)
    #expect(throws: (any Error).self) {
      try GuidanceRoutingOracle.validate(
        units: projected, fixture: fixture, candidates: fixture.candidates)
    }
    #expect(throws: GuidanceLatencyEnvelope.Failure.emptyResponse) {
      try GuidanceLatencyEnvelope.project([])
    }
    #expect(throws: GuidanceLatencyEnvelope.Failure.unitBudgetExceeded) {
      try GuidanceLatencyEnvelope.project(Array(repeating: assessment(.progress), count: 33))
    }
  }

  @Test func publicArchiveKeepsUnfilteredStatusAndPixelTargetDecodedFields() throws {
    let status = assessment(.progress, summary: "Public progress remains in the archive.")
    let pixel = ProviderUnit(
      type: "target", text: nil, title: nil, nodes: nil, removeIDs: nil,
      target: .init(
        x: 0, y: 0, width: 0, height: 0, instruction: "Select the public profile.",
        label: "Profile", shape: "ellipse", advanceOn: "click",
        pixelBounds: .init(x: 1_120, y: 28, width: 40, height: 40), awaitUser: false))
    let encoded = try GuidanceLatencyEnvelope.publicUnitsJSON([status, pixel])
    let decoded = try JSONDecoder().decode([ProviderUnit].self, from: encoded)
    #expect(decoded.count == 2 && decoded[0].guidance == status.guidance)
    #expect(decoded[1].target?.pixelBounds == pixel.target?.pixelBounds)
    #expect(decoded[1].target?.instruction == pixel.target?.instruction)
    #expect(decoded[1].target?.awaitUser == false)
    #expect(decoded[1].target?.candidateID == nil)
    // Decoder-supplied zeros must not be re-encoded alongside pixel bounds:
    // doing so would create a mixed representation the real decoder rejects.
    let json = try #require(JSONSerialization.jsonObject(with: encoded) as? [[String: Any]])
    let target = try #require(json[1]["target"] as? [String: Any])
    #expect(target["x"] == nil && target["width"] == nil && target["pixelBounds"] != nil)
  }

  private func fixture() throws -> GuidanceRoutingFixture {
    try #require(GuidanceRoutingFixture.scenarios().first { $0.id == "01-icon-only-compose" })
  }
  private func targetUnit(_ fixture: GuidanceRoutingFixture) throws -> ProviderUnit {
    let id = try #require(fixture.expectedCandidateID)
    return .init(
      type: "target", text: nil, title: nil, nodes: nil, removeIDs: nil,
      target: .init(
        x: 0, y: 0, width: 0, height: 0, instruction: "Select New task.",
        label: "New task", shape: "ellipse", advanceOn: "click", candidateID: id))
  }
  private func assessment(
    _ status: ProviderGuidanceAssessment.Status, summary: String = "Public screen progress."
  ) -> ProviderUnit {
    .init(
      type: "guidanceStatus", text: nil, title: nil, nodes: nil, removeIDs: nil,
      target: nil, guidance: .init(status: status, summary: summary))
  }
}
