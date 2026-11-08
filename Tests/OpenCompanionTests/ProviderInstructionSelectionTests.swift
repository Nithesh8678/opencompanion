import CompanionCore
import Foundation
import Testing

@testable import OpenCompanion

struct ProviderInstructionSelectionTests {
  @Test func compactStartupRequiresARealPartAndCompletesLabelsWithoutChangingOtherFormats() {
    let policy = ResponsePolicy(route: .notebook, includesExistingNotebook: false)
    for mode in [CodexSceneStartMode.introductionFirst, .geometryFirst] {
      let prompt = ReasoningProvider.baseInstructions(for: policy, sceneStart: mode)
      #expect(prompt.contains("exactly ONE meaningful physical mesh"))
      #expect(prompt.contains("only a minimal assembly group if needed"))
      #expect(prompt.contains("Defer anchored labels, animations and connectors to the second"))
      #expect(prompt.contains("Omit identity transforms and all unused optional or default fields"))
      #expect(prompt.contains("First-scene narration must contain at most 12 words"))
      #expect(prompt.contains("never use an empty group, decorative shape or placeholder"))
      #expect(prompt.contains("Complete useful anchored labels and all requested parts"))
      #expect(prompt.contains("Do not stop after the starter part"))
      #expect(!prompt.contains("ONE physical part (at most two meshes)"))
      #expect(prompt.contains("A unit must remain a valid standalone transaction"))
    }
    for prompt in [
      ReasoningProvider.standaloneStructuredSceneInstructions(for: policy),
      ReasoningProvider.standaloneStructuredSpatialStepsInstructions,
      ReasoningProvider.baseInstructions(
        for: .init(route: .notebook, includesExistingNotebook: true)),
    ] {
      #expect(!prompt.contains("First-scene narration must contain at most 12 words"))
      #expect(!prompt.contains("Defer anchored labels, animations and connectors to the second"))
    }
  }

  @Test func visualQualityGuidelinesAreSharedAcrossSpatialFormatsWithoutGrantingOtherRoutes() {
    let policy = ResponsePolicy(route: .notebook, includesExistingNotebook: false)
    let guidelines = ReasoningProvider.spatialVisualQualityGuidelines
    // Keep this shared design guidance concise; protocol details live separately.
    #expect(guidelines.utf8.count <= 3_000)
    for prompt in [
      ReasoningProvider.baseInstructions(for: policy),
      ReasoningProvider.baseInstructions(for: policy, sceneStart: .geometryFirst),
      ReasoningProvider.standaloneStructuredSceneInstructions(for: policy),
      ReasoningProvider.standaloneStructuredSpatialStepsInstructions,
    ] {
      #expect(prompt.components(separatedBy: guidelines).count == 2)
      #expect(prompt.contains("recognisable topic silhouette"))
      #expect(prompt.contains("connected parts meet"))
      #expect(prompt.contains("2–4 color hierarchy"))
      #expect(prompt.contains("simplified illustrative model"))
      #expect(prompt.contains("complete requested explanation in the same response"))
      #expect(prompt.contains("The host owns camera, reveal, speech timing and cancellation"))
      #expect(!prompt.contains(#"{"type":"target"#))
    }
    for route in [ResponsePolicy.Route.conversation, .screenGuidance] {
      let prompt = ReasoningProvider.baseInstructions(
        for: .init(route: route, includesExistingNotebook: false))
      #expect(!prompt.contains(guidelines))
    }
  }

  @Test func allDocumentedPrimitiveExamplesPassNativeGeometryAdmission() throws {
    let prompt = ReasoningProvider.baseInstructions(
      for: .init(route: .notebook, includesExistingNotebook: false))
    let expected: Set<String> = [
      "box", "sphere", "cylinder", "torus", "tube", "cone", "capsule", "lathe", "extrusion",
    ]
    var admitted: [String] = []
    for line in prompt.split(separator: "\n") {
      let text = line.trimmingCharacters(in: .whitespaces)
      guard text.hasPrefix(#"{"type":"#),
        let object = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any],
        let tag = object["type"] as? String, expected.contains(tag)
      else { continue }
      let geometry = try JSONDecoder().decode(Geometry3D.self, from: Data(text.utf8))
      let budget = try geometry.validatedBudget()
      #expect(budget.vertices > 0 && budget.triangles > 0)
      admitted.append(tag)
    }
    #expect(admitted.count == expected.count)
    #expect(Set(admitted) == expected)
    #expect(prompt.contains("Capsule height is total end-to-end height"))
    #expect(prompt.contains("The polygon closes implicitly from last to first"))
    #expect(prompt.contains("endpoint discs extending to the axis"))
  }

  @Test func notebookUsesOnlyTextSceneAndTypedSpatialContract() {
    for editing in [false, true] {
      let policy = ResponsePolicy(route: .notebook, includesExistingNotebook: editing)
      let prompt = ReasoningProvider.baseInstructions(for: policy)
      #expect(prompt.contains(#"{"type":"text","text":"#))
      #expect(prompt.contains(#"{"type":"scene","title":"#))
      #expect(prompt.contains("spatial3D.geometry"))
      #expect(prompt.contains("baseDocumentRevision"))
      #expect(prompt.contains("atomic valid transaction"))
      #expect(prompt.contains("focusID"))
      #expect(prompt.contains("exact stable node ID"))
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
