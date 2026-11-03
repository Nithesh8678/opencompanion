import Foundation
import Testing

@testable import OpenCompanion

@Suite struct NotchLayoutTests {
  private var layout: NotchLayout {
    NotchLayout(
      display: CGRect(x: -1512, y: 120, width: 1512, height: 982),
      visible: CGRect(x: -1512, y: 145, width: 1512, height: 925), safeTop: 32,
      left: CGRect(x: -1512, y: 1070, width: 654, height: 32),
      right: CGRect(x: -654, y: 1070, width: 654, height: 32))
  }
  @Test func tuckedFrameExactlyMatchesActualCutoutWithoutGap() throws {
    let cutout = try #require(layout.cutout)
    #expect(layout.frame(for: .tucked) == cutout)
    #expect(cutout == CGRect(x: -858, y: 1070, width: 204, height: 32))
    for surface in [NotchSurface.peek, .conversation, .settings] {
      #expect(layout.frame(for: surface).maxY == layout.display.maxY)
      #expect(layout.frame(for: surface).midX == cutout.midX)
    }
  }
  @Test func measuredBodyProportionsIncludeOnlyTheAdditionalShoulders() {
    #expect(layout.frame(for: .peek).size == CGSize(width: 530, height: 160))
    #expect(layout.frame(for: .settings).size == CGSize(width: 814, height: 650))
    #expect(layout.frame(for: .conversation).width == 614)
  }
  @Test func notchlessFallbackKeepsControlsBelowMenuBar() {
    let plain = NotchLayout(
      display: CGRect(x: 2000, y: -200, width: 1920, height: 1080),
      visible: CGRect(x: 2000, y: -180, width: 1920, height: 1035), safeTop: 0, left: nil,
      right: nil)
    #expect(plain.cutout == nil && plain.topInset == 0)
    #expect(plain.frame(for: .peek).maxY == plain.visible.maxY - 5)
    #expect(plain.display.contains(plain.frame(for: .conversation)))
  }
  @Test func hoverPeekTucksOnExitAndNeverUnpinsExplicitConversationOrVoice() {
    var policy = NotchHoverPolicy()
    let overNotch = CGPoint(x: -756, y: 1085)
    #expect(
      policy.action(
        pointer: overNotch, layout: layout, surface: .tucked,
        displayedFrame: layout.frame(for: .tucked), voiceActive: false) == .reveal)
    let outside = CGPoint(x: -1300, y: 500)
    #expect(
      policy.action(
        pointer: outside, layout: layout, surface: .peek,
        displayedFrame: layout.frame(for: .peek), voiceActive: false) == .tuck)
    #expect(
      policy.action(
        pointer: outside, layout: layout, surface: .conversation,
        displayedFrame: layout.frame(for: .conversation), voiceActive: false) == .none)
    #expect(
      policy.action(
        pointer: outside, layout: layout, surface: .peek,
        displayedFrame: layout.frame(for: .peek), voiceActive: true) == .none)
  }
  @Test func dismissalNeedsPointerExitBeforeRearmingHover() {
    var policy = NotchHoverPolicy(suppressedUntilExit: true)
    let frame = layout.frame(for: .tucked)
    #expect(
      policy.action(
        pointer: CGPoint(x: frame.midX, y: frame.midY), layout: layout,
        surface: .tucked, displayedFrame: frame, voiceActive: false) == .none)
    #expect(policy.suppressedUntilExit)
    _ = policy.action(
      pointer: CGPoint(x: -1300, y: 500), layout: layout,
      surface: .tucked, displayedFrame: frame, voiceActive: false)
    #expect(!policy.suppressedUntilExit)
    #expect(
      policy.action(
        pointer: CGPoint(x: frame.midX, y: frame.midY), layout: layout,
        surface: .tucked, displayedFrame: frame, voiceActive: false) == .reveal)
  }

  @Test func physicalCameraHoverIncludesTheVeryTopDisplayEdge() throws {
    let physical = NotchLayout(
      display: CGRect(x: 0, y: 0, width: 1512, height: 982),
      visible: CGRect(x: 0, y: 0, width: 1512, height: 950), safeTop: 32,
      left: CGRect(x: 0, y: 950, width: 663, height: 32),
      right: CGRect(x: 848, y: 950, width: 664, height: 32))
    #expect(physical.cutout == CGRect(x: 663, y: 950, width: 185, height: 32))
    var policy = NotchHoverPolicy()
    for point in [
      CGPoint(x: 755.5, y: 982), CGPoint(x: 663, y: 982), CGPoint(x: 848, y: 982),
      CGPoint(x: 755.5, y: 950), CGPoint(x: 755.5, y: 945),
    ] {
      #expect(
        policy.action(
          pointer: point, layout: physical, surface: .tucked,
          displayedFrame: physical.frame(for: .tucked), voiceActive: false) == .reveal)
    }
    for point in [
      CGPoint(x: 755.5, y: 983), CGPoint(x: 755.5, y: 944), CGPoint(x: 650, y: 970),
      CGPoint(x: CGFloat.nan, y: 982),
    ] {
      #expect(
        policy.action(
          pointer: point, layout: physical, surface: .tucked,
          displayedFrame: physical.frame(for: .tucked), voiceActive: false) == .none)
    }
    policy.suppressedUntilExit = true
    _ = policy.action(
      pointer: CGPoint(x: 755.5, y: 982), layout: physical, surface: .tucked,
      displayedFrame: physical.frame(for: .tucked), voiceActive: false)
    #expect(policy.suppressedUntilExit)
  }
}
