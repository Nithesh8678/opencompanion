import Foundation

enum NotchSurface: String, Sendable { case tucked, peek, conversation }

/// AppKit global logical points. The camera housing comes from the display's
/// actual auxiliary areas; content never occupies that physical cutout.
struct NotchLayout: Sendable {
  let display: CGRect
  let visible: CGRect
  let cutout: CGRect?

  init(display: CGRect, visible: CGRect, safeTop: CGFloat, left: CGRect?, right: CGRect?) {
    self.display = display
    self.visible = visible
    if safeTop > 0, let left, let right,
      left.maxX >= display.minX, right.minX <= display.maxX,
      right.minX > left.maxX, right.minX - left.maxX < display.width * 0.8
    {
      cutout = CGRect(
        x: left.maxX, y: display.maxY - safeTop,
        width: right.minX - left.maxX, height: safeTop)
    } else {
      cutout = nil
    }
  }

  var topInset: CGFloat { cutout?.height ?? 0 }
  var hoverTarget: CGRect {
    (cutout ?? frame(for: .tucked)).insetBy(dx: -10, dy: -5)
      .intersection(display)
  }

  func frame(for surface: NotchSurface) -> CGRect {
    if surface == .tucked, let cutout { return cutout }
    let requested: CGSize
    switch surface {
    case .tucked: requested = CGSize(width: 96, height: 36)
    case .peek: requested = CGSize(width: 380, height: 142 + topInset)
    case .conversation: requested = CGSize(width: 430, height: 330 + topInset)
    }
    let size = CGSize(
      width: min(requested.width, display.width - 12),
      height: min(requested.height, display.height - 12))
    let center = cutout?.midX ?? display.midX
    let top = cutout != nil ? display.maxY : min(visible.maxY, display.maxY) - 5
    return CGRect(
      x: min(max(display.minX + 6, center - size.width / 2), display.maxX - size.width - 6),
      y: max(display.minY + 6, top - size.height), width: size.width, height: size.height)
  }
}

/// Pure hover policy. A click/keyboard-opened conversation remains pinned;
/// explicit dismissal must see a pointer exit before hover can open it again.
struct NotchHoverPolicy {
  enum Action: Equatable { case none, reveal, tuck }
  var suppressedUntilExit = false

  mutating func action(
    pointer: CGPoint, layout: NotchLayout, surface: NotchSurface,
    displayedFrame: CGRect, voiceActive: Bool
  ) -> Action {
    let target = layout.hoverTarget
    let retained =
      surface == .tucked ? target : target.union(displayedFrame.insetBy(dx: -6, dy: -6))
    if suppressedUntilExit {
      if !containsPointer(pointer, in: retained) { suppressedUntilExit = false }
      return .none
    }
    if surface == .conversation || voiceActive { return .none }
    if containsPointer(pointer, in: retained) { return surface == .tucked ? .reveal : .none }
    return surface == .peek ? .tuck : .none
  }

  /// CGRect uses half-open bounds. The system pointer can rest exactly on the
  /// display's top edge, which is also the clipped camera housing's maxY.
  private func containsPointer(_ pointer: CGPoint, in rect: CGRect) -> Bool {
    !rect.isNull && pointer.x.isFinite && pointer.y.isFinite
      && pointer.x >= rect.minX && pointer.x <= rect.maxX
      && pointer.y >= rect.minY && pointer.y <= rect.maxY
  }
}
