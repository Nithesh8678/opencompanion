import Foundation

/// A bounded lexer for one trusted root key containing an array of JSON objects.
/// It supplies complete object bytes; its consumer owns decoding and admission.
struct ObjectArrayStreamFramer: Sendable {
  static let maximumTotalBytes = 2_000_000
  static let maximumObjectBytes = 262_144
  static let maximumNesting = 32

  struct Object: Sendable {
    let data: Data
    let keys: Set<String>
  }

  private enum Phase: Sendable {
    case root, key, colon, array, firstObjectOrEnd, nextObject, object, separator, close, complete
  }
  private let rootKey: [UInt8]
  private let maximumObjects: Int
  private let allowedObjectKeys: Set<String>
  private var phase = Phase.root
  private var keyOffset = 0
  private var totalBytes = 0
  private var objectCount = 0
  private var buffer: [UInt8] = []
  private var containers: [UInt8] = []
  private var inString = false
  private var escaped = false
  private var expectingObjectKey = true
  private var objectKeyStart: Int?
  private var objectKeys: Set<String> = []
  private var failed = false
  private var finished = false

  init(rootKey: String, maximumObjects: Int, allowedObjectKeys: Set<String>) {
    precondition(rootKey == "units" || rootKey == "steps")
    precondition((1...96).contains(maximumObjects))
    self.rootKey = Array(("\"" + rootKey + "\"").utf8)
    self.maximumObjects = maximumObjects
    self.allowedObjectKeys = allowedObjectKeys
  }

  func beginAppend() throws {
    guard !failed, !finished else { throw Self.invalid("The stream has already ended.") }
    try Task.checkCancellation()
  }

  mutating func consume(_ byte: UInt8) throws -> Object? {
    guard !failed, !finished else { throw Self.invalid("The stream has already ended.") }
    guard totalBytes < Self.maximumTotalBytes else {
      throw Self.invalid("The envelope exceeded 2 MB.")
    }
    totalBytes += 1
    if totalBytes & 16_383 == 0 { try Task.checkCancellation() }
    if phase == .object { return try consumeObject(byte) }
    if Self.whitespace(byte), phase != .key || keyOffset == 0 { return nil }
    switch phase {
    case .root:
      guard byte == 123 else { throw Self.invalid("Expected the root object.") }
      phase = .key
    case .key:
      guard keyOffset < rootKey.count, byte == rootKey[keyOffset] else {
        throw Self.invalid("The envelope has an unexpected root key.")
      }
      keyOffset += 1
      if keyOffset == rootKey.count { phase = .colon }
    case .colon:
      guard byte == 58 else { throw Self.invalid("Expected the array separator.") }
      phase = .array
    case .array:
      guard byte == 91 else { throw Self.invalid("Expected the object array.") }
      phase = .firstObjectOrEnd
    case .firstObjectOrEnd:
      if byte == 93 {
        phase = .close
      } else {
        try beginObject(byte)
      }
    case .nextObject:
      try beginObject(byte)
    case .separator:
      if byte == 44 {
        phase = .nextObject
      } else if byte == 93 {
        phase = .close
      } else {
        throw Self.invalid("Expected another object or the array end.")
      }
    case .close:
      guard byte == 125 else {
        throw Self.invalid("Foreign or duplicate root fields are forbidden.")
      }
      phase = .complete
    case .complete:
      throw Self.invalid("Trailing content is forbidden.")
    case .object:
      throw Self.invalid("Invalid object framing state.")
    }
    return nil
  }

  mutating func finish() throws {
    guard !failed else { throw Self.invalid("The stream has already failed.") }
    try Task.checkCancellation()
    if finished { return }
    guard phase == .complete else { throw Self.invalid("The envelope was truncated.") }
    guard objectCount > 0 else { throw Self.invalid("At least one object is required.") }
    finished = true
    releaseBuffers()
  }

  mutating func fail() {
    failed = true
    releaseBuffers()
  }

  private mutating func beginObject(_ byte: UInt8) throws {
    guard byte == 123 else { throw Self.invalid("Each array member must be an object.") }
    guard objectCount < maximumObjects else { throw Self.invalid("Too many objects.") }
    buffer = [byte]
    containers = [byte]
    inString = false
    escaped = false
    expectingObjectKey = true
    objectKeyStart = nil
    objectKeys.removeAll(keepingCapacity: true)
    phase = .object
  }

  private mutating func consumeObject(_ byte: UInt8) throws -> Object? {
    guard buffer.count < Self.maximumObjectBytes else {
      throw Self.invalid("An object exceeded 256 KiB.")
    }
    buffer.append(byte)
    if inString {
      if escaped {
        escaped = false
      } else if byte == 92 {
        escaped = true
      } else if byte == 34 {
        inString = false
        if let start = objectKeyStart {
          let key: String
          do {
            key = try JSONDecoder().decode(String.self, from: Data(buffer[start...]))
          } catch {
            throw Self.invalid("Invalid object key.")
          }
          guard allowedObjectKeys.contains(key) else {
            throw Self.invalid("Foreign object fields are forbidden.")
          }
          guard objectKeys.insert(key).inserted else {
            throw Self.invalid("Duplicate object fields are forbidden.")
          }
          objectKeyStart = nil
          expectingObjectKey = false
        }
      }
      return nil
    }
    switch byte {
    case 34:
      inString = true
      if containers.count == 1, expectingObjectKey { objectKeyStart = buffer.count - 1 }
    case 44:
      if containers.count == 1 { expectingObjectKey = true }
    case 123, 91:
      guard containers.count < Self.maximumNesting else {
        throw Self.invalid("An object exceeded its nesting limit.")
      }
      containers.append(byte)
    case 125, 93:
      let opening: UInt8 = byte == 125 ? 123 : 91
      guard containers.last == opening else { throw Self.invalid("Mismatched object containers.") }
      containers.removeLast()
      if containers.isEmpty {
        let object = Object(data: Data(buffer), keys: objectKeys)
        buffer.removeAll(keepingCapacity: true)
        phase = .separator
        objectCount += 1
        return object
      }
    default:
      break
    }
    return nil
  }

  private mutating func releaseBuffers() {
    buffer.removeAll(keepingCapacity: false)
    containers.removeAll(keepingCapacity: false)
    objectKeys.removeAll(keepingCapacity: false)
    objectKeyStart = nil
  }

  private static func whitespace(_ byte: UInt8) -> Bool {
    byte == 32 || byte == 9 || byte == 10 || byte == 13
  }
  private static func invalid(_ detail: String) -> ProviderError {
    .message("Invalid structured stream. \(detail) Earlier accepted content was retained.")
  }
}
