import CoreGraphics
import Foundation

/// An observation bound to one capture, rather than a persistent element handle.
/// All geometry uses the capture's normalized, top-left coordinate space.
struct ScreenGroundingCandidate: Codable, Sendable, Equatable {
  enum Source: String, Codable, Sendable {
    case accessibility, ocr
  }

  let id: String
  let source: Source
  let role: String
  let label: String
  let enabled: Bool
  let actionable: Bool
  let x: Double
  let y: Double
  let width: Double
  let height: Double
}

enum ScreenGrounding {
  static let maximumCandidates = 120
  static let maximumContextBytes = 24_000

  /// Empty AX titles must not hide useful descriptions or help text. The byte
  /// limit also bounds labels consisting of unusually large Unicode clusters.
  static func firstNonemptyLabel(_ values: [String?], limit: Int = 180) -> String {
    guard limit > 0 else { return "" }
    for value in values {
      guard let value else { continue }
      // Bound work before trimming or segmenting graphemes. A hostile AX value
      // can contain one enormous combining sequence or arbitrarily much space.
      let bytes = Array(value.utf8.prefix(8_192))
      var end = bytes.count
      var prefix = ""
      for _ in 0..<4 {
        if let valid = String(bytes: bytes.prefix(end), encoding: .utf8) {
          prefix = valid
          break
        }
        guard end > 0 else { break }
        end -= 1
      }
      let trimmed = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
      let label = boundedText(trimmed, characters: min(limit, 2_048), bytes: 2_048)
      if !label.isEmpty { return label }
    }
    return ""
  }

  /// AX global coordinates originate at the primary display's top-left. Convert
  /// into AppKit global coordinates before normalizing against the exact crop.
  /// A partially intersecting control is not admitted as a complete target.
  static func normalizedAXRect(
    _ rect: CGRect, primaryTop: Double, sourceRect: CGRect
  ) -> CGRect? {
    guard validRect(rect), validRect(sourceRect), primaryTop.isFinite else { return nil }
    let appKitBottom = primaryTop - rect.maxY
    let appKitTop = primaryTop - rect.minY
    guard appKitBottom.isFinite, appKitTop.isFinite,
      rect.minX >= sourceRect.minX, rect.maxX <= sourceRect.maxX,
      appKitBottom >= sourceRect.minY, appKitTop <= sourceRect.maxY
    else { return nil }
    let normalized = CGRect(
      x: (rect.minX - sourceRect.minX) / sourceRect.width,
      y: (sourceRect.maxY - appKitTop) / sourceRect.height,
      width: rect.width / sourceRect.width, height: rect.height / sourceRect.height)
    return validNormalizedRect(normalized) ? normalized : nil
  }

  /// Vision text observations use normalized bottom-left coordinates. OCR boxes
  /// describe text only; this conversion does not make them actionable controls.
  static func normalizedOCRRect(_ visionRect: CGRect) -> CGRect? {
    guard validNormalizedRect(visionRect) else { return nil }
    let normalized = CGRect(
      x: visionRect.minX, y: 1 - visionRect.maxY,
      width: visionRect.width, height: visionRect.height)
    return validNormalizedRect(normalized) ? normalized : nil
  }

  static func candidateID(frameID: UUID, index: Int) -> String {
    "\(candidatePrefix(frameID))\(index)"
  }

  /// Retain this exact table in ScreenEvidence, then serialize and resolve from
  /// it. IDs are preserved. Ambiguous duplicate IDs are omitted entirely.
  static func boundedCandidates(
    _ candidates: [ScreenGroundingCandidate], frameID: UUID
  ) -> [ScreenGroundingCandidate] {
    // Native collectors are bounded separately; cap this boundary as well.
    let inspected = candidates.prefix(1_024)
    var occurrences: [String: Int] = [:]
    for candidate in inspected { occurrences[candidate.id, default: 0] += 1 }
    var retained: [ScreenGroundingCandidate] = []
    let encoder = contextEncoder()
    guard let empty = try? encoder.encode(Context(frameID: frameID, candidates: [])) else {
      return []
    }
    var byteCount = empty.count
    for candidate in inspected {
      guard retained.count < maximumCandidates else { break }
      guard occurrences[candidate.id] == 1, validCandidate(candidate, frameID: frameID) else {
        continue
      }
      let bounded = ScreenGroundingCandidate(
        id: candidate.id, source: candidate.source,
        role: firstNonemptyLabel([candidate.role], limit: 80),
        label: firstNonemptyLabel([candidate.label]), enabled: candidate.enabled,
        actionable: candidate.actionable,
        x: candidate.x, y: candidate.y, width: candidate.width, height: candidate.height)
      guard let data = try? encoder.encode(bounded) else { continue }
      let addition = data.count + (retained.isEmpty ? 0 : 1)
      guard byteCount + addition <= maximumContextBytes else { continue }
      retained.append(bounded)
      byteCount += addition
    }
    return retained
  }

  /// JSON data, never instructions. The envelope states the coordinate owner.
  static func evidenceContext(
    candidates: [ScreenGroundingCandidate], frameID: UUID
  ) -> String {
    let bounded = boundedCandidates(candidates, frameID: frameID)
    let data = try? contextEncoder().encode(Context(frameID: frameID, candidates: bounded))
    guard let data, data.count <= maximumContextBytes,
      let text = String(data: data, encoding: .utf8)
    else { return "{}" }
    return text
  }

  /// Candidate selection grants no action capability. Native geometry replaces
  /// the model's guessed box; rendering and freshness guards still apply later.
  static func resolve(
    _ payload: ProviderTarget, candidates: [ScreenGroundingCandidate], frameID: UUID,
    imagePixelSize: CGSize? = nil
  ) throws -> ProviderTarget {
    if let pixels = payload.pixelBounds {
      guard payload.candidateID == nil,
        payload.x == 0, payload.y == 0, payload.width == 0, payload.height == 0,
        let size = imagePixelSize,
        size.width.isFinite, size.height.isFinite,
        size.width > 0, size.height > 0,
        size.width <= ScreenImageGeometry.maximumDimension,
        size.height <= ScreenImageGeometry.maximumDimension,
        size.width.rounded(.towardZero) == size.width,
        size.height.rounded(.towardZero) == size.height,
        pixels.x.isFinite, pixels.y.isFinite, pixels.width.isFinite, pixels.height.isFinite,
        pixels.x >= 0, pixels.y >= 0, pixels.width > 0, pixels.height > 0,
        pixels.x + pixels.width <= size.width, pixels.y + pixels.height <= size.height
      else {
        throw ProviderError.message("Pixel target bounds do not match the trusted captured image.")
      }
      var resolved = payload
      resolved.x = pixels.x / size.width
      resolved.y = pixels.y / size.height
      resolved.width = pixels.width / size.width
      resolved.height = pixels.height / size.height
      resolved.pixelBounds = nil
      return resolved
    }
    guard let id = payload.candidateID else { return payload }
    guard validID(id, frameID: frameID), candidates.count <= maximumCandidates else {
      throw ProviderError.message("Screen target refers to invalid or stale grounding evidence.")
    }
    let matches = candidates.filter { $0.id == id }
    guard matches.count == 1, let candidate = matches.first,
      validCandidate(candidate, frameID: frameID)
    else {
      throw ProviderError.message("Screen target is unknown, ambiguous, or invalid.")
    }
    switch payload.advanceOn {
    case nil, "click":
      guard candidate.enabled, candidate.source == .accessibility, candidate.actionable else {
        throw ProviderError.message(
          "Click guidance requires an enabled actionable accessibility control.")
      }
    case "manual":
      break
    default:
      throw ProviderError.message("Unsupported grounding interaction condition.")
    }
    var resolved = payload
    resolved.x = candidate.x
    resolved.y = candidate.y
    resolved.width = candidate.width
    resolved.height = candidate.height
    return resolved
  }

  private struct Context: Encodable {
    let frameID: UUID
    let coordinateSpace = "capture.normalized.topLeft"
    let candidates: [ScreenGroundingCandidate]
  }

  private static func contextEncoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return encoder
  }

  private static func boundedText(_ text: String, characters: Int, bytes: Int) -> String {
    var result = ""
    var remaining = bytes
    for character in text.prefix(characters) {
      let size = character.utf8.prefix(remaining + 1).count
      guard size <= remaining else { break }
      result.append(character)
      remaining -= size
    }
    return result
  }

  private static func candidatePrefix(_ frameID: UUID) -> String {
    "gnd:\(frameID.uuidString.lowercased()):"
  }

  private static func validID(_ id: String, frameID: UUID) -> Bool {
    guard id.utf8.prefix(101).count <= 100 else { return false }
    let prefix = candidatePrefix(frameID)
    guard id.hasPrefix(prefix) else { return false }
    let index = id.dropFirst(prefix.count)
    return !index.isEmpty && index.utf8.allSatisfy { (48...57).contains($0) }
  }

  private static func validCandidate(
    _ candidate: ScreenGroundingCandidate, frameID: UUID
  ) -> Bool {
    validID(candidate.id, frameID: frameID)
      && validNormalizedRect(
        CGRect(x: candidate.x, y: candidate.y, width: candidate.width, height: candidate.height))
  }

  private static func validRect(_ rect: CGRect) -> Bool {
    rect.origin.x.isFinite && rect.origin.y.isFinite
      && rect.size.width.isFinite && rect.size.height.isFinite
      && rect.size.width > 0 && rect.size.height > 0
      && rect.maxX.isFinite && rect.maxY.isFinite
  }

  private static func validNormalizedRect(_ rect: CGRect) -> Bool {
    validRect(rect) && rect.minX >= 0 && rect.minY >= 0 && rect.maxX <= 1 && rect.maxY <= 1
  }
}
