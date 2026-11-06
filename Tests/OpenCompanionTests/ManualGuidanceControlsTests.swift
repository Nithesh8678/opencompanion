import AppKit
import Foundation
import Testing

@testable import OpenCompanion

struct ManualGuidanceControlsTests {
  @Test @MainActor func passiveMarksDoNotInheritAutomaticAppDeactivationHiding() {
    _ = NSApplication.shared
    let panel = OverlayHost.makePanel(display: CGRect(x: -1512, y: 0, width: 1512, height: 982))
    defer { panel.close() }
    #expect(!panel.hidesOnDeactivate)
    #expect(panel.ignoresMouseEvents && !panel.canBecomeKey && !panel.canBecomeMain)
    #expect(!panel.isVisible && !panel.isKeyWindow)
    #expect(panel.level == .floating)
  }

  @Test @MainActor func hostedButtonsAreEligibleWithoutActivatingTheirPanel() throws {
    _ = NSApplication.shared
    let content = ManualGuidanceControls.makeContentView(proceed: {}, stop: {})
    let panel = AnnotationPanel(
      contentRect: CGRect(origin: .zero, size: ManualGuidanceControlsLayout.size),
      styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    panel.isReleasedWhenClosed = false
    panel.contentView = content
    defer { panel.contentView = nil; panel.close() }
    content.layoutSubtreeIfNeeded()
    #expect(!panel.canBecomeKey && !panel.isKeyWindow && !panel.isVisible)
    for point in [CGPoint(x: 98, y: 27), CGPoint(x: 208, y: 27)] {
      let hit = try #require(content.hitTest(point))
      #expect(hit.acceptsFirstMouse(for: nil))
      #expect(!hit.needsPanelToBecomeKey)
    }
  }

  @Test func menuAreaTargetsAndTallTargetsKeepControlsVisibleAndDisjoint() throws {
    let visible = CGRect(x: 0, y: 38, width: 1512, height: 912)
    for target in [
      CGRect(x: 100, y: 970, width: 20, height: 10),
      CGRect(x: 300, y: 60, width: 300, height: 870),
    ] {
      let controls = try #require(
        ManualGuidanceControlsLayout.frame(target: target, visibleFrame: visible))
      #expect(visible.insetBy(dx: 8, dy: 8).contains(controls))
      #expect(!target.intersects(controls))
    }
  }

  @Test func translatedAndUnavoidablyOverlappingTargetsKeepControlsAvailable() throws {
    let visible = CGRect(x: -1512, y: -944, width: 1512, height: 912)
    let tall = CGRect(x: -1212, y: -922, width: 300, height: 870)
    let side = try #require(
      ManualGuidanceControlsLayout.frame(target: tall, visibleFrame: visible))
    #expect(visible.insetBy(dx: 8, dy: 8).contains(side))
    #expect(!tall.intersects(side))
    let fallback = try #require(
      ManualGuidanceControlsLayout.frame(target: visible, visibleFrame: visible))
    #expect(visible.insetBy(dx: 8, dy: 8).contains(fallback))
  }

  @Test func invalidRawSizesAndNonfiniteFramesCannotPlaceControls() {
    let visible = CGRect(x: 0, y: 38, width: 1512, height: 912)
    for target in [
      CGRect(x: 10, y: 20, width: -100, height: 30),
      CGRect(x: 10, y: 20, width: 100, height: -30),
      CGRect(x: CGFloat.nan, y: 20, width: 100, height: 30),
    ] {
      #expect(ManualGuidanceControlsLayout.frame(target: target, visibleFrame: visible) == nil)
    }
    #expect(ManualGuidanceControlsLayout.frame(
      target: CGRect(x: 10, y: 20, width: 100, height: 30),
      visibleFrame: CGRect(x: 0, y: 0, width: -1512, height: 982)) == nil)
  }

  @Test func controlsStayOnNegativeOriginAndSmallDisplays() throws {
    for display in [
      CGRect(x: -1512, y: -982, width: 1512, height: 950),
      CGRect(x: 0, y: 600, width: 400, height: 300),
    ] {
      for target in [
        CGRect(x: display.minX, y: display.minY, width: 40, height: 30),
        CGRect(x: display.maxX - 60, y: display.maxY - 40, width: 60, height: 40),
      ] {
        let controls = try #require(
          ManualGuidanceControlsLayout.frame(target: target, visibleFrame: display))
        #expect(display.contains(controls))
        #expect(!target.intersects(controls))
      }
    }
    #expect(ManualGuidanceControlsLayout.frame(target: .zero, visibleFrame: .zero) == nil)
  }

  @Test func onlyAnExplicitBooleanAsksToWaitForAManualAction() throws {
    let decoder = JSONDecoder()
    let legacy = try decoder.decode(
      ProviderTarget.self,
      from: Data(
        #"{"x":0.1,"y":0.2,"width":0.2,"height":0.05,"instruction":"Explain","advanceOn":"manual"}"#
          .utf8))
    #expect(legacy.awaitUser == nil)
    let action = try decoder.decode(
      ProviderTarget.self,
      from: Data(
        #"{"pixelBounds":{"x":20,"y":30,"width":200,"height":40},"instruction":"Type here","advanceOn":"manual","awaitUser":true}"#
          .utf8))
    #expect(action.awaitUser == true)
    #expect(throws: (any Error).self) {
      try decoder.decode(
        ProviderTarget.self,
        from: Data(
          #"{"pixelBounds":{"x":20,"y":30,"width":200,"height":40},"instruction":"Type here","advanceOn":"manual","awaitUser":"yes"}"#
            .utf8))
    }
  }
}
