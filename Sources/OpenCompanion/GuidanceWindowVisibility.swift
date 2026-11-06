import AppKit
import CoreGraphics
import Foundation

/// Ephemeral window metadata only; no image or screen-evidence authority.
struct GuidanceWindowSource: Sendable, Equatable {
  let id: CGWindowID
  let ownerPID: pid_t
  let capturedBounds: CGRect
  let sourceRect: CGRect
}

struct GuidanceWindowRecord: Sendable, Equatable {
  let id: CGWindowID
  let ownerPID: pid_t
  let bounds: CGRect
  let alpha: Double
  let isOnScreen: Bool
}

/// Conservative metadata admission, not proof of per-pixel visibility or a
/// successful click. The host separately owns the selection/frame/generation.
enum GuidanceWindowVisibility {
  static let maximumRecords = 4_096

  static func permits(
    source: GuidanceWindowSource, targetRect: CGRect,
    frontToBack: [GuidanceWindowRecord], hitWindowID: CGWindowID?, ownPID: pid_t,
    passiveWindowIDs: Set<CGWindowID>
  ) -> Bool {
    guard valid(source: source, targetRect: targetRect), ownPID > 0,
      hitWindowID == source.id,
      !frontToBack.isEmpty, frontToBack.count <= maximumRecords,
      passiveWindowIDs.count <= maximumRecords
    else { return false }

    var ids = Set<CGWindowID>()
    var selectedIndex: Int?
    for (index, record) in frontToBack.enumerated() {
      guard record.id > 0, record.ownerPID > 0, valid(record.bounds),
        record.alpha.isFinite, (0...1).contains(record.alpha),
        ids.insert(record.id).inserted
      else { return false }
      if record.id == source.id { selectedIndex = index }
    }
    guard let selectedIndex else { return false }
    let selected = frontToBack[selectedIndex]
    guard selected.ownerPID == source.ownerPID,
      selected.bounds.origin == source.capturedBounds.origin,
      selected.bounds.size == source.capturedBounds.size,
      selected.isOnScreen, selected.alpha > 0
    else { return false }

    for higher in frontToBack[..<selectedIndex] {
      guard higher.isOnScreen, higher.alpha > 0 else { continue }
      if higher.ownerPID == ownPID, passiveWindowIDs.contains(higher.id) { continue }
      let overlap = higher.bounds.intersection(targetRect)
      if overlap.size.width > 0, overlap.size.height > 0 { return false }
    }
    return true
  }

  /// Reads IDs, owners, bounds and visibility only. The public AppKit point
  /// query asks which window would receive a mouse-down at the target center;
  /// it does not activate, capture, or send an event to that window.
  @MainActor static func nativePermits(
    source: GuidanceWindowSource, targetRect: CGRect,
    passiveWindowIDs: Set<CGWindowID>
  ) -> Bool {
    guard valid(source: source, targetRect: targetRect),
      passiveWindowIDs.count <= maximumRecords,
      let primaryTop = NSScreen.screens.first?.frame.maxY, primaryTop.isFinite,
      let raw = CGWindowListCopyWindowInfo(
        [.optionOnScreenAboveWindow, .optionIncludingWindow], source.id),
      CFArrayGetCount(raw) > 0, CFArrayGetCount(raw) <= maximumRecords,
      let windows = raw as? [[String: Any]]
    else { return false }

    var records: [GuidanceWindowRecord] = []
    records.reserveCapacity(windows.count)
    for window in windows {
      guard let id = unsignedID(window[kCGWindowNumber as String]),
        let owner = positiveInteger(window[kCGWindowOwnerPID as String], maximum: Int32.max),
        let alpha = number(window[kCGWindowAlpha as String]),
        let onScreen = number(window[kCGWindowIsOnscreen as String], allowBoolean: true),
        onScreen == 0 || onScreen == 1,
        let dictionary = window[kCGWindowBounds as String] as? [String: Any],
        let quartz = CGRect(dictionaryRepresentation: dictionary as CFDictionary), valid(quartz)
      else { return false }
      let appKit = CGRect(
        x: quartz.origin.x, y: primaryTop - quartz.maxY,
        width: quartz.size.width, height: quartz.size.height)
      guard valid(appKit) else { return false }
      records.append(
        .init(
          id: id, ownerPID: pid_t(owner), bounds: appKit, alpha: alpha,
          isOnScreen: onScreen == 1))
    }

    let hit = NSWindow.windowNumber(
      at: CGPoint(x: targetRect.midX, y: targetRect.midY), belowWindowWithWindowNumber: 0)
    guard hit > 0, UInt64(hit) <= UInt64(UInt32.max) else { return false }
    return permits(
      source: source, targetRect: targetRect, frontToBack: records,
      hitWindowID: CGWindowID(hit), ownPID: ProcessInfo.processInfo.processIdentifier,
      passiveWindowIDs: passiveWindowIDs)
  }

  private static func valid(source: GuidanceWindowSource, targetRect: CGRect) -> Bool {
    source.id > 0 && source.ownerPID > 0 && valid(source.capturedBounds)
      && valid(source.sourceRect) && valid(targetRect)
      && source.capturedBounds.contains(source.sourceRect)
      && source.sourceRect.contains(targetRect)
  }

  private static func valid(_ rect: CGRect) -> Bool {
    rect.origin.x.isFinite && rect.origin.y.isFinite
      && abs(rect.origin.x) <= 10_000_000 && abs(rect.origin.y) <= 10_000_000
      && rect.size.width.isFinite && rect.size.height.isFinite
      && rect.size.width > 0 && rect.size.height > 0
      && rect.size.width <= 100_000 && rect.size.height <= 100_000
      && rect.maxX.isFinite && rect.maxY.isFinite
  }

  private static func number(_ value: Any?, allowBoolean: Bool = false) -> Double? {
    guard let value = value as? NSNumber,
      allowBoolean || CFGetTypeID(value) != CFBooleanGetTypeID(), value.doubleValue.isFinite
    else { return nil }
    return value.doubleValue
  }

  private static func positiveInteger<T: BinaryInteger>(_ value: Any?, maximum: T) -> UInt64? {
    guard let value = number(value), value > 0, value <= Double(maximum),
      value.rounded(.towardZero) == value
    else { return nil }
    return UInt64(value)
  }

  private static func unsignedID(_ value: Any?) -> CGWindowID? {
    positiveInteger(value, maximum: UInt32.max).map(CGWindowID.init)
  }
}
