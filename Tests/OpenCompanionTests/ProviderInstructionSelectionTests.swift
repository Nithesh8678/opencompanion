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
      #expect(prompt.contains("Omit whole identity transforms, whole optional identity vectors"))
      #expect(prompt.contains("never omit individual components from a present vector"))
      #expect(prompt.contains("Every present 3D vector must contain x, y and z"))
      #expect(prompt.contains("Keep one stable overall lesson title"))
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

  @Test func documentedCompactTransformRetainsEveryRequiredVectorComponent() throws {
    let policy = ResponsePolicy(route: .notebook, includesExistingNotebook: false)
    for prompt in [
      ReasoningProvider.baseInstructions(for: policy),
      ReasoningProvider.baseInstructions(for: policy, sceneStart: .geometryFirst),
      ReasoningProvider.standaloneStructuredSceneInstructions(for: policy),
    ] {
      let marker = "Compact transform example: "
      let line = try #require(
        prompt.split(separator: "\n").map(String.init).first { $0.hasPrefix(marker) })
      let data = Data(line.dropFirst(marker.count).utf8)
      let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
      for key in ["position", "rotationDegrees", "scale"] {
        if let vector = object[key] as? [String: Any] {
          #expect(Set(vector.keys) == ["x", "y", "z"])
        }
      }
      let transform = try JSONDecoder().decode(Transform3D.self, from: data)
      #expect(transform.position == .zero && transform.scale == .one)
      #expect(transform.rotationDegrees == .init(x: 90, y: 0, z: 0))
    }
    // Compact output cannot silently change the native vector contract.
    for key in ["position", "rotationDegrees", "scale"] {
      let incomplete = Data("{\"\(key)\":{\"x\":90}}".utf8)
      #expect(throws: DecodingError.self) {
        try JSONDecoder().decode(Transform3D.self, from: incomplete)
      }
    }
  }

  @Test func visualQualityGuidelinesAreSharedAcrossSpatialFormatsWithoutGrantingOtherRoutes() {
    let policy = ResponsePolicy(route: .notebook, includesExistingNotebook: false)
    let guidelines = ReasoningProvider.spatialVisualQualityGuidelines
    // Keep this shared design guidance concise; protocol details live separately.
    #expect(guidelines.utf8.count <= 4_000)
    let ordinary = [
      ReasoningProvider.baseInstructions(for: policy),
      ReasoningProvider.baseInstructions(for: policy, sceneStart: .geometryFirst),
      ReasoningProvider.standaloneStructuredSceneInstructions(for: policy),
    ]
    for prompt in ordinary {
      #expect(prompt.components(separatedBy: guidelines).count == 2)
      #expect(prompt.contains("up to eight related new meshes"))
    }
    for prompt in ordinary + [ReasoningProvider.standaloneStructuredSpatialStepsInstructions] {
      #expect(prompt.contains("recognisable topic silhouette"))
      #expect(prompt.contains("A smaller mesh count is not a quality goal"))
      #expect(prompt.contains("A head on one featureless tube still lacks segmentation"))
      #expect(!prompt.contains("one to three NEW physical parts"))
      #expect(prompt.contains("differentiated head/body regions, segmentation"))
      #expect(prompt.contains("not a fixed number"))
      #expect(prompt.contains("including the return transition for a cycle"))
      #expect(prompt.contains("static rod connectors alone do not show direction"))
      #expect(!prompt.lowercased().contains("butterfly"))
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

  @Test func spatialStepsBatchingGuidanceMatchesItsStrictThreePartAdmission() throws {
    let prompt = ReasoningProvider.standaloneStructuredSpatialStepsInstructions
    #expect(prompt.contains("up to three related new meshes"))
    #expect(prompt.contains("one to three physical parts"))
    #expect(!prompt.contains("up to eight related new meshes"))
    for count in [3, 4] {
      let parts: [JSONValue] = (0..<count).map { index in
        .object([
          "id": .string("part-\(index)"), "parentID": .null,
          "fill": .string("#4488CC"), "opacity": .null, "transform": .null,
          "geometry": .object([
            "type": .string("sphere"), "radius": .number(0.1), "segments": .number(12),
          ]),
        ])
      }
      let step = JSONValue.object([
        "text": .string("The stage introduces related parts."), "title": .null,
        "groups": .array([]), "parts": .array(parts), "labels": .array([]),
        "animations": .array([]), "removeIDs": .array([]),
      ])
      let data = try JSONEncoder().encode(step)
      if count == 3 {
        let compiled = try StructuredSpatialStageCompiler.compile(data)
        let document = try ProviderSceneBoundary.applying(
          compiled.scene, to: SceneDocument(), baseRevision: 0)
        #expect(document.nodes.count == 3)
      } else {
        #expect(throws: (any Error).self) { try StructuredSpatialStageCompiler.compile(data) }
      }
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
