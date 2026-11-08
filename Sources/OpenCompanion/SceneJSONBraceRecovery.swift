import Foundation

/// A scene-only, one-byte structural recovery, never a general JSON repair.
/// Original and candidate bytes stay bounded; no EOF, string, array, comma,
/// key, value, coordinate or semantic repair is permitted.
enum SceneJSONBraceRecovery {
  static let maximumBytes = 262_144
  static let maximumNesting = 128

  static func recover(_ original: Data) throws -> ProviderUnit? {
    try Task.checkCancellation()
    guard !original.isEmpty, original.count <= maximumBytes,
      String(data: original, encoding: .utf8) != nil
    else { return nil }
    let bytes = Array(original)
    var originalSyntax = Syntax(bytes: bytes)
    guard try !originalSyntax.validate() else { return nil }
    var stack: [UInt8] = []
    var candidate: [UInt8] = []
    candidate.reserveCapacity(min(maximumBytes, bytes.count + 1))
    var quoted = false
    var escaped = false
    var edited = false
    var previousClosedObject = false
    for (index, byte) in bytes.enumerated() {
      if index.isMultiple(of: 4_096) { try Task.checkCancellation() }
      if quoted {
        candidate.append(byte)
        if escaped {
          escaped = false
        } else if byte == 92 {
          escaped = true
        } else if byte == 34 {
          quoted = false
        }
        continue
      }
      switch byte {
      case 34:
        quoted = true
        previousClosedObject = false
      case 123, 91:
        guard stack.count < maximumNesting else { return nil }
        stack.append(byte)
        previousClosedObject = false
      case 125:
        if stack.last == 123 {
          stack.removeLast()
          previousClosedObject = true
        } else {
          // Only an extra close immediately following a completed array
          // object is removable. A root close or value close is not guessed.
          guard !edited, stack.last == 91, previousClosedObject else { return nil }
          edited = true
          continue
        }
      case 93:
        if stack.last == 123 {
          // Exactly one object above its own array can be closed here. Never
          // unwind nested objects, finish an array, or repair the root at EOF.
          guard !edited, stack.count >= 2, stack[stack.count - 2] == 91 else { return nil }
          stack.removeLast()
          candidate.append(125)
          edited = true
        }
        guard stack.last == 91 else { return nil }
        stack.removeLast()
        previousClosedObject = false
      default:
        if !whitespace(byte) { previousClosedObject = false }
      }
      candidate.append(byte)
      guard candidate.count <= maximumBytes else { return nil }
    }
    guard edited, !quoted, !escaped, stack.isEmpty, candidate.count <= maximumBytes else {
      return nil
    }
    var recoveredSyntax = Syntax(bytes: candidate)
    guard try recoveredSyntax.validate() else { return nil }
    try Task.checkCancellation()
    guard let unit = try? JSONDecoder().decode(ProviderUnit.self, from: Data(candidate)),
      unit.type == "scene"
    else { return nil }
    try Task.checkCancellation()
    return unit
  }

  private static func whitespace(_ byte: UInt8) -> Bool {
    byte == 32 || byte == 9 || byte == 10 || byte == 13
  }

  /// Strict lexical JSON grammar, including trailing commas, number grammar,
  /// escapes and surrogate pairs. It supplies no values or decoder defaults.
  private struct Syntax {
    let bytes: [UInt8]
    var offset = 0
    var visits = 0

    mutating func validate() throws -> Bool {
      skipWhitespace()
      guard try value(depth: 0) else { return false }
      skipWhitespace()
      return offset == bytes.count
    }

    private mutating func value(depth: Int) throws -> Bool {
      visits += 1
      guard visits <= 65_536, depth < maximumNesting else { return false }
      try Task.checkCancellation()
      skipWhitespace()
      guard offset < bytes.count else { return false }
      switch bytes[offset] {
      case 123:
        offset += 1
        skipWhitespace()
        if consume(125) { return true }
        while true {
          guard string() else { return false }
          skipWhitespace()
          guard consume(58), try value(depth: depth + 1) else { return false }
          skipWhitespace()
          if consume(125) { return true }
          guard consume(44) else { return false }
          skipWhitespace()
        }
      case 91:
        offset += 1
        skipWhitespace()
        if consume(93) { return true }
        while true {
          guard try value(depth: depth + 1) else { return false }
          skipWhitespace()
          if consume(93) { return true }
          guard consume(44) else { return false }
        }
      case 34: return string()
      case 116: return literal([116, 114, 117, 101])
      case 102: return literal([102, 97, 108, 115, 101])
      case 110: return literal([110, 117, 108, 108])
      case 45, 48...57: return number()
      default: return false
      }
    }

    private mutating func string() -> Bool {
      guard consume(34) else { return false }
      while offset < bytes.count {
        let byte = bytes[offset]
        offset += 1
        if byte == 34 { return true }
        if byte < 32 { return false }
        if byte != 92 { continue }
        guard offset < bytes.count else { return false }
        let escaped = bytes[offset]
        offset += 1
        switch escaped {
        case 34, 92, 47, 98, 102, 110, 114, 116: break
        case 117:
          guard let scalar = hexQuad() else { return false }
          if (0xD800...0xDBFF).contains(scalar) {
            guard consume(92), consume(117), let low = hexQuad(),
              (0xDC00...0xDFFF).contains(low)
            else { return false }
          } else if (0xDC00...0xDFFF).contains(scalar) {
            return false
          }
        default: return false
        }
      }
      return false
    }

    private mutating func hexQuad() -> UInt32? {
      guard bytes.count - offset >= 4 else { return nil }
      var result: UInt32 = 0
      for _ in 0..<4 {
        let byte = bytes[offset]
        offset += 1
        let digit: UInt32
        switch byte {
        case 48...57: digit = UInt32(byte - 48)
        case 65...70: digit = UInt32(byte - 55)
        case 97...102: digit = UInt32(byte - 87)
        default: return nil
        }
        result = result * 16 + digit
      }
      return result
    }

    private mutating func number() -> Bool {
      _ = consume(45)
      if consume(48) {
      } else {
        guard offset < bytes.count, (49...57).contains(bytes[offset]) else { return false }
        repeat { offset += 1 } while offset < bytes.count && (48...57).contains(bytes[offset])
      }
      if consume(46) {
        guard digits() else { return false }
      }
      if consume(101) || consume(69) {
        if !consume(43) { _ = consume(45) }
        guard digits() else { return false }
      }
      return true
    }

    private mutating func digits() -> Bool {
      let start = offset
      while offset < bytes.count, (48...57).contains(bytes[offset]) { offset += 1 }
      return offset > start
    }

    private mutating func literal(_ expected: [UInt8]) -> Bool {
      guard bytes.count - offset >= expected.count,
        bytes[offset..<(offset + expected.count)].elementsEqual(expected)
      else { return false }
      offset += expected.count
      return true
    }

    private mutating func consume(_ byte: UInt8) -> Bool {
      guard offset < bytes.count, bytes[offset] == byte else { return false }
      offset += 1
      return true
    }

    private mutating func skipWhitespace() {
      while offset < bytes.count, whitespace(bytes[offset]) { offset += 1 }
    }
  }
}
