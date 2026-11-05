import CoreGraphics
import Foundation

/// One geometry definition for rendering and landing the assistant's pointer.
enum CursorCompanionGlyph {
  static let size = CGSize(width: 18, height: 22)
  static let tip = CGPoint(x: 16.5, y: 11)
  static let tipOffset = CGPoint(x: tip.x - size.width / 2, y: tip.y - size.height / 2)
}

/// A bounded presentation queue, independent of canonical chat history. Units
/// have increasing IDs and cumulative UTF-8 prefixes; old or rewritten content
/// cannot replace text which a different unit already owns.
struct CursorTextReveal: Sendable {
  static let maximumUnitUTF8Bytes = 32_768
  static let maximumPendingUnits = 8
  // Authored presentation parameters, not recovered reference constants.
  static let wordInterval = 0.22
  static let maximumWordGroupCharacters = 24

  private struct Group: Sendable {
    let end: Int
    let pause: Double
  }

  private enum WordKind { case ordinary, unspaced, symbol }

  private struct Unit: Sendable {
    let id: Int
    var text: String
    var characters: [Character]
    var isComplete: Bool
    var revealed = 0

    // An unfinished final cluster may still receive a combining mark, CR/LF,
    // regional indicator, or ZWJ continuation in the next cumulative update.
    var stableCount: Int { isComplete ? characters.count : max(0, characters.count - 1) }
  }

  private var units: [Unit] = []
  private var latestAcceptedID: Int?
  private var remainingDelay = 0.0
  private(set) var visibleText = ""
  private(set) var currentUnitID: Int?
  var hasPending: Bool { !units.isEmpty }
  /// A pending provisional tail needs transport, not display callbacks. Later
  /// units cannot bypass that head. Completed empty heads still require cleanup.
  var hasRevealableText: Bool {
    guard let first = units.first else { return false }
    return Self.nextGroup(in: first, after: first.revealed) != nil
      || (first.isComplete && first.characters.isEmpty)
  }
  var pendingUnitCount: Int { units.count }

  init() {}

  mutating func reset() {
    units.removeAll(keepingCapacity: true)
    latestAcceptedID = nil
    remainingDelay = 0
    visibleText = ""
    currentUnitID = nil
  }

  /// True means a new or changed prefix was accepted. False means unchanged,
  /// stale, rewritten, oversized, or full. No pending prefix is silently evicted.
  /// An accepted completed unit is immutable. IDs may restart only after reset.
  @discardableResult mutating func append(unitID: Int, text: String, isComplete: Bool) -> Bool {
    guard unitID >= 0, text.utf8.count <= Self.maximumUnitUTF8Bytes else { return false }
    if let index = units.firstIndex(where: { $0.id == unitID }) {
      let previous = units[index]
      guard !previous.isComplete,
        text.utf8.starts(with: previous.text.utf8),
        text != previous.text || isComplete
      else { return false }
      let characters = Array(text)
      guard characters.count >= previous.revealed,
        characters.prefix(previous.revealed).elementsEqual(
          previous.characters.prefix(previous.revealed))
      else { return false }
      units[index].text = text
      units[index].characters = characters
      units[index].isComplete = isComplete
    } else {
      guard units.count < Self.maximumPendingUnits,
        latestAcceptedID.map({ unitID > $0 }) ?? true
      else { return false }
      units.append(Unit(id: unitID, text: text, characters: Array(text), isComplete: isComplete))
      latestAcceptedID = unitID
    }
    return true
  }

  /// Reveal at most ONE word group per display advance, even after a long frame
  /// or large backlog. Words use a calm fixed cadence with punctuation rests;
  /// arrival rate cannot accelerate them. Reduce Motion bypasses this pacing.
  @discardableResult mutating func advance(by delta: Double, reduceMotion: Bool = false) -> Bool {
    guard delta.isFinite, delta >= 0 else { return false }
    if reduceMotion { return fastForward() }
    guard delta > 0 else { return false }
    remainingDelay = max(0, remainingDelay - delta)
    discardCompletedEmptyHeads()
    guard !units.isEmpty, remainingDelay == 0,
      let group = Self.nextGroup(in: units[0], after: units[0].revealed)
    else { return false }
    var unit = units[0]
    unit.revealed = group.end
    // Discard excess elapsed time: a stalled frame never creates a burst on the
    // next callback, nor may a new semantic unit bypass the last word's rest.
    remainingDelay = Self.wordInterval + group.pause
    let changed = present(unit)
    units[0] = unit
    if unit.isComplete && unit.revealed == unit.characters.count { units.removeFirst() }
    return changed
  }

  /// Explicit queue-pressure/Reduce Motion escape hatch. A complete head can be
  /// revealed immediately; an incomplete head exposes only complete word groups
  /// or bounded unspaced chunks, retaining its unfinished word and Unicode tail.
  @discardableResult mutating func fastForward() -> Bool {
    discardCompletedEmptyHeads()
    guard !units.isEmpty else { return false }
    var unit = units[0]
    var end = unit.revealed
    var pause = 0.0
    if unit.isComplete {
      end = unit.characters.count
    } else {
      while let group = Self.nextGroup(in: unit, after: end) {
        end = group.end
        pause = group.pause
      }
    }
    guard end > unit.revealed else { return false }
    unit.revealed = end
    remainingDelay = Self.wordInterval + pause
    let changed = present(unit)
    units[0] = unit
    if unit.isComplete { units.removeFirst() }
    return changed
  }

  /// Optional host-playback signal. It affects only its currently queued unit;
  /// a delayed speech completion cannot fast-forward a newer caption.
  @discardableResult mutating func finishSpeech(unitID: Int) -> Bool {
    guard units.first?.id == unitID else { return false }
    return fastForward()
  }

  private mutating func present(_ unit: Unit) -> Bool {
    guard unit.revealed > 0 else { return false }
    let text = String(unit.characters.prefix(unit.revealed))
    let changed = currentUnitID != unit.id || visibleText != text
    currentUnitID = unit.id
    visibleText = text
    return changed
  }

  private mutating func discardCompletedEmptyHeads() {
    while let first = units.first, first.isComplete && first.characters.isEmpty {
      units.removeFirst()
    }
  }

  /// Whitespace-delimited words retain attached punctuation. CJK runs use
  /// two-grapheme groups; long URLs/unspaced runs use at most24 graphemes. These
  /// are bounded presentation groups, not a claim of linguistic segmentation.
  private static func nextGroup(in unit: Unit, after offset: Int) -> Group? {
    let characters = unit.characters
    let stable = unit.stableCount
    guard offset < stable else { return nil }
    var index = offset
    while index < stable && characters[index].isWhitespace { index += 1 }
    if index == stable {
      return unit.isComplete ? Group(end: stable, pause: 0) : nil
    }
    var contentStart = index
    while contentStart < stable, contentStart - index < maximumWordGroupCharacters,
      isOpening(characters[contentStart])
    { contentStart += 1 }
    if contentStart - index == maximumWordGroupCharacters {
      return Group(end: contentStart, pause: 0)
    }
    guard contentStart < stable else {
      return unit.isComplete ? Group(end: stable, pause: 0) : nil
    }
    let wordKind = kind(of: characters[contentStart])
    let limit = wordKind == .unspaced ? 2 : (wordKind == .symbol ? 1 : maximumWordGroupCharacters)
    var count = 0
    while index < stable {
      let character = characters[index]
      if character.isWhitespace { return Group(end: index, pause: pause(for: character)) }
      if index > contentStart, !isPunctuation(character), kind(of: character) != wordKind {
        return Group(end: index, pause: 0)
      }
      index += 1
      if index > contentStart { count += 1 }
      if pause(for: character) > 0 && !isInternalPunctuation(at: index - 1, in: characters) {
        return finishGroup(in: unit, end: index, initialPause: pause(for: character))
      }
      if count >= limit { return finishGroup(in: unit, end: index, initialPause: 0) }
    }
    if unit.isComplete { return Group(end: index, pause: 0) }
    // The final provisional cluster may establish a boundary without itself
    // being shown. Otherwise hold the unfinished word until more text arrives.
    if index < characters.count {
      let next = characters[index]
      if next.isWhitespace { return Group(end: index, pause: pause(for: next)) }
      if !isPunctuation(next), kind(of: next) != wordKind { return Group(end: index, pause: 0) }
    }
    return nil
  }

  private static func finishGroup(in unit: Unit, end: Int, initialPause: Double) -> Group? {
    var index = end
    var rest = initialPause
    var attached = 0
    while index < unit.stableCount, attached < 8,
      pause(for: unit.characters[index]) > 0 || isClosing(unit.characters[index])
    {
      rest = max(rest, pause(for: unit.characters[index]))
      index += 1
      attached += 1
    }
    if index == unit.stableCount, !unit.isComplete, index < unit.characters.count {
      let tail = unit.characters[index]
      if pause(for: tail) > 0 || isClosing(tail) { return nil }
    }
    if index < unit.characters.count, unit.characters[index].isWhitespace {
      rest = max(rest, pause(for: unit.characters[index]))
    }
    return Group(end: index, pause: rest)
  }

  private static func kind(of character: Character) -> WordKind {
    for scalar in character.unicodeScalars {
      switch scalar.value {
      case 0x3040...0x30FF, 0x31F0...0x31FF, 0x3400...0x9FFF, 0x20000...0x323AF:
        return .unspaced
      default: break
      }
    }
    return character.unicodeScalars.contains { $0.properties.generalCategory == .otherSymbol }
      ? .symbol : .ordinary
  }

  private static func isPunctuation(_ character: Character) -> Bool {
    character.unicodeScalars.allSatisfy {
      switch $0.properties.generalCategory {
      case .connectorPunctuation, .dashPunctuation, .openPunctuation, .closePunctuation,
        .initialPunctuation, .finalPunctuation, .otherPunctuation:
        true
      default: false
      }
    }
  }

  private static func isOpening(_ character: Character) -> Bool {
    character == "\"" || character == "'"
      || character.unicodeScalars.allSatisfy {
        $0.properties.generalCategory == .openPunctuation
          || $0.properties.generalCategory == .initialPunctuation
      }
  }

  private static func isClosing(_ character: Character) -> Bool {
    character == "\"" || character == "'"
      || character.unicodeScalars.allSatisfy {
        $0.properties.generalCategory == .closePunctuation
          || $0.properties.generalCategory == .finalPunctuation
      }
  }

  private static func isInternalPunctuation(at index: Int, in characters: [Character]) -> Bool {
    guard index > 0, index + 1 < characters.count else { return false }
    let before = characters[index - 1]
    let after = characters[index + 1]
    switch characters[index] {
    case ".", "．": return (before.isLetter || before.isNumber) && (after.isLetter || after.isNumber)
    case ",", "，": return before.isNumber && after.isNumber
    case ":": return after == "/"
    default: return false
    }
  }

  private static func pause(for character: Character) -> Double {
    switch character {
    case ".", "!", "?", "。", "！", "？", "؟", "।", "॥": 0.15
    case ",", ";", ":", "，", "、", "；", "：", "،", "؛": 0.10
    case "\n", "\r", "\r\n", "\u{2028}", "\u{2029}": 0.16
    default: 0
    }
  }
}

struct CursorCompanionPlacement: Sendable, Equatable {
  /// Global AppKit logical points (unflipped).
  let frame: CGRect
  /// Triangle center and bubble rect in the panel's local flipped coordinates.
  let bodyPoint: CGPoint
  let bubbleFrame: CGRect
}

struct CursorCompanionLayout: Sendable {
  static let maximumCaptionWidth: CGFloat = 320
  static let bodySize = CursorCompanionGlyph.size

  /// `anchor` is the global center of the cursor body. It stays exact when the
  /// body/glow fits; near unsafe display edges it is clamped into the safe area.
  /// The returned panel encloses only the painted body/glow and optional bubble.
  static func placement(
    anchor: CGPoint, bubbleSize: CGSize, display: CGRect, visible: CGRect,
    previous: CursorCompanionPlacement? = nil
  ) -> CursorCompanionPlacement {
    let display = usable(display) ?? CGRect(x: 0, y: 0, width: 1024, height: 768)
    let intersection = usable(visible).map { display.intersection($0) }
    let region = intersection.flatMap(usable) ?? display
    let safe = region.insetBy(dx: min(6, region.width / 4), dy: min(6, region.height / 4))
    let width = min(bodySize.width, safe.width)
    let height = min(bodySize.height, safe.height)
    // Enclose the rotated triangle's diagonal and its soft halo, not just
    // the axis-aligned path. The panel stays small and never clips the flight.
    let glowX = min(18, max(0, (safe.width - width) / 2))
    let glowY = min(18, max(0, (safe.height - height) / 2))
    let center = CGPoint(
      x: clamped(
        anchor.x, fallback: safe.midX, low: safe.minX + width / 2 + glowX,
        high: safe.maxX - width / 2 - glowX),
      y: clamped(
        anchor.y, fallback: safe.midY, low: safe.minY + height / 2 + glowY,
        high: safe.maxY - height / 2 - glowY))
    let body = CGRect(
      x: center.x - width / 2, y: center.y - height / 2,
      width: width, height: height)
    var frame = body.insetBy(dx: -glowX, dy: -glowY)
    var bubble = CGRect.zero
    if bubbleSize.width.isFinite && bubbleSize.height.isFinite,
      bubbleSize.width > 0 && bubbleSize.height > 0
    {
      let bubbleWidth = min(maximumCaptionWidth, bubbleSize.width, safe.width)
      let gap: CGFloat = 6
      let below = max(0, body.minY - gap - safe.minY)
      let above = max(0, safe.maxY - body.maxY - gap)
      let desiredHeight = min(bubbleSize.height, 240)
      var placeAbove = below < desiredHeight && above > below
      if let previous, previous.bubbleFrame.height > 0 {
        let wasAbove = previous.bubbleFrame.midY < previous.bodyPoint.y
        let oldRoom = wasAbove ? above : below
        if oldRoom >= desiredHeight || abs(above - below) < 12 { placeAbove = wasAbove }
      }
      let bubbleHeight = min(desiredHeight, placeAbove ? above : below)
      if bubbleHeight > 0 {
        let right = max(0, safe.maxX - body.maxX - gap)
        let left = max(0, body.minX - gap - safe.minX)
        var placeLeft = right < bubbleWidth && left > right
        if let previous, previous.bubbleFrame.width > 0 {
          let wasLeft = previous.bubbleFrame.midX < previous.bodyPoint.x
          let oldRoom = wasLeft ? left : right
          if oldRoom >= bubbleWidth || abs(left - right) < 12 { placeLeft = wasLeft }
        }
        let x = placeLeft ? body.minX - gap - bubbleWidth : body.maxX + gap
        let y = placeAbove ? body.maxY + gap : body.minY - gap - bubbleHeight
        bubble = CGRect(
          x: min(max(safe.minX, x), safe.maxX - bubbleWidth), y: y,
          width: bubbleWidth, height: bubbleHeight)
        // Include the caption's soft halo in the tight native window. The
        // logical bubble remains inside the visible region at display edges.
        frame = frame.union(bubble.insetBy(dx: -12, dy: -12).intersection(safe))
      }
    }
    return CursorCompanionPlacement(
      frame: frame,
      bodyPoint: CGPoint(x: center.x - frame.minX, y: frame.maxY - center.y),
      bubbleFrame: bubble.isEmpty
        ? .zero
        : CGRect(
          x: bubble.minX - frame.minX, y: frame.maxY - bubble.maxY,
          width: bubble.width, height: bubble.height))
  }

  private static func usable(_ rect: CGRect) -> CGRect? {
    guard rect.origin.x.isFinite, rect.origin.y.isFinite,
      rect.width.isFinite, rect.height.isFinite
    else { return nil }
    let value = rect.standardized
    guard value.width > 0, value.height > 0,
      value.width <= 100_000, value.height <= 100_000,
      abs(value.minX) <= 10_000_000, abs(value.minY) <= 10_000_000,
      value.maxX.isFinite, value.maxY.isFinite
    else { return nil }
    return value
  }

  private static func clamped(
    _ value: CGFloat, fallback: CGFloat, low: CGFloat, high: CGFloat
  ) -> CGFloat {
    min(max(value.isFinite ? value : fallback, low), high)
  }
}

/// Original local guidance motion, not recovered reference animation constants.
/// Progress is elapsed/duration; the curve's projection along start→end is
/// monotonic, with a quiet perpendicular bow and zero endpoint speed.
struct CursorFlight: Sendable {
  let start: CGPoint
  let end: CGPoint
  let duration: Double
  private let control: CGPoint

  init(start: CGPoint, end: CGPoint) {
    let start = Self.safe(start, fallback: .zero)
    let end = Self.safe(end, fallback: start)
    self.start = start
    self.end = end
    let dx = end.x - start.x
    let dy = end.y - start.y
    let distance = hypot(dx, dy)
    duration = min(0.65, max(0.18, Double(distance) / 1400))
    var normal = distance > 0 ? CGPoint(x: -dy / distance, y: dx / distance) : .zero
    if normal.y < 0 { normal = CGPoint(x: -normal.x, y: -normal.y) }
    let bow = min(60, distance * 0.12)
    control = CGPoint(
      x: (start.x + end.x) / 2 + normal.x * bow,
      y: (start.y + end.y) / 2 + normal.y * bow)
  }

  func point(at progress: Double) -> CGPoint {
    let t = eased(progress)
    let inverse = 1 - t
    return CGPoint(
      x: inverse * inverse * start.x + 2 * inverse * t * control.x + t * t * end.x,
      y: inverse * inverse * start.y + 2 * inverse * t * control.y + t * t * end.y)
  }

  /// Unit direction in the same global coordinate space as the input points.
  /// A flipped native view converts the Y component before atan2 if needed.
  func tangent(at progress: Double) -> CGPoint {
    let t = eased(progress)
    let dx = 2 * (1 - t) * (control.x - start.x) + 2 * t * (end.x - control.x)
    let dy = 2 * (1 - t) * (control.y - start.y) + 2 * t * (end.y - control.y)
    let length = hypot(dx, dy)
    return length > 0 ? CGPoint(x: dx / length, y: dy / length) : CGPoint(x: 1, y: 0)
  }

  private func eased(_ progress: Double) -> CGFloat {
    let t = progress.isFinite ? min(1, max(0, progress)) : 0
    return CGFloat(t * t * (3 - 2 * t))
  }

  private static func safe(_ point: CGPoint, fallback: CGPoint) -> CGPoint {
    guard point.x.isFinite, point.y.isFinite,
      abs(point.x) <= 10_000_000, abs(point.y) <= 10_000_000
    else { return fallback }
    return point
  }
}
