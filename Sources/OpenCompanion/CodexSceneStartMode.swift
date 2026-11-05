import Foundation

/// An explicit latency experiment, independent of the selected model and wire
/// format. Ordinary callers retain their existing introduction-first prompt.
enum CodexSceneStartMode: String, Sendable {
  case introductionFirst, geometryFirst

  func validate(
    policy: ResponsePolicy, hasImage: Bool, hasScene: Bool, outputMode: CodexOutputMode
  ) throws {
    guard self == .geometryFirst else { return }
    guard outputMode == .ndjson, policy.allowsNotebook, !policy.includesExistingNotebook,
      !hasImage, !hasScene
    else {
      throw ProviderError.message(
        "Geometry-first output supports only a new standalone NDJSON explanation without an image or retained scene."
      )
    }
  }

  func usesGeometryFirstPrompt(for policy: ResponsePolicy) -> Bool {
    self == .geometryFirst && policy.allowsNotebook && !policy.includesExistingNotebook
  }
}
