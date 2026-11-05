import AppKit
import CompanionCore
import Testing

@testable import OpenCompanion

struct ExplanationOverlayLayoutTests {
  @Test func wakeAndSessionActivationMustBothPermitPresentation() {
    var state = ExplanationOverlayAvailability()
    state.awake = false
    state.sessionActive = false
    state.awake = true
    #expect(!state.canPresent)
    state.sessionActive = true
    #expect(state.canPresent)
    state.awake = false
    state.sessionActive = true
    #expect(!state.canPresent)
  }

  @Test func compactStageUsesLowerRightOfIntendedNegativeOriginDisplay() throws {
    let display = CGRect(x: -1920, y: -180, width: 1920, height: 1040)
    let frames = try #require(
      ExplanationOverlayLayout.frames(
        documentSize: CGSize(width: 900, height: 560), visibleFrame: display))
    #expect(display.contains(frames.stage) && display.contains(frames.clear))
    #expect(frames.stage.width <= 620 && frames.stage.height <= 420)
    #expect(abs(frames.stage.width / frames.stage.height - 900.0 / 560.0) < 0.000_001)
    #expect(frames.stage.maxX == display.maxX - 20)
    #expect(frames.stage.minY == display.minY + 24)
    #expect(frames.clear.minY >= frames.stage.maxY)
    #expect(frames.clear.size == CGSize(width: 74, height: 32))
  }

  @Test func smallDisplayStillContainsTheStageAndBoundedClearControl() throws {
    let display = CGRect(x: 900, y: -900, width: 320, height: 240)
    let frames = try #require(
      ExplanationOverlayLayout.frames(
        documentSize: CGSize(width: 560, height: 900), visibleFrame: display))
    #expect(display.contains(frames.stage) && display.contains(frames.clear))
    #expect(!frames.stage.intersects(frames.clear))
    #expect(frames.stage.width > 0 && frames.stage.height > 0)
  }

  @Test func unusableGeometryNeverCreatesWindows() {
    let display = CGRect(x: 0, y: 0, width: 1512, height: 900)
    for size in [
      CGSize.zero, CGSize(width: -900, height: 560), CGSize(width: 900, height: -560),
      CGSize(width: CGFloat.nan, height: 560), CGSize(width: 900, height: CGFloat.infinity),
    ] {
      #expect(ExplanationOverlayLayout.frames(documentSize: size, visibleFrame: display) == nil)
    }
    for frame in [
      CGRect.zero, CGRect(x: 0, y: 0, width: -300, height: 400),
      CGRect(x: CGFloat.nan, y: 0, width: 1512, height: 900),
      CGRect(x: 0, y: 0, width: 1512, height: CGFloat.infinity),
    ] {
      #expect(
        ExplanationOverlayLayout.frames(
          documentSize: CGSize(width: 900, height: 560), visibleFrame: frame) == nil)
    }
  }
}

/// Native objects are constructed without ordering windows on screen. The
/// window-server pass-through flag is asserted in addition to NSView hitTest.
@Suite @MainActor struct ExplanationOverlayNativeTests {
  @Test func passiveCanvasIsTransparentAndCannotStartAnEdit() {
    let canvas = RetainedCanvasView(frame: CGRect(x: 0, y: 0, width: 620, height: 420))
    canvas.drawing = true
    canvas.presentation = .passiveOverlay
    #expect(canvas.layer?.backgroundColor?.alpha == 0)
    #expect(!canvas.acceptsFirstResponder && !canvas.drawing)
    #expect(canvas.hitTest(CGPoint(x: 40, y: 40)) == nil)
    canvas.presentation = .editor
    #expect(canvas.layer?.backgroundColor?.alpha == 1)
    #expect(canvas.acceptsFirstResponder)
  }

  @Test func visualWindowIsWhollyClickThroughAndClearWindowIsTightlyBounded() {
    _ = NSApplication.shared
    let canvas = RetainedCanvasView(frame: CGRect(x: 0, y: 0, width: 620, height: 420))
    let visual = ExplanationOverlay.makeVisualPanel(
      frame: CGRect(x: 800, y: 60, width: 620, height: 420), canvas: canvas)
    let clear = ExplanationOverlay.makeClearPanel(
      frame: CGRect(x: 1073, y: 490, width: 74, height: 32), action: {})
    defer {
      visual.contentView = nil
      visual.close()
      clear.contentView = nil
      clear.close()
    }
    #expect(visual.ignoresMouseEvents && !clear.ignoresMouseEvents)
    #expect(!visual.isOpaque && visual.backgroundColor?.alphaComponent == 0)
    #expect(!visual.canBecomeKey && !visual.canBecomeMain)
    #expect(!clear.canBecomeKey && !clear.canBecomeMain)
    #expect(visual.sharingType == .none && clear.sharingType == .none)
    #expect(clear.frame.size == CGSize(width: 74, height: 32))
    #expect(canvas.presentation == .passiveOverlay)
    #expect(!visual.isVisible && !clear.isVisible)
  }
}
