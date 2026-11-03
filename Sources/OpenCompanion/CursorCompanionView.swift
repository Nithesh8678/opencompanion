import AppKit
import Combine
import QuartzCore

/// Passive native presentation only. The coordinator supplies the latest pose
/// and visible text prefix; this view never samples input or owns a reveal clock.
@MainActor final class CursorCompanionView: NSView {
  private let bodyLayer = CAShapeLayer()
  private let bubbleLayer = CALayer()
  private let textLayer = CATextLayer()
  private let bars = (0..<5).map { _ in CALayer() }
  private let dots = (0..<3).map { _ in CALayer() }
  private let red = NSColor(srgbRed: 0.93, green: 0.19, blue: 0.23, alpha: 1)
  private let captionFont: NSFont = {
    let base = NSFont.systemFont(ofSize: 12.5, weight: .semibold)
    return base.fontDescriptor.withDesign(.rounded)
      .flatMap { NSFont(descriptor: $0, size: base.pointSize) } ?? base
  }()
  private let lineHeight: CGFloat = 17
  private var visibilitySubscription: AnyCancellable?
  private var phase = NotchActivityPhase.idle
  private var reduceMotion = false
  private var visibleText = ""
  private var animatedPhase: NotchActivityPhase?
  private var measurementKey: MeasurementKey?
  private var measuredSize = CGSize.zero
  private var bubbleSize = CGSize.zero

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

  /// `maxWidth` includes the bubble's horizontal insets. Empty status pills
  /// reserve room for the real-level meter or three work-in-progress dots.
  func measure(text: String, maxWidth: CGFloat = 300) -> CGSize {
    let text = bounded(text)
    let width = maxWidth.isFinite ? min(420, max(32, maxWidth)) : 300
    let key = MeasurementKey(text: text, maxWidth: width)
    if measurementKey == key { return measuredSize }
    let size: CGSize
    if text.isEmpty {
      size = CGSize(width: min(width, 52), height: 29)
    } else {
      let measured = attributed(text).boundingRect(
        with: CGSize(width: max(1, width - 20), height: 10_000),
        options: [.usesLineFragmentOrigin, .usesFontLeading])
      size = CGSize(
        width: min(width, max(32, ceil(measured.width) + 20)),
        height: max(29, min(lineHeight * 4, ceil(measured.height)) + 12))
    }
    measurementKey = key
    measuredSize = size
    return size
  }

  /// All geometry is view-local and flipped. `bodyPoint` is the center of an
  /// 18×22 triangle, pointing right at zero radians. The host owns positioning.
  func update(
    phase: NotchActivityPhase, text: String, level: Double, bodyPoint: CGPoint,
    bubbleFrame: CGRect, rotation: CGFloat, reduceMotion: Bool
  ) {
    let phaseChanged = self.phase != phase || self.reduceMotion != reduceMotion
    self.phase = phase
    self.reduceMotion = reduceMotion
    if phaseChanged { stopAnimations() }
    let responseActive = phase == .thinking || phase == .speaking
    // The coordinator may retain a completed caption briefly after speech.
    let caption = responseActive || phase == .idle ? bounded(text) : ""
    let validBody = bodyPoint.x.isFinite && bodyPoint.y.isFinite
    let validBubble =
      bubbleFrame.origin.x.isFinite && bubbleFrame.origin.y.isFinite
      && bubbleFrame.width.isFinite && bubbleFrame.height.isFinite
      && bubbleFrame.width > 0 && bubbleFrame.height > 0
    let meter = phase == .listening
    let showDots = responseActive && caption.isEmpty
    let showBubble = validBody && validBubble && (meter || showDots || !caption.isEmpty)
    let geometry = validBubble ? bubbleFrame : .zero
    withoutImplicitAnimations {
      bodyLayer.isHidden = !validBody
      if validBody { bodyLayer.position = bodyPoint }
      bodyLayer.setAffineTransform(
        CGAffineTransform(rotationAngle: rotation.isFinite ? rotation : 0))
      bodyLayer.shadowOpacity = phase == .idle || phase == .preparing ? 0 : 0.28
      bubbleLayer.isHidden = !showBubble
      textLayer.isHidden = !showBubble || caption.isEmpty
      if visibleText != caption {
        textLayer.string = caption.isEmpty ? nil : attributed(caption)
        textLayer.contents = nil
        textLayer.setNeedsDisplay()
        visibleText = caption
      }
      if validBubble {
        bubbleLayer.frame = geometry
        if bubbleSize != geometry.size {
          bubbleSize = geometry.size
          bubbleLayer.cornerRadius = min(13, geometry.height / 2)
          bubbleLayer.shadowPath = CGPath(
            roundedRect: CGRect(origin: .zero, size: geometry.size),
            cornerWidth: bubbleLayer.cornerRadius, cornerHeight: bubbleLayer.cornerRadius,
            transform: nil)
          textLayer.frame = CGRect(
            x: 10, y: 6, width: max(0, geometry.width - 20),
            height: min(lineHeight * 4, max(0, geometry.height - 12)))
        }
      }
      let inputLevel = level.isFinite ? min(1, max(0, level)) : 0
      let weights = [0.45, 0.75, 1.0, 0.75, 0.45]
      let meterWidth: CGFloat = 26.5
      let start = max(0, (geometry.width - meterWidth) / 2)
      for (index, bar) in bars.enumerated() {
        bar.isHidden = !showBubble || !meter
        let height = 2 + 12 * inputLevel * weights[index]
        bar.frame = CGRect(
          x: start + CGFloat(index) * 6, y: (geometry.height - height) / 2,
          width: 2.5, height: height)
      }
      for (index, dot) in dots.enumerated() {
        dot.isHidden = !showBubble || !showDots
        dot.opacity = 0.76
        dot.frame = CGRect(
          x: max(0, (geometry.width - 23) / 2) + CGFloat(index) * 9,
          y: (geometry.height - 4) / 2, width: 4, height: 4)
      }
    }
    synchronizeAnimations()
  }

  /// Removes old content synchronously. The owner's opacity/exposure policy is
  /// unchanged; an idle visible view contains only the original red triangle.
  func reset() {
    stopAnimations()
    phase = .idle
    visibleText = ""
    withoutImplicitAnimations {
      bodyLayer.isHidden = false
      bodyLayer.shadowOpacity = 0
      bubbleLayer.isHidden = true
      textLayer.isHidden = true
      textLayer.string = nil
      textLayer.contents = nil
      for bar in bars { bar.isHidden = true }
      for dot in dots { dot.isHidden = true }
    }
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
    bodyLayer.name = "cursor.body"
    bodyLayer.bounds = CGRect(x: 0, y: 0, width: 18, height: 22)
    let triangle = CGMutablePath()
    triangle.move(to: CGPoint(x: 1.5, y: 1.5))
    triangle.addLine(to: CGPoint(x: 16.5, y: 11))
    triangle.addLine(to: CGPoint(x: 1.5, y: 20.5))
    triangle.closeSubpath()
    bodyLayer.path = triangle
    bodyLayer.fillColor = red.cgColor
    bodyLayer.strokeColor = red.cgColor
    bodyLayer.lineWidth = 1.5
    bodyLayer.lineJoin = .round
    bodyLayer.shadowColor = red.cgColor
    bodyLayer.shadowRadius = 8
    bodyLayer.shadowOffset = .zero
    bodyLayer.shadowPath = triangle
    layer.addSublayer(bodyLayer)

    bubbleLayer.name = "cursor.reply"
    bubbleLayer.anchorPoint = .zero
    bubbleLayer.backgroundColor = red.withAlphaComponent(0.97).cgColor
    bubbleLayer.shadowColor = red.cgColor
    bubbleLayer.shadowOpacity = 0.22
    bubbleLayer.shadowRadius = 8
    bubbleLayer.shadowOffset = CGSize(width: 0, height: 2)
    layer.addSublayer(bubbleLayer)
    textLayer.name = "cursor.reply.text"
    textLayer.anchorPoint = .zero
    textLayer.isWrapped = true
    textLayer.masksToBounds = true
    textLayer.truncationMode = .end
    textLayer.alignmentMode = .left
    bubbleLayer.addSublayer(textLayer)
    for (index, bar) in bars.enumerated() {
      bar.name = "cursor.listening.\(index)"
      bar.backgroundColor = NSColor.white.cgColor
      bar.cornerRadius = 1.25
      bubbleLayer.addSublayer(bar)
    }
    for (index, dot) in dots.enumerated() {
      dot.name = "cursor.thinking.\(index)"
      dot.backgroundColor = NSColor.white.cgColor
      dot.cornerRadius = 2
      bubbleLayer.addSublayer(dot)
    }
    // The shared Chat retains the complete, selectable, accessible answer.
    // Do not announce a new accessibility value for each revealed letter.
    setAccessibilityElement(false)
    updateScale()
    reset()
  }

  private func updateScale() {
    let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
    bodyLayer.contentsScale = scale
    textLayer.contentsScale = scale
  }

  private func synchronizeAnimations() {
    let workPhase = phase == .thinking || phase == .speaking
    guard workPhase, !bodyLayer.isHidden, !reduceMotion, !isHiddenOrHasHiddenAncestor,
      let window, window.isVisible, window.occlusionState.contains(.visible)
    else {
      stopAnimations()
      return
    }
    if animatedPhase != phase {
      animatedPhase = phase
      let glow = CABasicAnimation(keyPath: "shadowOpacity")
      glow.fromValue = 0.18
      glow.toValue = 0.35
      glow.duration = 1.25
      glow.autoreverses = true
      glow.repeatCount = .infinity
      glow.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
      bodyLayer.add(glow, forKey: "cursorGlow")
    }
    let now = CACurrentMediaTime()
    for (index, dot) in dots.enumerated() {
      if dot.isHidden {
        dot.removeAllAnimations()
        continue
      }
      guard dot.animation(forKey: "cursorThinking") == nil else { continue }
      let pulse = CAKeyframeAnimation(keyPath: "opacity")
      pulse.values = [0.4, 1, 0.4]
      pulse.keyTimes = [0, 0.4, 1]
      pulse.beginTime = now + Double(index) * 0.16
      pulse.duration = 1.15
      pulse.repeatCount = .infinity
      dot.add(pulse, forKey: "cursorThinking")
    }
  }

  private func stopAnimations() {
    animatedPhase = nil
    bodyLayer.removeAllAnimations()
    bubbleLayer.removeAllAnimations()
    textLayer.removeAllAnimations()
    for bar in bars { bar.removeAllAnimations() }
    for dot in dots { dot.removeAllAnimations() }
  }

  private func attributed(_ text: String) -> NSAttributedString {
    let paragraph = NSMutableParagraphStyle()
    paragraph.lineBreakMode = .byWordWrapping
    paragraph.minimumLineHeight = lineHeight
    paragraph.maximumLineHeight = lineHeight
    return NSAttributedString(
      string: text,
      attributes: [.font: captionFont, .foregroundColor: NSColor.white, .paragraphStyle: paragraph])
  }

  private func bounded(_ text: String) -> String { String(text.prefix(220)) }

  private func withoutImplicitAnimations(_ change: () -> Void) {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    change()
    CATransaction.commit()
  }

  private struct MeasurementKey: Equatable {
    let text: String
    let maxWidth: CGFloat
  }
}
