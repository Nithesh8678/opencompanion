import CryptoKit
import Foundation
import Testing

@testable import OpenCompanion

struct CodexSceneStartModeTests {
  @Test func defaultPromptsRemainByteEquivalentToThePreAblationCheckpoint() {
    // SHA-256 snapshots of the complete UTF-8 prompts at 969c49b, before this
    // opt-in experiment. Compare against old bytes, not two new code paths.
    let cases: [(ResponsePolicy, String)] = [
      (
        .init(route: .conversation, includesExistingNotebook: false),
        "3315bc481a7c6114c06fe10a3144e2f59b44e5539410315ba4b7c7f390f6c220"
      ),
      (
        .init(route: .screenGuidance, includesExistingNotebook: false),
        "a975adb04605adf18c0dc80be5b1c5567fb45be703cdc3ccf818a4bac188e934"
      ),
      (
        .init(route: .notebook, includesExistingNotebook: false),
        "e27ab1ea72962d04e2b46b52edb402e3542cf27a4bc9dbcc0c6b92dfbb9e67c8"
      ),
      (
        .init(route: .notebook, includesExistingNotebook: true),
        "2d70ca24aef350de12937b55b7bc9265f81e744d1a237e7ccfe4ef09ce0c9dc3"
      ),
    ]
    for (policy, expected) in cases {
      let implicit = ReasoningProvider.baseInstructions(for: policy)
      let explicit = ReasoningProvider.baseInstructions(for: policy, sceneStart: .introductionFirst)
      #expect(implicit.utf8.elementsEqual(explicit.utf8))
      #expect(
        SHA256.hash(data: Data(implicit.utf8)).map { String(format: "%02x", $0) }.joined()
          == expected)
    }
  }

  @Test func candidateIsLimitedToTheNewStandaloneNdjsonScope() throws {
    let outputs: [CodexOutputMode] = [
      .ndjson, .structuredScene, .structuredUnifiedScene, .structuredSpatialSteps,
    ]
    let policies: [ResponsePolicy] = [
      .init(route: .conversation, includesExistingNotebook: false),
      .init(route: .screenGuidance, includesExistingNotebook: false),
      .init(route: .notebook, includesExistingNotebook: true),
      .init(route: .notebook, includesExistingNotebook: false),
    ]
    for output in outputs {
      for policy in policies {
        for image in [false, true] {
          for scene in [false, true] {
            try CodexSceneStartMode.introductionFirst.validate(
              policy: policy, hasImage: image, hasScene: scene, outputMode: output)
            let allowed =
              output == .ndjson && policy.allowsNotebook && !policy.includesExistingNotebook
              && !image && !scene
            if allowed {
              try CodexSceneStartMode.geometryFirst.validate(
                policy: policy, hasImage: image, hasScene: scene, outputMode: output)
            } else {
              #expect(throws: ProviderError.self) {
                try CodexSceneStartMode.geometryFirst.validate(
                  policy: policy, hasImage: image, hasScene: scene, outputMode: output)
              }
            }
          }
        }
      }
    }
  }

  @Test func geometryFirstRemovesIntroductionOrderingWithoutChangingSharedNativeContracts() {
    let policy = ResponsePolicy(route: .notebook, includesExistingNotebook: false)
    let original = ReasoningProvider.baseInstructions(for: policy)
    let candidate = ReasoningProvider.baseInstructions(for: policy, sceneStart: .geometryFirst)
    #expect(candidate != original)
    #expect(candidate.contains("FIRST complete output unit a small scene"))
    #expect(candidate.contains("brief attached narration, and focusID"))
    #expect(candidate.contains("complete the ENTIRE requested lesson in the SAME response"))
    #expect(candidate.contains("until every requested part and label has been included"))
    #expect(candidate.contains("Never stop after the first part or wait for a follow-up request"))
    #expect(!original.contains("complete the ENTIRE requested lesson in the SAME response"))
    #expect(candidate.contains("If no useful scene is appropriate, answer using text units only"))
    #expect(!candidate.contains("Start with one brief useful text unit"))
    #expect(!candidate.contains("Start with one brief text unit"))
    #expect(!candidate.contains("Standalone text units remain useful for the short introduction"))
    #expect(!candidate.contains("Use text to answer."))
    #expect(!candidate.contains(#"{"type":"target"#))

    // Everything outside the four explicitly changed ordering clauses must
    // remain verbatim: native schema, geometry/quality, revisions, narration,
    // bounded connectors, tool/privacy limits and permission are not ablated.
    let startupClauses = [
      "Start with one brief useful text unit in canonical type-then-text order. Follow with a small coherent visual relationship, then add useful detail progressively in separate complete scene units. A scene is permitted only when useful for the current requested explanation; it is never mandatory. Empty pages and generic titles are insufficient.",
      "Standalone text units remain useful for the short introduction or conclusion.",
      "Start with one brief text unit, then immediately emit a small first scene unit containing an assembly group and ONE physical part (at most two meshes).",
      "Use text to answer.",
    ]
    var unchangedPieces = [original]
    for clause in startupClauses {
      #expect(original.contains(clause))
      unchangedPieces = unchangedPieces.flatMap { $0.components(separatedBy: clause) }
    }
    for piece in unchangedPieces where !piece.isEmpty { #expect(candidate.contains(piece)) }
    #expect(candidate.contains("scene is permitted only if it materially helps"))
    #expect(candidate.contains("it is not mandatory"))
    #expect(candidate.contains("No retained notebook is authorized for editing."))
  }

  @Test func unsupportedPromptRoutesAndTextOnlyRequestsDoNotAcquireTheCandidate() {
    for policy in [
      ResponsePolicy(route: .conversation, includesExistingNotebook: false),
      .init(route: .screenGuidance, includesExistingNotebook: false),
      .init(route: .notebook, includesExistingNotebook: true),
    ] {
      #expect(
        ReasoningProvider.baseInstructions(for: policy, sceneStart: .geometryFirst)
          == ReasoningProvider.baseInstructions(for: policy))
    }
    let textOnly = ResponsePolicy.resolve(
      text: "Text only. Explain a motor without a diagram.", screenGuidanceEnabled: false)
    #expect(!textOnly.allowsNotebook)
    #expect(throws: ProviderError.self) {
      try CodexSceneStartMode.geometryFirst.validate(
        policy: textOnly, hasImage: false, hasScene: false, outputMode: .ndjson)
    }
  }
}
