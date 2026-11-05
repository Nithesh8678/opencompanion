import Testing

@testable import OpenCompanion

struct ProviderInstructionSelectionTests {
  @Test func notebookUsesOnlyTextSceneAndTypedSpatialContract() {
    for editing in [false, true] {
      let policy = ResponsePolicy(route: .notebook, includesExistingNotebook: editing)
      let prompt = ReasoningProvider.baseInstructions(for: policy)
      #expect(prompt.contains(#"{"type":"text","text":"#))
      #expect(prompt.contains(#"{"type":"scene","title":"#))
      #expect(prompt.contains("spatial3D.geometry"))
      #expect(prompt.contains("baseDocumentRevision"))
      #expect(prompt.contains("atomic valid transaction"))
      #expect(prompt.hasSuffix("\n" + policy.instructions))
      #expect(!prompt.contains(#"{"type":"target"#))
      #expect(!prompt.contains("candidateID"))
      #expect(!prompt.contains("pixelBounds"))
      #expect(!prompt.contains("supplied screenshot"))
    }
  }

  @Test func conversationRetainsItsOriginalBaseExactly() {
    let policy = ResponsePolicy(route: .conversation, includesExistingNotebook: false)
    #expect(
      ReasoningProvider.baseInstructions(for: policy)
        == ReasoningProvider.instructions + "\n" + policy.instructions)
  }

  @Test func screenGuidanceRetainsItsDedicatedOriginalProtocol() {
    let policy = ResponsePolicy(route: .screenGuidance, includesExistingNotebook: false)
    let prompt = ReasoningProvider.baseInstructions(for: policy)
    #expect(prompt.hasPrefix("You are OpenCompanion, a native Mac guidance assistant."))
    #expect(prompt.contains(#"{"type":"target"#))
    #expect(prompt.contains("candidateID"))
    #expect(prompt.contains("pixelBounds"))
    #expect(prompt.hasSuffix("\n" + policy.instructions))
    #expect(!prompt.contains("atomic valid transaction"))
    #expect(!prompt.contains("spatial3D.geometry"))
  }
}
