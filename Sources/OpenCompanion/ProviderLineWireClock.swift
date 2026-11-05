import Foundation

/// Client-observed framing only. Classification happens after the decoder's one
/// authoritative JSON decode; this value contains no response or prompt content.
struct ProviderLineWireSample: Codable, Sendable, Equatable {
  enum Termination: String, Codable, Sendable { case newline, endOfStream }
  let startedUptime: Double
  let completedUptime: Double
  let utf8Bytes: Int
  let termination: Termination
}

/// Constant storage alongside the existing bounded NDJSON line buffer. One
/// append-entry timestamp may describe many bytes already received together.
struct ProviderLineWireClock: Sendable {
  static let maximumLineBytes = 262_144
  private var started: Double?
  private var lastObserved: Double?
  private var byteCount = 0
  private var invalid = false

  mutating func appendByte(observedAt uptime: Double) {
    if byteCount <= Self.maximumLineBytes { byteCount += 1 }
    guard !invalid, byteCount <= Self.maximumLineBytes,
      uptime.isFinite, uptime >= 0,
      lastObserved.map({ uptime >= $0 }) ?? true
    else {
      invalid = true
      return
    }
    if started == nil { started = uptime }
    lastObserved = uptime
  }

  /// LF is the boundary, not a counted response byte. CR remains a raw byte.
  /// EOF is explicitly different and must not be reported as newline framing.
  mutating func finishLine(
    observedAt uptime: Double, termination: ProviderLineWireSample.Termination
  ) -> ProviderLineWireSample? {
    defer { reset() }
    guard !invalid, byteCount > 0, byteCount <= Self.maximumLineBytes,
      let started, let lastObserved, uptime.isFinite,
      uptime >= lastObserved, uptime >= started
    else { return nil }
    return .init(
      startedUptime: started, completedUptime: uptime, utf8Bytes: byteCount,
      termination: termination)
  }

  mutating func reset() {
    started = nil
    lastObserved = nil
    byteCount = 0
    invalid = false
  }
}
