import Foundation

/// Ephemeral presentation only. Canonical chat and every structured action still
/// require the separately decoded, complete ProviderUnit delivered to onUnit.
struct ProviderTextPreview: Sendable, Equatable {
  let unitID: Int
  let text: String
  let isComplete: Bool
}

/// Shared NDJSON framing for both provider transports. Only the final unfinished
/// line can emit a partial preview, once per append (transport delta). Complete
/// validated text lines always emit a final preview before their canonical unit.
struct ProviderTextStreamDecoder: Sendable {
  static let maximumLineBytes = 262_144
  static let maximumTextBytes = 32_000

  private var line: [UInt8] = []
  private var prefix = TextJSONPrefix()
  private var lastPreviewBytes = 0
  private(set) var acceptedUnits = 0

  mutating func append(
    _ delta: String,
    onUnit: @Sendable (ProviderUnit) async throws -> Void,
    onText: (@Sendable (ProviderTextPreview) async throws -> Void)? = nil
  ) async throws {
    try Task.checkCancellation()
    for byte in delta.utf8 {
      if byte == 10 {
        if let unit = try finishLine() {
          try await deliver(unit, onUnit: onUnit, onText: onText)
        }
      } else {
        guard line.count < Self.maximumLineBytes else {
          throw ProviderError.message("A response unit exceeded 256 KiB.")
        }
        line.append(byte)
        prefix.append(byte)
      }
    }
    if let text = prefix.preview, prefix.textBytes > lastPreviewBytes, let onText {
      try Task.checkCancellation()
      lastPreviewBytes = prefix.textBytes
      try await onText(.init(unitID: acceptedUnits, text: text, isComplete: false))
    }
  }

  mutating func finish(
    onUnit: @Sendable (ProviderUnit) async throws -> Void,
    onText: (@Sendable (ProviderTextPreview) async throws -> Void)? = nil
  ) async throws {
    try Task.checkCancellation()
    if let unit = try finishLine() {
      try await deliver(unit, onUnit: onUnit, onText: onText)
    }
  }

  private mutating func finishLine() throws -> ProviderUnit? {
    let value = String(decoding: line, as: UTF8.self)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    line.removeAll(keepingCapacity: true)
    prefix = TextJSONPrefix()
    lastPreviewBytes = 0
    guard !value.isEmpty else { return nil }
    let unit: ProviderUnit
    do {
      unit = try JSONDecoder().decode(ProviderUnit.self, from: Data(value.utf8))
    } catch {
      throw ProviderError.message(
        "Model output did not match the line protocol. Accepted earlier content was retained.")
    }
    if unit.type == "text" {
      guard let text = unit.text, text.utf8.count <= Self.maximumTextBytes else {
        throw ProviderError.message("Invalid or oversized text unit.")
      }
    }
    return unit
  }

  private mutating func deliver(
    _ unit: ProviderUnit,
    onUnit: @Sendable (ProviderUnit) async throws -> Void,
    onText: (@Sendable (ProviderTextPreview) async throws -> Void)?
  ) async throws {
    let unitID = acceptedUnits
    try Task.checkCancellation()
    if unit.type == "text", let text = unit.text, let onText {
      try await onText(.init(unitID: unitID, text: text, isComplete: true))
    }
    try Task.checkCancellation()
    try await onUnit(unit)
    acceptedUnits += 1
  }
}

/// A byte-level, append-only recognizer for exactly this ordered JSON shape:
/// {"type":"text","text":"..."}. JSON whitespace between tokens is allowed.
/// Unsupported syntax disables previews for this line; complete-line decoding
/// remains authoritative. No partial object, command or escape is evaluated.
private struct TextJSONPrefix: Sendable {
  private enum State: Sendable {
    case token, string, escape, unicode, surrogateSlash, surrogateU, utf8, tail, done, disabled
  }
  private static let tokens = ["{", "\"type\"", ":", "\"text\"", ",", "\"text\"", ":", "\""]
    .map { Array($0.utf8) }
  private var state = State.token
  private var token = 0
  private var tokenOffset = 0
  private var text = ""
  private(set) var textBytes = 0
  private var unicodeValue: UInt32 = 0
  private var unicodeDigits = 0
  private var highSurrogate: UInt32?
  private var utf8Bytes: [UInt8] = []
  private var expectedUTF8Bytes = 0

  var preview: String? { state != .disabled && textBytes > 0 ? text : nil }

  mutating func append(_ byte: UInt8) {
    switch state {
    case .token:
      if tokenOffset == 0 && Self.isWhitespace(byte) { return }
      let expected = Self.tokens[token]
      guard byte == expected[tokenOffset] else { disable(); return }
      tokenOffset += 1
      if tokenOffset == expected.count {
        token += 1
        tokenOffset = 0
        if token == Self.tokens.count { state = .string }
      }
    case .string:
      switch byte {
      case 34: state = .tail
      case 92: state = .escape
      case 0..<32: disable()
      case 32..<128: appendScalar(UInt32(byte))
      case 0xC2...0xDF: startUTF8(byte, count: 2)
      case 0xE0...0xEF: startUTF8(byte, count: 3)
      case 0xF0...0xF4: startUTF8(byte, count: 4)
      default: disable()
      }
    case .escape:
      switch byte {
      case 34, 47, 92: appendScalar(UInt32(byte)); resumeString()
      case 98: appendScalar(8); resumeString()
      case 102: appendScalar(12); resumeString()
      case 110: appendScalar(10); resumeString()
      case 114: appendScalar(13); resumeString()
      case 116: appendScalar(9); resumeString()
      case 117:
        unicodeValue = 0
        unicodeDigits = 0
        state = .unicode
      default: disable()
      }
    case .unicode:
      guard let hex = Self.hex(byte) else { disable(); return }
      unicodeValue = unicodeValue * 16 + hex
      unicodeDigits += 1
      if unicodeDigits == 4 { finishUnicode() }
    case .surrogateSlash:
      guard byte == 92 else { disable(); return }
      state = .surrogateU
    case .surrogateU:
      guard byte == 117 else { disable(); return }
      unicodeValue = 0
      unicodeDigits = 0
      state = .unicode
    case .utf8:
      guard (0x80...0xBF).contains(byte) else { disable(); return }
      utf8Bytes.append(byte)
      if utf8Bytes.count == expectedUTF8Bytes {
        guard let decoded = String(bytes: utf8Bytes, encoding: .utf8),
          decoded.unicodeScalars.count == 1, let scalar = decoded.unicodeScalars.first
        else { disable(); return }
        appendScalar(scalar.value)
        utf8Bytes.removeAll(keepingCapacity: true)
        resumeString()
      }
    case .tail:
      if Self.isWhitespace(byte) { return }
      guard byte == 125 else { disable(); return }
      state = .done
    case .done:
      if !Self.isWhitespace(byte) { disable() }
    case .disabled: break
    }
  }

  private mutating func startUTF8(_ byte: UInt8, count: Int) {
    utf8Bytes = [byte]
    expectedUTF8Bytes = count
    state = .utf8
  }

  private mutating func finishUnicode() {
    if let highSurrogate {
      guard (0xDC00...0xDFFF).contains(unicodeValue) else { disable(); return }
      let scalar = 0x10000 + (highSurrogate - 0xD800) * 0x400 + unicodeValue - 0xDC00
      self.highSurrogate = nil
      appendScalar(scalar)
      resumeString()
    } else if (0xD800...0xDBFF).contains(unicodeValue) {
      highSurrogate = unicodeValue
      state = .surrogateSlash
    } else if (0xDC00...0xDFFF).contains(unicodeValue) {
      disable()
    } else {
      appendScalar(unicodeValue)
      resumeString()
    }
  }

  private mutating func appendScalar(_ value: UInt32) {
    guard let scalar = UnicodeScalar(value) else { disable(); return }
    let amount = scalar.utf8.count
    guard textBytes <= ProviderTextStreamDecoder.maximumTextBytes - amount else {
      disable()
      return
    }
    text.unicodeScalars.append(scalar)
    textBytes += amount
  }

  private mutating func resumeString() { if state != .disabled { state = .string } }
  private mutating func disable() { state = .disabled }

  private static func isWhitespace(_ byte: UInt8) -> Bool {
    byte == 32 || byte == 9 || byte == 13
  }
  private static func hex(_ byte: UInt8) -> UInt32? {
    switch byte {
    case 48...57: UInt32(byte - 48)
    case 65...70: UInt32(byte - 65 + 10)
    case 97...102: UInt32(byte - 97 + 10)
    default: nil
    }
  }
}
