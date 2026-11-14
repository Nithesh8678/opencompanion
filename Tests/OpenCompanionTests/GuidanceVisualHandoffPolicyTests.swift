import Testing

@testable import OpenCompanion

struct GuidanceVisualHandoffPolicyTests {
  @Test(arguments: ["Show it in 3D", "Generate it in 3D", "Render that in 3D"])
  func explicitVisualShorthandRequiresAnArtifact(_ text: String) {
    let policy = ResponsePolicy.resolve(text: text, screenGuidanceEnabled: true)
    #expect(policy.route == .notebook && policy.allowsNotebook)
    #expect(ResponsePolicy.requestsExplicit3D(text))
  }

  @Test(arguments: [
    "Explain it in text only, no 3D", "What does 3D mean?", "Don't show a 3D model",
  ])
  func optOutAndDefinitionDoNotRequireGeometry(_ text: String) {
    #expect(!ResponsePolicy.requestsExplicit3D(text))
  }

  @Test func turnRestrictionCannotRedefineProductCapabilities() {
    let policy = ResponsePolicy.resolve(text: "Hello", screenGuidanceEnabled: true)
    #expect(policy.route == .conversation)
    #expect(policy.instructions.contains("native host can display typed 2D and 3D scenes"))
    #expect(policy.instructions.contains("per-turn restriction"))
    #expect(!policy.allowsNotebook)
  }
}
