import CoreGraphics
import Foundation

/// Bounded host-owned callout placement. Model offsets remain preferences;
/// geometry anchors and canonical measured sizes are never rewritten.
enum SpatialLabelLayout {
  struct Item: Sendable, Equatable {
    let id: String
    let anchor: CGPoint
    let preferredOrigin: CGPoint
    let size: CGSize
  }

  struct Result: Sendable {
    let frames: [String: CGRect]
    /// Physical space can be insufficient for a schema's maximum128 labels.
    /// Keep that failure observable rather than claiming an overlap-free view.
    let overlappingPairs: Int
  }

  private struct Segment {
    let start: CGPoint
    let end: CGPoint
  }

  private struct Score {
    let overlap: CGFloat
    let objectOverlap: CGFloat
    let crossings: Int
    let distance: CGFloat
    func precedes(_ other: Self) -> Bool {
      if overlap != other.overlap { return overlap < other.overlap }
      if objectOverlap != other.objectOverlap { return objectOverlap < other.objectOverlap }
      if crossings != other.crossings { return crossings < other.crossings }
      return distance < other.distance
    }
  }

  static func place(
    _ input: [Item], in bounds: CGRect, objectBounds: CGRect? = nil,
    gap: CGFloat = 6, previous: [String: CGRect] = [:]
  ) -> Result {
    guard valid(bounds), gap.isFinite, gap >= 0, gap <= 1_000_000 else {
      return Result(frames: [:], overlappingPairs: 0)
    }
    var frames: [String: CGRect] = [:]
    var placed: [CGRect] = []
    var leaders: [Segment] = []
    let obstacle = objectBounds.flatMap { valid($0) ? $0.intersection(bounds) : nil }
    for item in input.prefix(128).sorted(by: { $0.id < $1.id }) {
      guard frames[item.id] == nil, item.anchor.x.isFinite, item.anchor.y.isFinite,
        item.preferredOrigin.x.isFinite, item.preferredOrigin.y.isFinite,
        item.size.width.isFinite, item.size.height.isFinite,
        item.size.width > 0, item.size.height > 0,
        item.size.width <= bounds.width, item.size.height <= bounds.height
      else { continue }
      var candidates: [CGRect] = []
      let previousFrame = previous[item.id].flatMap { valid($0) ? $0 : nil }
      func candidate(_ origin: CGPoint) {
        guard candidates.count < 256 else { return }
        candidates.append(
          CGRect(
            x: min(max(origin.x, bounds.minX), bounds.maxX - item.size.width),
            y: min(max(origin.y, bounds.minY), bounds.maxY - item.size.height),
            width: item.size.width, height: item.size.height))
      }
      candidate(item.preferredOrigin)
      if let old = previousFrame, old.size == item.size { candidate(old.origin) }
      for x in [item.anchor.x + gap, item.anchor.x - item.size.width - gap] {
        for y in [item.anchor.y - item.size.height - gap, item.anchor.y, item.anchor.y + gap] {
          candidate(CGPoint(x: x, y: y))
        }
      }
      candidate(CGPoint(x: item.anchor.x - item.size.width / 2, y: bounds.minY))
      candidate(CGPoint(x: item.anchor.x - item.size.width / 2, y: bounds.maxY - item.size.height))
      // Adjacent slots fill holes left by labels of differing measured widths.
      for rect in placed {
        candidate(CGPoint(x: rect.minX, y: rect.maxY + gap))
        candidate(CGPoint(x: rect.minX, y: rect.minY - item.size.height - gap))
        candidate(CGPoint(x: rect.maxX + gap, y: rect.minY))
        candidate(CGPoint(x: rect.minX - item.size.width - gap, y: rect.minY))
      }
      let rows = Int(max(1, min(16, bounds.height / (item.size.height + gap))))
      let columns = Int(max(1, min(12, bounds.width / (item.size.width + gap))))
      for row in 0..<rows {
        for column in 0..<columns {
          let x =
            bounds.minX + (bounds.width - item.size.width) * CGFloat(column)
            / CGFloat(max(1, columns - 1))
          let y =
            bounds.minY + (bounds.height - item.size.height) * CGFloat(row)
            / CGFloat(max(1, rows - 1))
          candidate(CGPoint(x: x, y: y))
        }
      }
      var best = candidates[0]
      var bestScore: Score?
      for frame in candidates {
        let leader = Segment(start: item.anchor, end: closestPoint(item.anchor, on: frame))
        var overlap = CGFloat.zero
        var crossings = 0
        for rect in placed {
          overlap += area(
            frame.insetBy(dx: -gap / 2, dy: -gap / 2).intersection(
              rect.insetBy(dx: -gap / 2, dy: -gap / 2)))
          if intersects(leader, rect) { crossings += 1 }
        }
        for existing in leaders {
          if crosses(leader, existing) || intersects(existing, frame) { crossings += 1 }
        }
        let oldDistance = previousFrame.map { squaredDistance(frame.origin, $0.origin) } ?? 0
        let score = Score(
          overlap: overlap, objectOverlap: obstacle.map { area(frame.intersection($0)) } ?? 0,
          crossings: crossings,
          distance: squaredDistance(frame.origin, item.preferredOrigin) + oldDistance * 0.25)
        if bestScore.map({ score.precedes($0) }) ?? true {
          best = frame
          bestScore = score
        }
      }
      frames[item.id] = best
      placed.append(best)
      leaders.append(Segment(start: item.anchor, end: closestPoint(item.anchor, on: best)))
    }
    var overlaps = 0
    for index in placed.indices {
      for other in placed.indices where other > index && placed[index].intersects(placed[other]) {
        overlaps += 1
      }
    }
    return Result(frames: frames, overlappingPairs: overlaps)
  }

  static func closestPoint(_ point: CGPoint, on rect: CGRect) -> CGPoint {
    CGPoint(x: min(max(point.x, rect.minX), rect.maxX), y: min(max(point.y, rect.minY), rect.maxY))
  }

  private static func valid(_ rect: CGRect) -> Bool {
    rect.origin.x.isFinite && rect.origin.y.isFinite && rect.width.isFinite && rect.height.isFinite
      && rect.width > 0 && rect.height > 0 && rect.maxX.isFinite && rect.maxY.isFinite
  }
  private static func area(_ rect: CGRect) -> CGFloat {
    rect.isNull ? 0 : max(0, rect.width) * max(0, rect.height)
  }
  private static func squaredDistance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
    let x = a.x - b.x
    let y = a.y - b.y
    return x * x + y * y
  }
  private static func crosses(_ a: Segment, _ b: Segment) -> Bool {
    func side(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint) -> CGFloat {
      (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)
    }
    return side(a.start, a.end, b.start) * side(a.start, a.end, b.end) < 0
      && side(b.start, b.end, a.start) * side(b.start, b.end, a.end) < 0
  }
  private static func intersects(_ line: Segment, _ rect: CGRect) -> Bool {
    var low = CGFloat.zero
    var high = CGFloat(1)
    func clip(_ direction: CGFloat, _ distance: CGFloat) -> Bool {
      if direction == 0 { return distance >= 0 }
      let ratio = distance / direction
      if direction < 0 { low = max(low, ratio) } else { high = min(high, ratio) }
      return low <= high
    }
    let dx = line.end.x - line.start.x
    let dy = line.end.y - line.start.y
    return clip(-dx, line.start.x - rect.minX) && clip(dx, rect.maxX - line.start.x)
      && clip(-dy, line.start.y - rect.minY) && clip(dy, rect.maxY - line.start.y)
  }
}
