import AppKit
import Combine
import QuartzCore

/// Retained, noninteractive activity wings. The center camera region has no
/// content; the owning host supplies the black attachment shape and clipping.
@MainActor final class NotchActivityView: NSView {
  private let labelLayer = CATextLayer()
  private let indicatorWing = CALayer()
  private let glowLayer = CAGradientLayer()
  private let bars = (0..<5).map { _ in CALayer() }
  private let dots = (0..<3).map { _ in CALayer() }
  private var visibilitySubscription: AnyCancellable?
  private var phase = NotchActivityPhase.idle
  private var level = 0.0
  private var cutoutWidth: CGFloat = 0
  private var reduceMotion = false
  private var animatedPhase: NotchActivityPhase?

  override var isFlipped: Bool { true }

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    configureLayers()
  }

  required init?(coder: NSCoder) {
    super.init(coder: coder)
    configureLayers()
  }

  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  /// Clears a previous turn before the owner reveals a new microphone session.
  /// Container opacity remains entirely under the parent's control.
  func reset() {
    withoutImplicitAnimations {
      layer?.removeAllAnimations()
      stopAnimations()
      phase = .idle
      level = 0
      clearVisibleContent()
    }
  }

  func update(
    phase: NotchActivityPhase, level: Double, cutoutWidth: CGFloat, reduceMotion: Bool
  ) {
    let incomingResponse = phase == .thinking || phase == .speaking
    let crossfade =
      incomingResponse && self.phase != .idle && self.phase != .preparing
      && self.phase != phase && !reduceMotion
    let enteringInput = self.phase != phase && (phase == .preparing || phase == .listening)
    let changedAppearance = self.phase != phase || self.reduceMotion != reduceMotion
    self.phase = phase
    // Idle keeps the last rendered bars while the owner fades this container.
    if phase == .preparing {
      self.level = 0
    } else if phase != .idle {
      self.level = level.isFinite ? min(1, max(0, level)) : 0
    }
    self.cutoutWidth = cutoutWidth.isFinite ? max(0, cutoutWidth) : 0
    self.reduceMotion = reduceMotion
    withoutImplicitAnimations {
      if changedAppearance {
        stopAnimations(preservingPresentation: phase == .idle)
        if enteringInput { clearVisibleContent() }
        if crossfade { crossfadePhase() }
        updatePhaseAppearance()
      }
      layoutLayers()
    }
    synchronizeAnimations()
  }

  override func layout() {
    super.layout()
    layoutLayers()
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    visibilitySubscription = nil
    if let window {
      visibilitySubscription = NotificationCenter.default.publisher(
        for: NSWindow.didChangeOcclusionStateNotification, object: window
      )
      .receive(on: RunLoop.main)
      .sink { [weak self] _ in
        MainActor.assumeIsolated { self?.synchronizeAnimations() }
      }
    }
    updateScale()
    synchronizeAnimations()
  }

  override func viewDidChangeBackingProperties() {
    super.viewDidChangeBackingProperties()
    updateScale()
  }

  override func viewDidHide() {
    super.viewDidHide()
    stopAnimations()
  }

  override func viewDidUnhide() {
    super.viewDidUnhide()
    synchronizeAnimations()
  }

  private func configureLayers() {
    wantsLayer = true
    guard let layer else { return }
    layer.isGeometryFlipped = true
    layer.masksToBounds = true
    labelLayer.alignmentMode = .right
    labelLayer.truncationMode = .end
    labelLayer.isWrapped = false
    labelLayer.isHidden = true
    layer.addSublayer(labelLayer)
    indicatorWing.masksToBounds = true
    indicatorWing.isHidden = true
    layer.addSublayer(indicatorWing)

    glowLayer.type = .radial
    glowLayer.startPoint = CGPoint(x: 0.85, y: 0.95)
    glowLayer.endPoint = CGPoint(x: 0.12, y: 0.05)
    glowLayer.locations = [0, 0.42, 1]
    indicatorWing.addSublayer(glowLayer)
    for bar in bars {
      bar.cornerRadius = 1.25
      indicatorWing.addSublayer(bar)
    }
    for dot in dots {
      dot.cornerRadius = 1.8
      indicatorWing.addSublayer(dot)
    }
    setAccessibilityRole(.staticText)
    updateScale()
    reset()
  }

  private func updateScale() {
    let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
    labelLayer.contentsScale = scale
    glowLayer.contentsScale = scale
  }

  private func updatePhaseAppearance() {
    guard phase != .preparing else {
      clearVisibleContent()
      return
    }
    guard phase != .idle else {
      setAccessibilityElement(false)
      setAccessibilityLabel(nil)
      return
    }
    withoutImplicitAnimations {
      labelLayer.isHidden = false
      indicatorWing.isHidden = false
      glowLayer.isHidden = false
      let color =
        phase == .thinking
        ? NSColor(srgbRed: 0.91, green: 0.35, blue: 0.89, alpha: 1)
        : NSColor(srgbRed: 0.17, green: 0.88, blue: 0.98, alpha: 1)
      glowLayer.colors = [
        color.withAlphaComponent(0.70).cgColor,
        color.withAlphaComponent(0.22).cgColor,
        color.withAlphaComponent(0).cgColor,
      ]
      glowLayer.opacity = reduceMotion ? 0.60 : 0.72
      for bar in bars {
        bar.backgroundColor = color.cgColor
        bar.isHidden = phase != .listening
      }
      for dot in dots {
        dot.backgroundColor = color.cgColor
        dot.opacity = 0.68
        dot.isHidden = phase == .listening || phase == .idle
      }
      let title: String =
        switch phase {
        case .idle: ""
        case .preparing: "Preparing"
        case .listening: "Listening"
        case .thinking: "Thinking"
        case .speaking: "Speaking"
        }
      let baseFont = NSFont.systemFont(ofSize: 11.5, weight: .medium)
      let font =
        baseFont.fontDescriptor.withDesign(.rounded)
        .flatMap { NSFont(descriptor: $0, size: baseFont.pointSize) } ?? baseFont
      labelLayer.string = NSAttributedString(
        string: title, attributes: [.font: font, .foregroundColor: NSColor(white: 0.96, alpha: 1)])
      setAccessibilityElement(true)
      setAccessibilityLabel("OpenCompanion: \(title)")
    }
  }

  private func layoutLayers() {
    guard bounds.width.isFinite, bounds.height.isFinite else { return }
    withoutImplicitAnimations {
      let width = max(0, bounds.width)
      let height = max(0, bounds.height)
      let camera = min(cutoutWidth, width)
      let totalWings = NotchActivityMetrics.leadingWing + NotchActivityMetrics.trailingWing
      let wingScale = min(1, max(0, (width - camera) / totalWings))
      let leading = NotchActivityMetrics.leadingWing * wingScale
      let trailing = NotchActivityMetrics.trailingWing * wingScale
      let textHeight = min(17, height)
      labelLayer.frame = CGRect(
        x: 6, y: (height - textHeight) / 2 + 0.5,
        width: max(0, leading - 14), height: textHeight)
      indicatorWing.frame = CGRect(x: leading + camera, y: 0, width: trailing, height: height)
      glowLayer.frame = CGRect(x: 0, y: 0, width: trailing, height: height)

      // A quiet two-point floor denotes an armed microphone. All changes in
      // height come from the supplied real level, never a synthetic waveform.
      let weights: [CGFloat] = [0.38, 0.72, 1, 0.78, 0.45]
      let maximum = min(16, max(2, height - 10))
      let indicatorWidth: CGFloat = 26.5
      let origin = max(4, min(14, (trailing - indicatorWidth) / 2))
      for (index, bar) in bars.enumerated() {
        let barHeight = min(height, 2 + (maximum - 2) * CGFloat(level) * weights[index])
        bar.frame = CGRect(
          x: origin + CGFloat(index) * 6, y: (height - barHeight) / 2,
          width: 2.5, height: barHeight)
      }
      for (index, dot) in dots.enumerated() {
        dot.frame = CGRect(
          x: origin + 2 + CGFloat(index) * 8, y: (height - 3.6) / 2,
          width: 3.6, height: 3.6)
      }
    }
  }

  private func synchronizeAnimations() {
    guard phase != .idle, phase != .preparing, !reduceMotion, !isHiddenOrHasHiddenAncestor,
      let window, window.isVisible, window.occlusionState.contains(.visible)
    else {
      stopAnimations()
      return
    }
    guard animatedPhase != phase else { return }
    animatedPhase = phase
    let breath = CABasicAnimation(keyPath: "opacity")
    breath.fromValue = 0.55
    breath.toValue = 0.80
    breath.duration = 1.5
    breath.autoreverses = true
    breath.repeatCount = .infinity
    breath.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
    glowLayer.add(breath, forKey: "activityGlow")

    // Dots communicate work in progress, not audio amplitude.
    guard phase != .listening else { return }
    let now = CACurrentMediaTime()
    for (index, dot) in dots.enumerated() {
      let pulse = CAKeyframeAnimation(keyPath: "opacity")
      pulse.values = [0.3, 1, 0.3]
      pulse.keyTimes = [0, 0.4, 1]
      pulse.duration = 1.15
      pulse.beginTime = now + Double(index) * 0.16
      pulse.repeatCount = .infinity
      pulse.timingFunctions = [CAMediaTimingFunction(name: .easeInEaseOut)]
      dot.add(pulse, forKey: "activityDot")
    }
  }

  private func crossfadePhase() {
    let transition = CATransition()
    transition.type = .fade
    transition.duration = 0.15
    transition.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
    labelLayer.add(transition, forKey: "phaseCrossfade")
    indicatorWing.add(transition, forKey: "phaseCrossfade")
  }

  private func clearVisibleContent() {
    labelLayer.string = nil
    labelLayer.contents = nil
    labelLayer.isHidden = true
    indicatorWing.isHidden = true
    glowLayer.isHidden = true
    glowLayer.colors = nil
    for bar in bars {
      bar.isHidden = true
      bar.backgroundColor = nil
    }
    for dot in dots {
      dot.isHidden = true
      dot.backgroundColor = nil
    }
    setAccessibilityElement(false)
    setAccessibilityLabel(nil)
  }

  private func stopAnimations(preservingPresentation: Bool = false) {
    let glowOpacity = glowLayer.presentation()?.opacity ?? glowLayer.opacity
    let dotOpacities = dots.map { $0.presentation()?.opacity ?? $0.opacity }
    animatedPhase = nil
    labelLayer.removeAllAnimations()
    indicatorWing.removeAllAnimations()
    glowLayer.removeAllAnimations()
    for dot in dots { dot.removeAllAnimations() }
    for bar in bars { bar.removeAllAnimations() }
    if preservingPresentation {
      withoutImplicitAnimations {
        glowLayer.opacity = glowOpacity
        for (dot, opacity) in zip(dots, dotOpacities) { dot.opacity = opacity }
      }
    }
  }

  private func withoutImplicitAnimations(_ change: () -> Void) {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    change()
    CATransaction.commit()
  }
}
