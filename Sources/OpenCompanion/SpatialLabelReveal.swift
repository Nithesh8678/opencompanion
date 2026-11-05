import CompanionCore

/// Presentation state for the bounded set of anchored labels. Canonical scene
/// text remains separate, so partial words never change layout or document data.
struct SpatialLabelReveal: Sendable {
  struct Label: Sendable, Equatable {
    let id: String
    let text: String
    let anchor: LabelAnchor3D
  }

  private struct Entry: Sendable {
    let label: Label
    var reveal: CursorTextReveal
    let immediateText: String?
    var visibleText: String { immediateText ?? reveal.visibleText }
  }

  private var documentID: String?
  private var generation: UInt64?
  private var entries: [String: Entry] = [:]
  var hasRevealableText: Bool { entries.values.contains { $0.reveal.hasRevealableText } }

  mutating func reset() {
    documentID = nil
    generation = nil
    entries.removeAll(keepingCapacity: true)
  }

  /// A newer turn settles its old labels instead of replaying them. A new
  /// document or changed label/anchor owns a fresh reveal; stale turns cannot
  /// rewrite presentation state for the current document.
  mutating func reconcile(
    documentID: String, generation: UInt64, labels: [Label], reduceMotion: Bool
  ) {
    if self.documentID != documentID {
      reset()
      self.documentID = documentID
    } else if let current = self.generation, generation < current {
      return
    }
    if let current = self.generation, current != generation { settle() }
    self.generation = generation
    let labels = labels.prefix(128)  // Same bound as validated typed scene nodes.
    let ids = Set(labels.map(\.id))
    for id in Array(entries.keys) where !ids.contains(id) { entries.removeValue(forKey: id) }
    for label in labels where entries[label.id]?.label != label {
      var reveal = CursorTextReveal()
      let accepted = reveal.append(unitID: 0, text: label.text, isComplete: true)
      entries[label.id] = Entry(
        label: label, reveal: reveal, immediateText: accepted ? nil : label.text)
    }
    if reduceMotion { settle() }
  }

  func visibleText(id: String) -> String? { entries[id]?.visibleText }

  @discardableResult mutating func advance(by delta: Double, reduceMotion: Bool = false) -> Bool {
    var changed = false
    for id in Array(entries.keys) {
      if entries[id]?.reveal.advance(by: delta, reduceMotion: reduceMotion) == true {
        changed = true
      }
    }
    return changed
  }

  private mutating func settle() {
    for id in Array(entries.keys) { entries[id]?.reveal.fastForward() }
  }
}
