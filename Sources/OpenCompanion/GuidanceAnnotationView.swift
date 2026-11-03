import AppKit
import QuartzCore

/// Display-local, top-left coordinates. Layout and outline timing are authored
/// choices; the label interval approximates the observed reference sequence.
struct GuidanceAnnotationLayout: Sendable {
  static let glyphInterval: TimeInterval = 0.06
  static let labelFadeDuration: TimeInterval = 0.16
  let target: CGRect
  let label: CGRect

  static func labelText(target: ProviderTarget, showInstruction: Bool = true) -> String {
    boundedLabel(target.label ?? (showInstruction ? target.instruction : ""))
  }

  static func boundedLabel(_ text: String) -> String {
    var result = ""
    var count = 0
    var bytes = 0
    for character in text {
      let part = String(character)
      guard count < 80, bytes + part.utf8.count <= 4096 else { break }
      result.append(character)
      count += 1
      bytes += part.utf8.count
    }
    return result
  }

  /// Capsule bounds in global AppKit coordinates, using exactly the native
  /// annotation's font, text cap, clipping and edge placement.
  @MainActor static func labelFrame(
    target: ProviderTarget, display: CGRect, showInstruction: Bool = true
  ) -> CGRect {
    guard display.minX.isFinite, display.minY.isFinite,
      display.width.isFinite, display.height.isFinite,
      display.width > 0, display.height > 0
    else { return .zero }
    let layout = make(
      target: CGRect(
        x: target.x * display.width, y: target.y * display.height,
        width: target.width * display.width, height: target.height * display.height),
      labelSize: labelSize(text: labelText(target: target, showInstruction: showInstruction)),
      canvas: CGRect(origin: .zero, size: display.size))
    guard !layout.label.isEmpty else { return .zero }
    return CGRect(
      x: display.minX + layout.label.minX, y: display.maxY - layout.label.maxY,
      width: layout.label.width, height: layout.label.height)
  }

  @MainActor static func labelSize(text: String) -> CGSize {
    let text = boundedLabel(text)
    guard !text.isEmpty else { return .zero }
    let measured = NSAttributedString(
      string: text, attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .semibold)]
    ).size()
    return CGSize(width: ceil(measured.width) + 20, height: ceil(measured.height) + 8)
  }

  /// Cumulative widths of whole shaped prefixes, starting at zero. The last
  /// width can be clipped to the capsule's text viewport by the caller.
  @MainActor static func labelPrefixWidths(text: String) -> [CGFloat] {
    let attributes: [NSAttributedString.Key: Any] = [
      .font: NSFont.systemFont(ofSize: 13, weight: .semibold)
    ]
    var widths: [CGFloat] = [0]
    var prefix = ""
    for character in boundedLabel(text) {
      prefix.append(character)
      let width = NSAttributedString(string: prefix, attributes: attributes).size().width
      widths.append(max(widths.last ?? 0, ceil(width) + 1))
    }
    return widths
  }

  static func make(target: CGRect, labelSize: CGSize, canvas: CGRect) -> Self {
    guard canvas.minX.isFinite, canvas.minY.isFinite,
      canvas.width.isFinite, canvas.height.isFinite, canvas.width > 0, canvas.height > 0,
      target.minX.isFinite, target.minY.isFinite, target.width.isFinite, target.height.isFinite,
      target.width > 0, target.height > 0
    else { return Self(target: .zero, label: .zero) }
    let clipped = target.intersection(canvas)
    guard !clipped.isNull, !clipped.isEmpty else { return Self(target: .zero, label: .zero) }
    guard labelSize.width.isFinite, labelSize.height.isFinite,
      labelSize.width > 0, labelSize.height > 0
    else { return Self(target: clipped, label: .zero) }
    let margin = min(6, min(canvas.width, canvas.height) / 2)
    let safe = canvas.insetBy(dx: margin, dy: margin)
    let width = min(320, labelSize.width, safe.width)
    let height = min(labelSize.height, safe.height)
    guard width > 0, height > 0 else { return Self(target: clipped, label: .zero) }
    let x = min(max(clipped.minX, safe.minX), safe.maxX - width)
    let above = clipped.minY - height - 5
    let below = clipped.maxY + 5
    let preferredY = above >= safe.minY ? above : below
    let y = min(max(preferredY, safe.minY), safe.maxY - height)
    return Self(target: clipped, label: CGRect(x: x, y: y, width: width, height: height))
  }
}

/// Retained, noninteractive guidance mark. Creation does the bounded text/path
/// work; Core Animation owns the finite entrance animations while it is shown.
@MainActor final class GuidanceAnnotationView: NSView {
  enum Shape: String, Sendable { case roundedRectangle, ellipse }

  private let fillLayer = CAShapeLayer()
  private let glowLayer = CAShapeLayer()
  private let outlineLayer = CAShapeLayer()
  private let labelLayer = CAGradientLayer()
  private let textLayer = CATextLayer()
  private let textMask = CALayer()
  private var revealWidths: [CGFloat] = []
  private let reduceMotion: Bool

  override var isFlipped: Bool { true }

  init(frame: CGRect, target: CGRect, shape: Shape, text: String, reduceMotion: Bool) {
    self.reduceMotion = reduceMotion
    super.init(frame: frame)
    configure(target: target, shape: shape, text: GuidanceAnnotationLayout.boundedLabel(text))
  }

  required init?(coder: NSCoder) { nil }
  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    textLayer.contentsScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
  }

  override func viewDidChangeBackingProperties() {
    super.viewDidChangeBackingProperties()
    textLayer.contentsScale = window?.backingScaleFactor ?? 2
  }

  func animateAppearance(introDelay: TimeInterval = 0) {
    guard !reduceMotion else { return }
    let delay = introDelay.isFinite ? min(2, max(0, introDelay)) : 0
    let start = CACurrentMediaTime()
    let draw = CABasicAnimation(keyPath: "strokeEnd")
    draw.fromValue = 0
    draw.toValue = 1
    draw.duration = 0.35
    draw.beginTime = outlineLayer.convertTime(start, from: nil) + delay
    draw.fillMode = .backwards
    draw.timingFunction = CAMediaTimingFunction(name: .easeOut)
    outlineLayer.add(draw, forKey: "guidance.draw")
    glowLayer.add(draw, forKey: "guidance.draw")
    let fillFade = CABasicAnimation(keyPath: "opacity")
    fillFade.fromValue = 0
    fillFade.toValue = 1
    fillFade.duration = 0.16
    fillFade.beginTime = fillLayer.convertTime(start, from: nil) + delay
    fillFade.fillMode = .backwards
    fillLayer.add(fillFade, forKey: "guidance.fillFade")
    guard !labelLayer.isHidden else { return }
    let fade = CABasicAnimation(keyPath: "opacity")
    fade.fromValue = 0
    fade.toValue = 1
    fade.duration = GuidanceAnnotationLayout.labelFadeDuration
    fade.beginTime = labelLayer.convertTime(start, from: nil) + delay
    fade.fillMode = .backwards
    labelLayer.add(fade, forKey: "guidance.labelFade")
    guard revealWidths.count > 1 else { return }
    // A single native animation uses Character boundaries, including joined
    // emoji/combining marks. Chat's word-by-word clock is deliberately separate.
    let reveal = CAKeyframeAnimation(keyPath: "bounds.size.width")
    reveal.values = revealWidths.map { NSNumber(value: Double($0)) }
    reveal.keyTimes = revealWidths.indices.map {
      NSNumber(value: Double($0) / Double(revealWidths.count - 1))
    }
    reveal.calculationMode = .discrete
    reveal.duration = GuidanceAnnotationLayout.glyphInterval * Double(revealWidths.count - 1)
    reveal.beginTime =
      textMask.convertTime(start, from: nil)
      + delay + GuidanceAnnotationLayout.labelFadeDuration
    reveal.fillMode = .backwards
    textMask.add(reveal, forKey: "guidance.labelReveal")
  }

  private func configure(target: CGRect, shape: Shape, text: String) {
    wantsLayer = true
    guard let layer else { return }
    layer.isGeometryFlipped = true
    let red = NSColor(srgbRed: 0.98, green: 0.23, blue: 0.28, alpha: 1)
    let font = NSFont.systemFont(ofSize: 13, weight: .semibold)
    let attributes: [NSAttributedString.Key: Any] = [
      .font: font, .foregroundColor: NSColor(srgbRed: 0.23, green: 0.10, blue: 0.12, alpha: 1),
    ]
    let attributed = NSAttributedString(string: text, attributes: attributes)
    let measured = attributed.size()
    let layout = GuidanceAnnotationLayout.make(
      target: target,
      labelSize: GuidanceAnnotationLayout.labelSize(text: text),
      canvas: bounds)
    let path: CGPath
    if shape == .ellipse {
      path = Self.handDrawnEllipse(in: layout.target)
    } else {
      let radius = min(8, layout.target.width / 2, layout.target.height / 2)
      path = CGPath(
        roundedRect: layout.target, cornerWidth: radius, cornerHeight: radius, transform: nil)
    }
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    for item in [fillLayer, glowLayer, outlineLayer] {
      item.frame = bounds
      item.path = path
      item.strokeEnd = 1
      item.lineCap = .round
      item.lineJoin = .round
      layer.addSublayer(item)
    }
    fillLayer.name = "guidance.fill"
    fillLayer.fillColor = red.withAlphaComponent(shape == .ellipse ? 0.025 : 0.045).cgColor
    fillLayer.strokeColor = nil
    glowLayer.name = "guidance.glow"
    glowLayer.fillColor = nil
    glowLayer.strokeColor = red.withAlphaComponent(0.18).cgColor
    glowLayer.lineWidth = 5
    glowLayer.shadowColor = red.cgColor
    glowLayer.shadowOpacity = 0.42
    glowLayer.shadowRadius = 5
    glowLayer.shadowOffset = .zero
    outlineLayer.name = "guidance.outline"
    outlineLayer.fillColor = nil
    outlineLayer.strokeColor = red.withAlphaComponent(0.91).cgColor
    outlineLayer.lineWidth = shape == .ellipse ? 2.5 : 2
    if shape == .roundedRectangle {
      outlineLayer.lineDashPattern = [6, 4]
      glowLayer.lineDashPattern = [6, 4]
    }
    labelLayer.name = "guidance.label"
    labelLayer.frame = layout.label
    labelLayer.isHidden = text.isEmpty || layout.label.isEmpty
    labelLayer.cornerRadius = layout.label.height / 2
    labelLayer.colors = [
      NSColor(srgbRed: 1, green: 0.91, blue: 0.93, alpha: 0.99).cgColor,
      NSColor(srgbRed: 1, green: 0.79, blue: 0.82, alpha: 0.99).cgColor,
    ]
    labelLayer.startPoint = CGPoint(x: 0.5, y: 0)
    labelLayer.endPoint = CGPoint(x: 0.5, y: 1)
    labelLayer.borderColor = NSColor.white.withAlphaComponent(0.32).cgColor
    labelLayer.borderWidth = 0.5
    labelLayer.shadowColor = red.cgColor
    labelLayer.shadowOpacity = 0.22
    labelLayer.shadowRadius = 7
    labelLayer.shadowOffset = CGSize(width: 0, height: 1)
    labelLayer.shadowPath = CGPath(
      roundedRect: labelLayer.bounds, cornerWidth: layout.label.height / 2,
      cornerHeight: layout.label.height / 2, transform: nil)
    layer.addSublayer(labelLayer)
    textLayer.name = "guidance.label.text"
    textLayer.frame = CGRect(
      x: 10, y: max(0, (layout.label.height - ceil(measured.height)) / 2),
      width: max(0, layout.label.width - 20), height: ceil(measured.height) + 1)
    textLayer.string = attributed
    textLayer.fontSize = font.pointSize
    textLayer.alignmentMode = .left
    textLayer.truncationMode = .end
    textLayer.isWrapped = false
    textLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
    labelLayer.addSublayer(textLayer)
    textMask.backgroundColor = NSColor.white.cgColor
    textMask.anchorPoint = .zero
    textMask.position = .zero
    textMask.bounds = textLayer.bounds
    textLayer.mask = textMask
    revealWidths = GuidanceAnnotationLayout.labelPrefixWidths(text: text).map {
      min(textLayer.bounds.width, $0)
    }
    // Final model geometry always exposes all text, including a native ellipsis
    // on unusually long labels. Only the presentation mask animates.
    if !text.isEmpty { revealWidths[revealWidths.count - 1] = textLayer.bounds.width }
    setAccessibilityElement(!text.isEmpty)
    setAccessibilityRole(.staticText)
    setAccessibilityLabel(text.isEmpty ? nil : text)
    CATransaction.commit()
  }

  private static func handDrawnEllipse(in rect: CGRect) -> CGPath {
    guard !rect.isEmpty else { return CGPath(rect: .zero, transform: nil) }
    let center = CGPoint(x: rect.midX, y: rect.midY)
    let rx = max(0.25, rect.width / 2 - 2)
    let ry = max(0.25, rect.height / 2 - 2)
    let points = (0..<32).map { index -> CGPoint in
      let angle = CGFloat(index) * 2 * .pi / 32 - .pi * 0.72
      let wobble = min(0.7, rx * 0.06, ry * 0.06) * sin(angle * 3 + 0.4)
      return CGPoint(
        x: center.x + (rx + wobble) * cos(angle),
        y: center.y + (ry + wobble) * sin(angle))
    }
    let path = CGMutablePath()
    path.move(to: points[0])
    for index in points.indices {
      let p0 = points[(index + points.count - 1) % points.count]
      let p1 = points[index]
      let p2 = points[(index + 1) % points.count]
      let p3 = points[(index + 2) % points.count]
      path.addCurve(
        to: p2,
        control1: CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6),
        control2: CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6))
    }
    path.closeSubpath()
    return path
  }
}
