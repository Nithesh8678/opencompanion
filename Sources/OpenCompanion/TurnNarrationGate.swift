import Foundation

/// A turn may express the same narration as both text and target instruction.
/// Bound the remembered keys and reset when its generation ends.
struct TurnNarrationGate {
  private var keys: Set<String> = []
  private var order: [String] = []

  func allows(_ text: String) -> Bool {
    guard text.utf8.prefix(32_001).count <= 32_000 else { return false }
    let key = text.split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased()
    return !key.isEmpty && !keys.contains(key)
  }

  mutating func admit(_ text: String) -> Bool {
    guard allows(text) else { return false }
    let key = text.split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased()
    if order.count == 128 { keys.remove(order.removeFirst()) }
    order.append(key)
    keys.insert(key)
    return true
  }

  mutating func reset() {
    keys.removeAll(keepingCapacity: true)
    order.removeAll(keepingCapacity: true)
  }
}
