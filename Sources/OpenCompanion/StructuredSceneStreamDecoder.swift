import Foundation

/// Opt-in new-scene envelope framing. A complete unit is only a proposal;
/// its awaited host callback still owns semantic admission and generation checks.
struct StructuredSceneStreamDecoder: Sendable {
  static let maximumTotalBytes = ObjectArrayStreamFramer.maximumTotalBytes
  static let maximumUnitBytes = ObjectArrayStreamFramer.maximumObjectBytes
  static let maximumTextBytes = 32_000
  static let maximumUnits = 96
  static let maximumNesting = ObjectArrayStreamFramer.maximumNesting

  private static let textKeys: Set<String> = ["type", "text"]
  private static let sceneKeys: Set<String> = ["type", "title", "nodes", "removeIDs", "animations"]
  private var framer = ObjectArrayStreamFramer(
    rootKey: "units", maximumObjects: maximumUnits,
    allowedObjectKeys: textKeys.union(sceneKeys))
  private(set) var acceptedUnits = 0

  mutating func append(
    _ delta: String,
    onUnit: @Sendable (ProviderUnit) async throws -> Void,
    onText: (@Sendable (ProviderTextPreview) async throws -> Void)? = nil
  ) async throws {
    do {
      try framer.beginAppend()
      for byte in delta.utf8 {
        guard let object = try framer.consume(byte) else { continue }
        let value: ProviderUnit
        do {
          value = try JSONDecoder().decode(ProviderUnit.self, from: object.data)
        } catch {
          throw Self.invalid("A unit did not match the scene protocol.")
        }
        guard value.type == "text" || value.type == "scene" else {
          throw Self.invalid("Only text and scene units are permitted.")
        }
        let allowed = value.type == "text" ? Self.textKeys : Self.sceneKeys
        guard object.keys.isSubset(of: allowed) else {
          throw Self.invalid("Mixed text and scene fields are forbidden.")
        }
        if value.type == "text" {
          guard let text = value.text, !text.isEmpty, text.utf8.count <= Self.maximumTextBytes
          else {
            throw Self.invalid("Invalid or oversized text unit.")
          }
        }
        try Task.checkCancellation()
        if value.type == "text", let text = value.text, let onText {
          try await onText(.init(unitID: acceptedUnits, text: text, isComplete: true))
        }
        try Task.checkCancellation()
        try await onUnit(value)
        acceptedUnits += 1
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

  private static func invalid(_ detail: String) -> ProviderError {
    .message("Invalid structured scene stream. \(detail) Earlier accepted content was retained.")
  }
}
