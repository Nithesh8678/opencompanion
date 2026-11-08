import AppKit
import Foundation
import Testing

@testable import OpenCompanion

struct CursorCompanionWindowPlacementTests {
  @Test(arguments: [CGFloat(1), CGFloat(-1)])
  func rebasingRoundedWindowFramesPreservesGlobalBodyAndCaption(_ sign: CGFloat) {
    let requested = CursorCompanionPlacement(
      frame: CGRect(
        x: sign * 941.637139892578, y: sign * 207.846585083, width: 354.4, height: 104.7),
      bodyPoint: CGPoint(x: 327.5, y: 75),
      bubbleFrame: CGRect(x: 12, y: 12, width: 300, height: 63))
    let actual = CGRect(
      x: floor(requested.frame.minX), y: floor(requested.frame.minY), width: 355, height: 105)
    let submitted = CursorCompanionLayout.rebased(requested, windowFrame: actual)
    #expect(submitted.frame == actual)
    assertPoint(globalBody(submitted), equals: globalBody(requested))
    assertRect(globalCaption(submitted), equals: globalCaption(requested))
    let uncompensated = CursorCompanionPlacement(
      frame: actual, bodyPoint: requested.bodyPoint, bubbleFrame: requested.bubbleFrame)
    let wrong = globalBody(uncompensated)
    let expected = globalBody(requested)
    let uncompensatedOffset = CGPoint(
      x: actual.minX - requested.frame.minX,
      y: actual.maxY - requested.frame.maxY)
    #expect(abs(wrong.x - expected.x - uncompensatedOffset.x) < 0.000_001)
    #expect(abs(wrong.y - expected.y - uncompensatedOffset.y) < 0.000_001)
    #expect(hypot(uncompensatedOffset.x, uncompensatedOffset.y) > 0.000_001)
  }

  @Test func zeroCaptionStaysAbsentAndInvalidNativeFramesCannotCorruptPlacement() {
    let original = CursorCompanionPlacement(
      frame: CGRect(x: -200.25, y: 90.75, width: 80, height: 60),
      bodyPoint: CGPoint(x: 40, y: 30), bubbleFrame: .zero)
    let result = CursorCompanionLayout.rebased(
      original, windowFrame: CGRect(x: -201, y: 90, width: 81, height: 61))
    #expect(result.bubbleFrame == .zero)
    assertPoint(globalBody(result), equals: globalBody(original))
    for invalid in [
      CGRect.zero, CGRect(x: CGFloat.nan, y: 0, width: 80, height: 60),
      CGRect(x: 0, y: 0, width: -1, height: 60),
    ] {
      #expect(CursorCompanionLayout.rebased(original, windowFrame: invalid) == original)
    }
  }

  private func globalBody(_ placement: CursorCompanionPlacement) -> CGPoint {
    CGPoint(
      x: placement.frame.minX + placement.bodyPoint.x,
      y: placement.frame.maxY - placement.bodyPoint.y)
  }

  private func globalCaption(_ placement: CursorCompanionPlacement) -> CGRect {
    CGRect(
      x: placement.frame.minX + placement.bubbleFrame.minX,
      y: placement.frame.maxY - placement.bubbleFrame.maxY,
      width: placement.bubbleFrame.width, height: placement.bubbleFrame.height)
  }

  private func assertPoint(_ actual: CGPoint, equals expected: CGPoint) {
    #expect(abs(actual.x - expected.x) < 0.000_001)
    #expect(abs(actual.y - expected.y) < 0.000_001)
  }

  private func assertRect(_ actual: CGRect, equals expected: CGRect) {
    assertPoint(actual.origin, equals: expected.origin)
    #expect(actual.size == expected.size)
  }
}

/// Native objects stay unordered and passive. These checks exercise the real
/// glyph's submitted layer transform through its own NSWindow coordinate API,
/// with authored fractional requests on positive and negative-origin displays.
@Suite @MainActor struct CursorCompanionNativeWindowPlacementTests {
  @Test(arguments: [CGFloat(1), CGFloat(-1)])
  func actualWindowFrameKeepsFractionalGlyphTipAndCaptionAtRequestedGlobalPoints(_ sign: CGFloat)
    throws
  {
    _ = NSApplication.shared
    let requested = CursorCompanionPlacement(
      frame: CGRect(
        x: sign * 941.637139892578, y: sign * 207.846585083, width: 354.4, height: 104.7),
      bodyPoint: CGPoint(x: 327.5, y: 75),
      bubbleFrame: CGRect(x: 12, y: 12, width: 300, height: 63))
    let panel = NSPanel(
      contentRect: CGRect(x: 0, y: 0, width: 80, height: 60),
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered, defer: false)
    panel.isReleasedWhenClosed = false
    panel.ignoresMouseEvents = true
    let view = CursorCompanionView(frame: .zero)
    panel.contentView = view
    defer {
      panel.contentView = nil
      panel.close()
    }
    // Exercise both the actual accepted fractional frame and an explicitly
    // quantized accepted frame; the latter reproduces the observed host shift.
    for frame in [requested.frame, requested.frame.integral] {
      panel.setFrame(frame, display: false)
      let submitted = CursorCompanionLayout.rebased(requested, windowFrame: panel.frame)
      view.frame = CGRect(origin: .zero, size: panel.frame.size)
      view.update(
        phase: .speaking, text: "Public native caption", level: 0,
        bodyPoint: submitted.bodyPoint, bubbleFrame: submitted.bubbleFrame,
        rotation: 0, reduceMotion: true)
      view.layoutSubtreeIfNeeded()
      let tip = try #require(view.submittedBodyTip)
      let actualTip = panel.convertPoint(toScreen: view.convert(tip, to: nil))
      let expectedCenter = CGPoint(
        x: requested.frame.minX + requested.bodyPoint.x,
        y: requested.frame.maxY - requested.bodyPoint.y)
      #expect(abs(actualTip.x - expectedCenter.x - CursorCompanionGlyph.tipOffset.x) < 0.000_001)
      #expect(abs(actualTip.y - expectedCenter.y + CursorCompanionGlyph.tipOffset.y) < 0.000_001)
      let caption = try #require(view.visibleCaptionFrame)
      let actualCaption = panel.convertToScreen(view.convert(caption, to: nil))
      let expectedCaption = CGRect(
        x: requested.frame.minX + requested.bubbleFrame.minX,
        y: requested.frame.maxY - requested.bubbleFrame.maxY,
        width: requested.bubbleFrame.width, height: requested.bubbleFrame.height)
      #expect(abs(actualCaption.minX - expectedCaption.minX) < 0.000_001)
      #expect(abs(actualCaption.minY - expectedCaption.minY) < 0.000_001)
      #expect(actualCaption.size == expectedCaption.size)
      #expect(!panel.isVisible && panel.ignoresMouseEvents)
    }
  }
}
