import CoreGraphics
import Foundation

/// A bounded presentation queue, independent of canonical chat history. Units
/// have increasing IDs and cumulative UTF-8 prefixes; old or rewritten content
/// cannot replace text which a different unit already owns.
struct CursorTextReveal: Sendable {
  static let maximumUnitUTF8Bytes = 32_768
  static let maximumPendingUnits = 8

  private struct Unit: Sendable {
    let id: Int
    var text: String
    var characters: [Character]
    var isComplete: Bool
    var revealed = 0
    var started = false
    var credit = 0.0
    var delay = 0.0
    var rate = 32.0

    // An unfinished final cluster may still receive a combining mark, CR/LF,
    // regional indicator, or ZWJ continuation in the next cumulative update.
    var stableCount: Int { isComplete ? characters.count : max(0, characters.count - 1) }
  }

  private var units: [Unit] = []
  private var latestAcceptedID: Int?
  private(set) var visibleText = ""
  private(set) var currentUnitID: Int?
  var hasPending: Bool { !units.isEmpty }
  var pendingUnitCount: Int { units.count }

  init() {}

  mutating func reset() {
    units.removeAll(keepingCapacity: true)
    latestAcceptedID = nil
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
    accelerateForBacklog()
    return true
  }

  /// Advance one visible unit per call, using elapsed time rather than frame
  /// counts. Invalid time is ignored. Reduce Motion reveals one safe prefix
  /// immediately, including when delta is zero; it never skips the whole queue.
  @discardableResult mutating func advance(by delta: Double, reduceMotion: Bool = false) -> Bool {
    guard delta.isFinite, delta >= 0 else { return false }
    if reduceMotion { return fastForward() }
    guard delta > 0 else { return false }
    discardCompletedEmptyHeads()
    guard !units.isEmpty else { return false }
    var unit = units[0]
    let available = unit.stableCount
    guard unit.revealed < available else {
      // Waiting for transport is not animation time to spend on future text.
      units[0].credit = 0
      return false
    }
    unit.credit += min(delta, 60)
    if !unit.started {
      unit.started = true
      unit.revealed = 1
      unit.delay = delay(after: unit.characters[0], rate: unit.rate)
    }
    // At most32,768 graphemes can be traversed, even after a suspended clock.
    while unit.revealed < available && unit.credit >= unit.delay {
      unit.credit -= unit.delay
      unit.revealed += 1
      unit.delay = delay(after: unit.characters[unit.revealed - 1], rate: unit.rate)
    }
    if unit.revealed == available { unit.credit = 0 }
    let changed = present(unit)
    units[0] = unit
    if unit.isComplete && unit.revealed == unit.characters.count { units.removeFirst() }
    return changed
  }

  /// Queue-pressure escape hatch: reveal only the head's safe prefix. A fully
  /// completed head is retired so append can be retried once. An incomplete head
  /// stays owned and cannot be discarded to make room for an unrelated caption.
  @discardableResult mutating func fastForward() -> Bool {
    discardCompletedEmptyHeads()
    guard !units.isEmpty else { return false }
    var unit = units[0]
    guard unit.stableCount > 0 else { return false }
    unit.revealed = unit.stableCount
    unit.started = true
    unit.credit = 0
    unit.delay = 0
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

  private mutating func accelerateForBacklog() {
    let backlog = units.reduce(0) { $0 + max(0, $1.stableCount - $1.revealed) }
    for index in units.indices {
      let desired = max(32, Double(units[index].characters.count) / 1.6, Double(backlog) / 2.4)
      units[index].rate = max(units[index].rate, min(150_000, desired))
    }
  }

  private func delay(after character: Character, rate: Double) -> Double {
    let pause: Double
    switch character {
    case ".", "!", "?", "。", "！", "？": pause = 0.08
    case ",", ";", ":", "，", "、", "；", "：": pause = 0.045
    case "\n", "\r\n": pause = 0.09
    default: pause = 0
    }
    return 1 / rate + pause * min(1, 32 / rate)
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
  static let bodySize = CGSize(width: 18, height: 22)

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
    let glowX = min(8, max(0, (safe.width - width) / 2))
    let glowY = min(8, max(0, (safe.height - height) / 2))
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
        frame = frame.union(bubble)
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
