import AppKit
import QuartzCore
import Testing

@testable import OpenCompanion

@Suite @MainActor struct NotchActivityViewTests {
  @Test func preparingClearsThePreviousResponseBeforeListeningAppears() throws {
    let view = makeView()
    update(view, phase: .thinking)
    let layers = try ActivityLayers(view)
    #expect(layers.title == "Thinking")
    #expect(!layers.label.isHidden && !layers.indicator.isHidden)
    #expect(layers.dots.allSatisfy { !$0.isHidden })

    update(view, phase: .preparing)
    #expect(layers.title == nil)
    #expect(layers.label.contents == nil)
    #expect(layers.label.isHidden && layers.indicator.isHidden)
    #expect(layers.glow.isHidden)
    #expect((layers.bars + layers.dots).allSatisfy { $0.isHidden })
    #expect(!view.isAccessibilityElement())
    #expect(view.accessibilityLabel() == nil)

    update(view, phase: .listening, level: 0.6)
    #expect(layers.title == "Listening")
    #expect(!layers.label.isHidden && !layers.indicator.isHidden)
    #expect(!layers.glow.isHidden)
    #expect(layers.bars.allSatisfy { !$0.isHidden })
    #expect(layers.dots.allSatisfy { $0.isHidden })
    #expect(view.isAccessibilityElement())
    #expect(view.accessibilityLabel() == "OpenCompanion: Listening")
    #expect(view.hitTest(CGPoint(x: 8, y: 16)) == nil)
  }

  @Test func resetClearsRetainedTextAndEveryAnimationWithoutChangingParentOpacity() throws {
    let view = makeView()
    update(view, phase: .thinking)
    let layers = try ActivityLayers(view)
    layers.root.opacity = 0.37
    // An unattached NSView does not run activity animations. Seed a stale
    // transition on every retained layer so reset's cleanup is exercised.
    for layer in layers.all {
      let stale = CABasicAnimation(keyPath: "opacity")
      stale.fromValue = 0
      stale.toValue = 1
      stale.duration = 10
      layer.add(stale, forKey: "staleTurn")
    }
    #expect(layers.all.allSatisfy { $0.animation(forKey: "staleTurn") != nil })

    view.reset()

    #expect(layers.root.opacity == Float(0.37))
    #expect(layers.title == nil && layers.label.contents == nil)
    #expect(layers.label.isHidden && layers.indicator.isHidden && layers.glow.isHidden)
    #expect(layers.glow.colors == nil)
    #expect((layers.bars + layers.dots).allSatisfy { $0.isHidden && $0.backgroundColor == nil })
    #expect(layers.all.allSatisfy { ($0.animationKeys() ?? []).isEmpty })
    #expect(!view.isAccessibilityElement())
    #expect(view.accessibilityLabel() == nil)

    update(view, phase: .listening)
    #expect(layers.title == "Listening")
    #expect(layers.bars.allSatisfy { !$0.isHidden && $0.bounds.height == 2 })
  }

  @Test func directListeningEntryDoesNotRetainThePriorThinkingTransition() throws {
    let view = makeView()
    update(view, phase: .thinking)
    let layers = try ActivityLayers(view)
    for layer in [layers.label, layers.indicator] {
      let stale = CATransition()
      stale.type = .fade
      stale.duration = 10
      layer.add(stale, forKey: "phaseCrossfade")
    }

    update(view, phase: .listening, level: 0.4)

    #expect(layers.title == "Listening")
    #expect(layers.all.allSatisfy { $0.animation(forKey: "phaseCrossfade") == nil })
    #expect(layers.bars.allSatisfy { !$0.isHidden })
    #expect(layers.dots.allSatisfy { $0.isHidden })
    #expect(view.accessibilityLabel() == "OpenCompanion: Listening")
  }

  @Test func repeatedListeningUpdatesKeepActualBarGeometryFiniteAndBounded() throws {
    let view = makeView()
    update(view, phase: .listening)
    let layers = try ActivityLayers(view)
    var baseline: [CGRect] = []
    var maximum: [CGRect] = []
    for level in [0.0, 0.5, 1, .nan, .infinity, -.infinity, -1, 20, 0] {
      update(view, phase: .listening, level: level)
      #expect(layers.title == "Listening")
      #expect(!layers.indicator.isHidden)
      #expect(layers.bars.allSatisfy { !$0.isHidden })
      #expect(layers.dots.allSatisfy { $0.isHidden })
      for bar in layers.bars {
        #expect(bar.frame.origin.x.isFinite && bar.frame.origin.y.isFinite)
        #expect(bar.bounds.width.isFinite && bar.bounds.height.isFinite)
        #expect(bar.bounds.height >= 2 && bar.bounds.height <= 16)
        #expect(layers.indicator.bounds.contains(bar.frame))
      }
      let frames = layers.bars.map(\.frame)
      if baseline.isEmpty { baseline = frames }
      if level == 1 { maximum = frames }
      if !level.isFinite || level < 0 || level == 0 { #expect(frames == baseline) }
      if level.isFinite && level > 1 { #expect(frames == maximum) }
      #expect(layers.all.allSatisfy { $0.animation(forKey: "phaseCrossfade") == nil })
    }
  }

  private func makeView() -> NotchActivityView {
    NotchActivityView(frame: CGRect(x: 0, y: 0, width: 361, height: 32))
  }

  private func update(
    _ view: NotchActivityView, phase: NotchActivityPhase, level: Double = 0
  ) {
    view.update(phase: phase, level: level, cutoutWidth: 185, reduceMotion: false)
  }

  /// Inspect the production view's retained layers, without opening a window or
  /// requesting capture, microphone, speech, focus, or input-monitoring access.
  @MainActor private struct ActivityLayers {
    let root: CALayer
    let label: CATextLayer
    let indicator: CALayer
    let glow: CAGradientLayer
    let bars: [CALayer]
    let dots: [CALayer]

    init(_ view: NotchActivityView) throws {
      let rootLayer = try #require(view.layer)
      let textLayer = try #require(rootLayer.sublayers?.compactMap { $0 as? CATextLayer }.first)
      let indicatorLayer = try #require(rootLayer.sublayers?.first { !($0 is CATextLayer) })
      let gradient = try #require(
        indicatorLayer.sublayers?.compactMap { $0 as? CAGradientLayer }.first)
      let glyphs = (indicatorLayer.sublayers ?? []).filter { !($0 is CAGradientLayer) }
      try #require(glyphs.count == 8)
      root = rootLayer
      label = textLayer
      indicator = indicatorLayer
      glow = gradient
      bars = Array(glyphs.prefix(5))
      dots = Array(glyphs.suffix(3))
    }

    var title: String? {
      if let attributed = label.string as? NSAttributedString { return attributed.string }
      return label.string as? String
    }

    var all: [CALayer] { [root, label, indicator, glow] + bars + dots }
  }
}
