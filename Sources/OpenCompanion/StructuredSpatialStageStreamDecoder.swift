import Foundation

/// Callback admission counts only, never native pixels or speech completion.
struct StructuredSpatialStageProgress: Codable, Sendable, Equatable {
  /// Strictly compiled whole wire stages, before native scene admission.
  let decodedStages: Int
  let admittedSceneUnits: Int
  let admittedTextUnits: Int
  let completedStages: Int
}

/// Narration cannot be released until its stage's scene callback succeeds.
/// A later failure retains admitted units and terminally prevents replay.
struct StructuredSpatialStageStreamDecoder: Sendable {
  static let maximumTotalBytes = ObjectArrayStreamFramer.maximumTotalBytes
  static let maximumStageBytes = ObjectArrayStreamFramer.maximumObjectBytes
  static let maximumStages = 48
  static let maximumNesting = ObjectArrayStreamFramer.maximumNesting

  private var framer = ObjectArrayStreamFramer(
    rootKey: "steps", maximumObjects: maximumStages,
    allowedObjectKeys: ["text", "title", "groups", "parts", "labels", "animations", "removeIDs"])
  private(set) var decodedStages = 0
  private(set) var admittedSceneUnits = 0
  private(set) var admittedTextUnits = 0
  private(set) var completedStages = 0
  var acceptedUnits: Int { admittedSceneUnits + admittedTextUnits }
  var progress: StructuredSpatialStageProgress {
    .init(
      decodedStages: decodedStages, admittedSceneUnits: admittedSceneUnits,
      admittedTextUnits: admittedTextUnits, completedStages: completedStages)
  }

  mutating func append(
    _ delta: String,
    onUnit: @Sendable (ProviderUnit) async throws -> Void,
    onText: (@Sendable (ProviderTextPreview) async throws -> Void)? = nil
  ) async throws {
    do {
      try framer.beginAppend()
      for byte in delta.utf8 {
        guard let object = try framer.consume(byte) else { continue }
        try Task.checkCancellation()
        let stage = try StructuredSpatialStageCompiler.compile(object.data)
        decodedStages += 1
        try Task.checkCancellation()
        try await onUnit(stage.scene)
        admittedSceneUnits += 1
        try Task.checkCancellation()
        if let text = stage.text.text, let onText {
          try await onText(.init(unitID: acceptedUnits, text: text, isComplete: true))
        }
        try Task.checkCancellation()
        try await onUnit(stage.text)
        admittedTextUnits += 1
        completedStages += 1
        try Task.checkCancellation()
      }
    } catch {
      framer.fail()
      throw error
    }
  }

  mutating func finish(
    onUnit: @Sendable (ProviderUnit) async throws -> Void,
    onText: (@Sendable (ProviderTextPreview) async throws -> Void)? = nil
  ) async throws {
    do {
      try framer.finish()
    } catch {
      framer.fail()
      throw error
    }
  }
}
