import AppKit
import CoreGraphics

/// A native metadata check for a selected window. Display/region guidance has
/// no exact window claim; its existing grounding and freshness gates remain.
@MainActor enum GuidanceSelectedWindowCheck {
  static func permits(evidence: ScreenEvidence, targetRect: CGRect) -> Bool {
    guard let id = evidence.windowID else { return true }
    guard let bounds = evidence.capturedWindowBounds else { return false }
    return GuidanceWindowVisibility.nativePermits(
      source: .init(
        id: id, ownerPID: evidence.foregroundPID,
        capturedBounds: bounds, sourceRect: evidence.screenRect),
      targetRect: targetRect, passiveWindowIDs: passiveWindowIDs)
  }

  /// Use currently registered own-window objects and their live input flags.
  /// Explanation surfaces and interactive controls are never exempted.
  static var passiveWindowIDs: Set<CGWindowID> {
    let allowed = Set(["org.opencompanion.cursor", "org.opencompanion.guidance.annotation"])
    let windows = NSApplication.shared.windows
    guard windows.count <= 4_096 else { return [] }
    return Set(
      windows.compactMap { window -> CGWindowID? in
        guard let id = window.identifier?.rawValue, allowed.contains(id),
          window.ignoresMouseEvents, !window.canBecomeKey, !window.canBecomeMain,
          !window.isKeyWindow, !window.isMainWindow,
          window.windowNumber > 0, UInt64(window.windowNumber) <= UInt64(UInt32.max)
        else { return nil }
        return CGWindowID(window.windowNumber)
      })
  }
}
