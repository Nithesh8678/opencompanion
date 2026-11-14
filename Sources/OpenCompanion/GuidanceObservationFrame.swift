import CoreGraphics
import Foundation

/// A deliberately armed local observation extent. It is never durable workflow
/// progress, a screenshot identity, or authority to broaden a selected source.
struct GuidanceObservationScope: Equatable, Sendable {
  let leaseID: UUID
  let generation: UInt64
  let foregroundPID: pid_t
  let displayID: CGDirectDisplayID
  let sourceRect: CGRect
  let windowID: CGWindowID?

  init(
    leaseID: UUID = UUID(), generation: UInt64, foregroundPID: pid_t,
    displayID: CGDirectDisplayID, sourceRect: CGRect, windowID: CGWindowID? = nil
  ) throws {
    guard foregroundPID > 0, displayID > 0, windowID.map({ $0 > 0 }) ?? true,
      Self.valid(sourceRect)
    else { throw GuidanceObservationFailure.invalidScope }
    self.leaseID = leaseID
    self.generation = generation
    self.foregroundPID = foregroundPID
    self.displayID = displayID
    self.sourceRect = sourceRect
    self.windowID = windowID
  }

  static func valid(_ rect: CGRect) -> Bool {
    rect.origin.x.isFinite && rect.origin.y.isFinite
      && abs(rect.origin.x) <= 10_000_000 && abs(rect.origin.y) <= 10_000_000
      && rect.size.width.isFinite && rect.size.height.isFinite
      && rect.size.width > 0 && rect.size.height > 0
      && rect.size.width <= 100_000 && rect.size.height <= 100_000
      && rect.maxX.isFinite && rect.maxY.isFinite
  }
}

enum GuidanceObservationFailure: Error, Equatable, LocalizedError {
  case invalidScope, permissionUnavailable, sourceUnavailable, streamUnavailable

  var errorDescription: String? {
    switch self {
    case .invalidScope: "The active screen observation scope is invalid. Choose the screen again."
    case .permissionUnavailable:
      "Screen Recording is unavailable. Enable the installed OpenCompanion app before starting guidance."
    case .sourceUnavailable:
      "The selected screen or window changed. Choose its current scope before resuming guidance."
    case .streamUnavailable:
      "Live screen observation could not start. Recheck the selected screen and Screen Recording permission."
    }
  }
}

struct GuidanceObservationEvent: Equatable, Sendable {
  enum Reason: String, Codable, Sendable {
    case foregroundChanged, windowChanged, focusChanged, geometryChanged, menuChanged
    case layoutChanged, scroll, typing, visualChange, suspended, unavailable
  }
  let reason: Reason
  let timestamp: TimeInterval
  let sequence: UInt64
}

struct GuidanceObservationSamplingPlan: Equatable, Sendable {
  let sourceRect: CGRect
  let width: Int
  let height: Int

  init?(source: CGRect, containing base: CGRect) {
    guard GuidanceObservationScope.valid(source), GuidanceObservationScope.valid(base),
      base.contains(source), source.size.width >= 1, source.size.height >= 1
    else { return nil }
    let ratio = min(256 / source.size.width, 160 / source.size.height)
    width = max(1, Int((source.size.width * ratio).rounded(.down)))
    height = max(1, Int((source.size.height * ratio).rounded(.down)))
    sourceRect = CGRect(
      x: source.minX - base.minX, y: base.maxY - source.maxY,
      width: source.size.width, height: source.size.height)
  }
}

/// Immutable copied local detector pixels, deliberately not Codable. They are
/// not model evidence and must not acquire a capture/frame ID or be persisted.
struct GuidanceObservationFrame: Equatable, Sendable {
  static let maximumWidth = 256
  static let maximumHeight = 160
  static let maximumBytes = maximumWidth * maximumHeight * 4

  let width: Int
  let height: Int
  let contentTime: TimeInterval
  let receivedAt: TimeInterval
  let pixels: Data

  init?(
    width: Int, height: Int, contentTime: TimeInterval, receivedAt: TimeInterval, pixels: Data
  ) {
    guard (1...Self.maximumWidth).contains(width), (1...Self.maximumHeight).contains(height),
      pixels.count == width * height * 4,
      contentTime.isFinite, contentTime >= 0, receivedAt.isFinite, receivedAt >= contentTime
    else { return nil }
    self.width = width
    self.height = height
    self.contentTime = contentTime
    self.receivedAt = receivedAt
    // Freeze even a Data value backed by a caller-owned mutable allocation.
    self.pixels = pixels.withUnsafeBytes { Data(bytes: $0.baseAddress!, count: $0.count) }
  }
}

/// Latest-only local comparison. An idle callback never calls accept, and a
/// repeated/out-of-order content timestamp cannot make stale pixels young.
struct GuidanceLatestFrameState: Sendable {
  enum Update: Equatable { case rejected, initial, unchanged, changed }
  private(set) var latestFrame: GuidanceObservationFrame?
  // One immutable analytical baseline, not a history/queue of video frames.
  // Keep it until reporting a change so gradual subthreshold changes accumulate.
  private var comparisonBaseline: GuidanceObservationFrame?

  mutating func reset() {
    latestFrame = nil
    comparisonBaseline = nil
  }

  mutating func accept(_ frame: GuidanceObservationFrame) -> Update {
    guard let previous = latestFrame else {
      latestFrame = frame
      comparisonBaseline = frame
      return .initial
    }
    guard frame.contentTime > previous.contentTime, frame.receivedAt >= previous.receivedAt else {
      return .rejected
    }
    latestFrame = frame
    guard let baseline = comparisonBaseline,
      frame.width == baseline.width, frame.height == baseline.height
    else {
      comparisonBaseline = frame
      return .changed
    }
    let changed = baseline.pixels.withUnsafeBytes { old in
      frame.pixels.withUnsafeBytes { new in
        let a = old.bindMemory(to: UInt8.self)
        let b = new.bindMemory(to: UInt8.self)
        var total = 0
        var substantial = 0
        let count = frame.width * frame.height
        for pixel in 0..<count {
          let index = pixel * 4
          let difference = max(
            abs(Int(a[index]) - Int(b[index])),
            max(
              abs(Int(a[index + 1]) - Int(b[index + 1])),
              abs(Int(a[index + 2]) - Int(b[index + 2]))))
          total += difference
          if difference > 16 { substantial += 1 }
        }
        // Authored noise thresholds, not a proof that all controls stayed
        // unchanged. AX/input metadata covers smaller semantic changes.
        return Double(total) / Double(count) >= 1
          || Double(substantial) / Double(count) >= 0.001
      }
    }
    if changed { comparisonBaseline = frame }
    return changed ? .changed : .unchanged
  }
}

/// Raw SCK on-screen placement metadata only. Comparing it to its own prior
/// value avoids assuming an undocumented Retina/origin transform. This does
/// not authorize pixels or retarget a moved selected window.
struct GuidanceObservationWindowState: Sendable {
  private(set) var latestBounds: CGRect?

  mutating func accept(_ bounds: CGRect) -> Bool {
    guard GuidanceObservationScope.valid(bounds) else { return false }
    let changed = latestBounds.map { $0 != bounds } ?? false
    latestBounds = bounds
    return changed
  }
}

/// One pending copied frame across the sample queue/MainActor boundary. Pushes
/// replace the slot; at most one drain task is scheduled, never one per frame.
final class GuidanceLatestFrameMailbox: @unchecked Sendable {
  private let lock = NSLock()
  private var active = true
  private var scheduled = false
  private var pending: GuidanceObservationFrame?

  func offer(_ frame: GuidanceObservationFrame) -> Bool {
    lock.withLock {
      guard active else { return false }
      pending = frame
      guard !scheduled else { return false }
      scheduled = true
      return true
    }
  }

  func take() -> GuidanceObservationFrame? {
    lock.withLock {
      guard active else { return nil }
      let frame = pending
      pending = nil
      return frame
    }
  }

  /// Clear scheduling only after draining. A concurrent offer either occupies
  /// this drain or owns the next scheduling edge; no newest frame is lost.
  func finishDrain() -> Bool {
    lock.withLock {
      guard active, pending != nil else {
        scheduled = false
        return false
      }
      return true
    }
  }

  func invalidate() {
    lock.withLock {
      active = false
      scheduled = false
      pending = nil
    }
  }
}
