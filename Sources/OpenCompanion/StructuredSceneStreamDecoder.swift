import Foundation

/// Opt-in new-scene envelope framing. A complete unit is only a proposal;
/// its awaited host callback still owns semantic admission and generation checks.
struct StructuredSceneStreamDecoder: Sendable {
  static let maximumTotalBytes = 2_000_000
  static let maximumUnitBytes = 262_144
  static let maximumTextBytes = 32_000
  static let maximumUnits = 96
  static let maximumNesting = 32

  private enum Phase: Sendable {
    case root, key, colon, array, firstUnitOrEnd, nextUnit, unit, separator, close, complete
  }
  private static let rootKey = Array("\"units\"".utf8)
  private static let textKeys: Set<String> = ["type", "text"]
  private static let sceneKeys: Set<String> = ["type", "title", "nodes", "removeIDs", "animations"]
  private var phase = Phase.root
  private var keyOffset = 0
  private var totalBytes = 0
  private var unit: [UInt8] = []
  private var containers: [UInt8] = []
  private var inString = false
  private var escaped = false
  private var expectingUnitKey = true
  private var unitKeyStart: Int?
  private var unitKeys: Set<String> = []
  private var failed = false
  private var finished = false
  private(set) var acceptedUnits = 0

  mutating func append(
    _ delta: String,
    onUnit: @Sendable (ProviderUnit) async throws -> Void,
    onText: (@Sendable (ProviderTextPreview) async throws -> Void)? = nil
  ) async throws {
    do {
      guard !failed, !finished else { throw Self.invalid("The stream has already ended.") }
      try Task.checkCancellation()
      for byte in delta.utf8 {
        guard totalBytes < Self.maximumTotalBytes else {
          throw Self.invalid("The envelope exceeded 2 MB.")
        }
        totalBytes += 1
        if totalBytes & 16_383 == 0 { try Task.checkCancellation() }
        if let value = try consume(byte) {
          try Task.checkCancellation()
          if value.type == "text", let text = value.text, let onText {
            try await onText(.init(unitID: acceptedUnits, text: text, isComplete: true))
          }
          try Task.checkCancellation()
          try await onUnit(value)
          acceptedUnits += 1
          try Task.checkCancellation()
        }
      }
    } catch {
      terminate()
      throw error
    }
  }

  mutating func finish(
    onUnit: @Sendable (ProviderUnit) async throws -> Void,
    onText: (@Sendable (ProviderTextPreview) async throws -> Void)? = nil
  ) async throws {
    do {
      guard !failed else { throw Self.invalid("The stream has already failed.") }
      try Task.checkCancellation()
      if finished { return }
      guard phase == .complete else { throw Self.invalid("The envelope was truncated.") }
      guard acceptedUnits > 0 else { throw Self.invalid("At least one unit is required.") }
      finished = true
      unit.removeAll(keepingCapacity: false)
      containers.removeAll(keepingCapacity: false)
    } catch {
      terminate()
      throw error
    }
  }

  private mutating func consume(_ byte: UInt8) throws -> ProviderUnit? {
    if phase == .unit { return try consumeUnit(byte) }
    if Self.whitespace(byte), phase != .key || keyOffset == 0 { return nil }
    switch phase {
    case .root:
      guard byte == 123 else { throw Self.invalid("Expected the root object.") }
      phase = .key
    case .key:
      guard keyOffset < Self.rootKey.count, byte == Self.rootKey[keyOffset] else {
        throw Self.invalid("The only root key is units.")
      }
      keyOffset += 1
      if keyOffset == Self.rootKey.count { phase = .colon }
    case .colon:
      guard byte == 58 else { throw Self.invalid("Expected the units separator.") }
      phase = .array
    case .array:
      guard byte == 91 else { throw Self.invalid("Expected the units array.") }
      phase = .firstUnitOrEnd
    case .firstUnitOrEnd:
      if byte == 93 {
        phase = .close
      } else {
        try beginUnit(byte)
      }
    case .nextUnit:
      try beginUnit(byte)
    case .separator:
      if byte == 44 {
        phase = .nextUnit
      } else if byte == 93 {
        phase = .close
      } else {
        throw Self.invalid("Expected another unit or the array end.")
      }
    case .close:
      guard byte == 125 else {
        throw Self.invalid("Foreign or duplicate root fields are forbidden.")
      }
      phase = .complete
    case .complete:
      throw Self.invalid("Trailing content is forbidden.")
    case .unit:
      throw Self.invalid("Invalid unit framing state.")
    }
    return nil
  }

  private mutating func beginUnit(_ byte: UInt8) throws {
    guard byte == 123 else { throw Self.invalid("Each unit must be an object.") }
    guard acceptedUnits < Self.maximumUnits else { throw Self.invalid("Too many units.") }
    unit = [byte]
    containers = [byte]
    inString = false
    escaped = false
    expectingUnitKey = true
    unitKeyStart = nil
    unitKeys.removeAll(keepingCapacity: true)
    phase = .unit
  }

  private mutating func consumeUnit(_ byte: UInt8) throws -> ProviderUnit? {
    guard unit.count < Self.maximumUnitBytes else { throw Self.invalid("A unit exceeded 256 KiB.") }
    unit.append(byte)
    if inString {
      if escaped {
        escaped = false
      } else if byte == 92 {
        escaped = true
      } else if byte == 34 {
        inString = false
        if let start = unitKeyStart {
          let key: String
          do {
            key = try JSONDecoder().decode(String.self, from: Data(unit[start...]))
          } catch {
            throw Self.invalid("Invalid unit key.")
          }
          guard Self.textKeys.contains(key) || Self.sceneKeys.contains(key) else {
            throw Self.invalid("Foreign unit fields are forbidden.")
          }
          guard unitKeys.insert(key).inserted else {
            throw Self.invalid("Duplicate unit fields are forbidden.")
          }
          unitKeyStart = nil
          expectingUnitKey = false
        }
      }
      return nil
    }
    switch byte {
    case 34:
      inString = true
      if containers.count == 1, expectingUnitKey { unitKeyStart = unit.count - 1 }
    case 44:
      if containers.count == 1 { expectingUnitKey = true }
    case 123, 91:
      guard containers.count < Self.maximumNesting else {
        throw Self.invalid("A unit exceeded its nesting limit.")
      }
      containers.append(byte)
    case 125, 93:
      let opening: UInt8 = byte == 125 ? 123 : 91
      guard containers.last == opening else { throw Self.invalid("Mismatched unit containers.") }
      containers.removeLast()
      if containers.isEmpty {
        let data = Data(unit)
        unit.removeAll(keepingCapacity: true)
        phase = .separator
        let value: ProviderUnit
        do {
          value = try JSONDecoder().decode(ProviderUnit.self, from: data)
        } catch {
          throw Self.invalid("A unit did not match the scene protocol.")
        }
        guard value.type == "text" || value.type == "scene" else {
          throw Self.invalid("Only text and scene units are permitted.")
        }
        let allowed = value.type == "text" ? Self.textKeys : Self.sceneKeys
        guard unitKeys.isSubset(of: allowed) else {
          throw Self.invalid("Mixed text and scene fields are forbidden.")
        }
        if value.type == "text" {
          guard let text = value.text, !text.isEmpty, text.utf8.count <= Self.maximumTextBytes
          else {
            throw Self.invalid("Invalid or oversized text unit.")
          }
        }
        return value
      }
    default:
      break
    }
    return nil
  }

  private mutating func terminate() {
    failed = true
    unit.removeAll(keepingCapacity: false)
    containers.removeAll(keepingCapacity: false)
    unitKeys.removeAll(keepingCapacity: false)
    unitKeyStart = nil
  }
  private static func whitespace(_ byte: UInt8) -> Bool {
    byte == 32 || byte == 9 || byte == 10 || byte == 13
  }
  private static func invalid(_ detail: String) -> ProviderError {
    .message("Invalid structured scene stream. \(detail) Earlier accepted content was retained.")
  }
}
