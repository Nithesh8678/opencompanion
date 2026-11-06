import Foundation
import Testing

@testable import OpenCompanion

struct ProviderGuidanceAssessmentTests {
  @Test(arguments: ProviderGuidanceAssessment.Status.allCases)
  func guidanceStatusDecodesEveryDeclaredAssessment(
    _ status: ProviderGuidanceAssessment.Status
  ) throws {
    let data = try JSONSerialization.data(withJSONObject: [
      "type": "guidanceStatus",
      "guidance": ["status": status.rawValue, "summary": "The public screen shows a new panel."],
    ])
    let unit = try JSONDecoder().decode(ProviderUnit.self, from: data)
    #expect(unit.type == "guidanceStatus")
    #expect(unit.guidance?.status == status)
    #expect(unit.guidance?.summary == "The public screen shows a new panel.")
    #expect(unit.target == nil && unit.nodes == nil)
  }

  @Test func legacyTextAndManualTargetDoNotRequireAnAssessment() throws {
    for line in [
      #"{"type":"text","text":"A public reply."}"#,
      #"{"type":"target","target":{"x":0.1,"y":0.2,"width":0.3,"height":0.1,"instruction":"Enter the name.","advanceOn":"manual","awaitUser":true}}"#,
    ] {
      let unit = try JSONDecoder().decode(ProviderUnit.self, from: Data(line.utf8))
      #expect(unit.guidance == nil)
    }
  }

  @Test func assessmentUsesUTF8ByteBoundsWithoutSplittingUnicode() throws {
    let summary = String(repeating: "🙂", count: 512)
    let valid = try decode(["status": "progress", "summary": summary])
    #expect(valid.summary == summary && valid.summary.utf8.count == 2_048)
    #expect(throws: DecodingError.self) {
      try decode(["status": "progress", "summary": summary + "a"])
    }
  }

  @Test func malformedOrUnknownAssessmentsFailClosed() throws {
    let invalid: [[String: Any]] = [
      ["status": "done", "summary": "A result."],
      ["status": "Progress", "summary": "A result."],
      ["status": "progress", "summary": ""],
      ["status": "progress", "summary": " \n\t"],
      ["status": "progress", "summary": NSNull()],
      ["status": "progress", "summary": 42],
      ["status": 1, "summary": "A result."],
      ["status": "progress"],
      ["summary": "A result."],
      ["status": "progress", "summary": "A result.", "verified": true],
    ]
    for value in invalid {
      #expect(throws: DecodingError.self) { try decode(value) }
    }
  }

  @Test func malformedOptionalAssessmentCannotHideInsideAUnit() throws {
    let data = Data(
      #"{"type":"guidanceStatus","guidance":{"status":"complete","summary":false}}"#.utf8)
    #expect(throws: DecodingError.self) { try JSONDecoder().decode(ProviderUnit.self, from: data) }
  }

  @Test func guidancePromptDescribesAssessmentWithoutChangingOtherRoutes() {
    let guidance = ReasoningProvider.baseInstructions(
      for: .resolve(
        text: "Show me where to click", screenGuidanceEnabled: true, explicitGuidance: true))
    #expect(guidance.contains(#""type":"guidanceStatus""#))
    #expect(guidance.contains("at most one guidanceStatus object per turn"))
    #expect(guidance.contains("loading plus a short text explanation and no target"))
    #expect(guidance.contains("not independent verification"))
    #expect(guidance.contains(#""awaitUser":true"#))
    #expect(guidance.contains("No long preamble, future plan, scene or Notebook"))
    let conversation = ReasoningProvider.baseInstructions(
      for: .resolve(
        text: "Hello", screenGuidanceEnabled: false))
    #expect(!conversation.contains(#""type":"guidanceStatus""#))
    let notebook = ReasoningProvider.baseInstructions(
      for: .resolve(
        text: "Draw a diagram of a motor", screenGuidanceEnabled: false))
    #expect(!notebook.contains(#""type":"guidanceStatus""#))
  }

  private func decode(_ object: [String: Any]) throws -> ProviderGuidanceAssessment {
    try JSONDecoder().decode(
      ProviderGuidanceAssessment.self, from: JSONSerialization.data(withJSONObject: object))
  }
}
