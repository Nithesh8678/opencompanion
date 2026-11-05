import AppKit
import Combine
import CoreText
import QuartzCore

struct CursorCaptionWord: Equatable, Sendable {
  static let fadeDuration: TimeInterval = 0.14
  let serial: UInt64
  let suffix: String
}

/// Passive native presentation only. The coordinator supplies the latest pose
/// and visible text prefix; this view never samples input or owns a reveal clock.
@MainActor final class CursorCompanionView: NSView {
  private let bodyLayer = CAShapeLayer()
  private let bubbleLayer = CAGradientLayer()
  private let bubbleView = CursorCaptionContainer()
  private let captionView = CursorCaptionView()
  private let wordView = CursorCaptionView()
  private var lastWordSerial: UInt64?
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
  private var animatedPhase: NotchActivityPhase?
  private var measurementKey: MeasurementKey?
  private var measuredSize = CGSize.zero
  private var measuredCaptionLayout: CursorCaptionLayout?
  private var captionDismissing = false
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

  /// Current painted caption bounds in this flipped view, for own-window QA.
  /// Hidden status geometry must not count as an attached visible caption.
  var visibleCaptionFrame: CGRect? {
    guard !bubbleView.isHidden, !bubbleLayer.isHidden, bubbleLayer.opacity > 0 else { return nil }
    return bubbleView.frame
  }

  /// Submitted model-layer geometry in this flipped view. This includes the
  /// body's actual position, anchor and rotation; it is not a scanout receipt.
  var submittedBodyTip: CGPoint? {
    guard let layer = visibleBodyOwner else { return nil }
    let point = layer.convert(CursorCompanionGlyph.tip, from: bodyLayer)
    return point.x.isFinite && point.y.isFinite ? point : nil
  }

  var submittedBodyFrame: CGRect? {
    guard let layer = visibleBodyOwner else { return nil }
    let frame = layer.convert(bodyLayer.bounds, from: bodyLayer)
    guard frame.origin.x.isFinite, frame.origin.y.isFinite,
      frame.width.isFinite, frame.height.isFinite, frame.width > 0, frame.height > 0
    else { return nil }
    return frame
  }

  private var visibleBodyOwner: CALayer? {
    guard !isHiddenOrHasHiddenAncestor, alphaValue > 0,
      let layer, !layer.isHidden, layer.opacity > 0,
      bodyLayer.superlayer === layer, !bodyLayer.isHidden, bodyLayer.opacity > 0
    else { return nil }
    return layer
  }

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
      measuredCaptionLayout = nil
    } else {
      let measured = CursorCaptionLayout.makeTrailingWindow(
        attributed(text), width: max(1, width - 20), minimumLineHeight: lineHeight)
      measuredCaptionLayout = measured
      size = CGSize(
        width: min(width, max(32, ceil(measured.size.width) + 20)),
        height: max(29, ceil(measured.size.height) + 12))
    }
    measurementKey = key
    measuredSize = size
    return size
  }

  /// All geometry is view-local and flipped. `bodyPoint` is the center of an
  /// 18×22 triangle, pointing right at zero radians. The host owns positioning.
  func update(
    phase: NotchActivityPhase, text: String, level: Double, bodyPoint: CGPoint,
    bubbleFrame: CGRect, rotation: CGFloat, reduceMotion: Bool, word: CursorCaptionWord? = nil
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
    let meter = false
    let showDots = false
    let showBubble = validBody && validBubble && !caption.isEmpty
    let animatedWord = !reduceMotion && !caption.isEmpty ? word : nil
    let wordChanged = animatedWord?.serial != lastWordSerial
    let geometry = validBubble ? bubbleFrame : .zero
    withoutImplicitAnimations {
      bodyLayer.isHidden = !validBody
      if validBody { bodyLayer.position = bodyPoint }
      bodyLayer.setAffineTransform(
        CGAffineTransform(rotationAngle: rotation.isFinite ? rotation : 0))
      bodyLayer.shadowOpacity = phase == .idle || phase == .preparing ? 0.20 : 0.45
      bubbleView.isHidden = !showBubble
      bubbleLayer.isHidden = !showBubble
      bubbleLayer.opacity = captionDismissing ? 0 : 1
      captionView.isHidden = !showBubble || caption.isEmpty
      wordView.isHidden = !showBubble || caption.isEmpty || animatedWord == nil
      if validBubble {
        bubbleView.frame = geometry
        if bubbleSize != geometry.size {
          bubbleSize = geometry.size
          bubbleLayer.cornerRadius = min(13, geometry.height / 2)
          bubbleLayer.shadowPath = CGPath(
            roundedRect: CGRect(origin: .zero, size: geometry.size),
            cornerWidth: bubbleLayer.cornerRadius, cornerHeight: bubbleLayer.cornerRadius,
            transform: nil)
          captionView.frame = CGRect(
            x: 7, y: 3, width: max(0, geometry.width - 14),
            height: max(0, geometry.height - 6))
          wordView.frame = captionView.frame
        }
      }
      let cachedLayout =
        measurementKey?.text == caption
          && (measuredCaptionLayout?.size.width ?? .infinity) <= captionView.bounds.width - 6
        ? measuredCaptionLayout : nil
      captionView.update(
        attributed(caption), minimumLineHeight: lineHeight, layout: cachedLayout, word: animatedWord
      )
      wordView.update(
        attributed(caption), minimumLineHeight: lineHeight, layout: cachedLayout,
        word: animatedWord, onlyWord: true)
      wordView.layer?.opacity = 1
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
    if wordChanged {
      wordView.layer?.removeAnimation(forKey: "cursor.wordReveal")
      if animatedWord != nil {
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = CursorCaptionWord.fadeDuration
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        wordView.layer?.add(fade, forKey: "cursor.wordReveal")
      }
      lastWordSerial = animatedWord?.serial
    }
    synchronizeAnimations()
  }

  /// Removes old content synchronously. The owner's opacity/exposure policy is
  /// unchanged; an idle visible view contains only the original red triangle.
  func reset() {
    cancelCaptionDismissal()
    stopAnimations()
    phase = .idle
    lastWordSerial = nil
    wordView.layer?.removeAllAnimations()
    withoutImplicitAnimations {
      bodyLayer.isHidden = false
      bodyLayer.shadowOpacity = 0.20
      bubbleView.isHidden = true
      bubbleLayer.isHidden = true
      captionView.isHidden = true
      wordView.isHidden = true
      captionView.update(attributed(""), minimumLineHeight: lineHeight)
      for bar in bars { bar.isHidden = true }
      for dot in dots { dot.isHidden = true }
    }
  }

  func dismissCaption(animated: Bool) {
    captionDismissing = true
    let opacity = bubbleLayer.presentation()?.opacity ?? bubbleLayer.opacity
    withoutImplicitAnimations { bubbleLayer.opacity = 0 }
    if animated {
      let fade = CABasicAnimation(keyPath: "opacity")
      fade.fromValue = opacity
      fade.toValue = 0
      fade.duration = 0.18
      fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
      bubbleLayer.add(fade, forKey: "cursor.captionExit")
    }
  }

  func cancelCaptionDismissal() {
    captionDismissing = false
    bubbleLayer.removeAnimation(forKey: "cursor.captionExit")
    withoutImplicitAnimations { bubbleLayer.opacity = 1 }
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
    bodyLayer.bounds = CGRect(origin: .zero, size: CursorCompanionGlyph.size)
    let triangle = CGMutablePath()
    triangle.move(to: CGPoint(x: 1.5, y: 1.5))
    triangle.addLine(to: CursorCompanionGlyph.tip)
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
    bubbleLayer.colors = [
      NSColor(srgbRed: 1, green: 0.98, blue: 0.98, alpha: 1).cgColor,
      NSColor(srgbRed: 1, green: 0.68, blue: 0.68, alpha: 1).cgColor,
    ]
    bubbleLayer.startPoint = CGPoint(x: 0.5, y: 0)
    bubbleLayer.endPoint = CGPoint(x: 0.5, y: 1)
    bubbleLayer.shadowColor = red.cgColor
    bubbleLayer.shadowOpacity = 0.32
    bubbleLayer.shadowRadius = 8
    bubbleLayer.shadowOffset = CGSize(width: 0, height: 2)
    // Keep the native caption inside the same retained bubble layer, so the
    // owner's existing opacity fade applies to text and indicators together.
    bubbleView.wantsLayer = true
    bubbleView.layer = bubbleLayer
    bubbleLayer.masksToBounds = false
    addSubview(bubbleView)
    captionView.wantsLayer = true
    captionView.layer?.name = "cursor.reply.text"
    bubbleView.addSubview(captionView)
    wordView.wantsLayer = true
    wordView.layer?.name = "cursor.reply.word"
    bubbleView.addSubview(wordView)
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
    captionView.layer?.contentsScale = scale
    wordView.layer?.contentsScale = scale
    captionView.needsDisplay = true
    wordView.needsDisplay = true
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
      glow.fromValue = 0.36
      glow.toValue = 0.52
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
    captionView.layer?.removeAllAnimations()
    for bar in bars { bar.removeAllAnimations() }
    for dot in dots { dot.removeAllAnimations() }
  }

  private func attributed(_ text: String) -> NSAttributedString {
    let ink = NSColor(srgbRed: 0.14, green: 0.06, blue: 0.07, alpha: 1)
    let paragraph = NSMutableParagraphStyle()
    paragraph.lineBreakMode = .byWordWrapping
    return NSAttributedString(
      string: text,
      attributes: [
        .font: captionFont, .foregroundColor: ink, .paragraphStyle: paragraph,
        NSAttributedString.Key(kCTForegroundColorAttributeName as String): ink.cgColor,
      ])
  }

  private func bounded(_ text: String) -> String {
    let tail = text.suffix(220)
    return tail.startIndex == text.startIndex ? String(tail) : "…" + text.suffix(219)
  }

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

/// Bubble coordinates follow the flipped cursor host. The caption itself uses
/// AppKit's ordinary, upward text coordinates for CoreText drawing.
@MainActor private final class CursorCaptionContainer: NSView {
  override var isFlipped: Bool { true }
  override var wantsDefaultClipping: Bool { false }
  override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

@MainActor private final class CursorCaptionView: NSView {
  private let inkInset: CGFloat = 3
  private var textWidth: CGFloat { max(1, bounds.width - inkInset * 2) }
  private var text = ""
  private var layoutWidth: CGFloat = -1
  private var minimumLineHeight: CGFloat = -1
  private var wordSerial: UInt64?
  private var showsOnlyWord = false
  private var captionLayout = CursorCaptionLayout(rows: [], size: .zero, text: "")

  override var isFlipped: Bool { false }
  override var isOpaque: Bool { false }
  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  func update(
    _ attributed: NSAttributedString, minimumLineHeight: CGFloat,
    layout: CursorCaptionLayout? = nil, word: CursorCaptionWord? = nil, onlyWord: Bool = false
  ) {
    guard
      text != attributed.string || layoutWidth != bounds.width
        || self.minimumLineHeight != minimumLineHeight || wordSerial != word?.serial
        || showsOnlyWord != onlyWord
    else { return }
    text = attributed.string
    layoutWidth = bounds.width
    self.minimumLineHeight = minimumLineHeight
    wordSerial = word?.serial
    showsOnlyWord = onlyWord
    captionLayout =
      layout
      ?? CursorCaptionLayout.makeTrailingWindow(
        attributed, width: textWidth, minimumLineHeight: minimumLineHeight)
    if let word, !word.suffix.isEmpty, captionLayout.text.hasSuffix(word.suffix) {
      let value = captionLayout.text
      let masked = NSMutableAttributedString(
        string: value, attributes: attributed.attributes(at: 0, effectiveRange: nil))
      let range = NSRange(
        location: value.utf16.count - word.suffix.utf16.count,
        length: word.suffix.utf16.count)
      if onlyWord {
        setInk(.clear, in: masked, range: NSRange(location: 0, length: masked.length))
        let ink =
          attributed.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor ?? .black
        setInk(ink, in: masked, range: range)
      } else {
        setInk(.clear, in: masked, range: range)
      }
      captionLayout = CursorCaptionLayout.make(
        masked, width: textWidth, minimumLineHeight: minimumLineHeight)
    } else if onlyWord {
      captionLayout = .init(rows: [], size: .zero, text: "")
    }
    needsDisplay = true
  }

  override func draw(_ dirtyRect: NSRect) {
    guard let context = NSGraphicsContext.current?.cgContext else { return }
    context.saveGState()
    context.clip(to: bounds)
    context.textMatrix = .identity
    context.setShouldAntialias(true)
    // A shallow glyph-only glow sits behind crisp text; it never blurs the
    // caption background or reanimates words which have already appeared.
    context.setShadow(
      offset: .zero, blur: 2.5,
      color: NSColor.white.withAlphaComponent(0.65).cgColor)
    for row in captionLayout.rows {
      context.textPosition = CGPoint(x: inkInset, y: bounds.height - inkInset - row.baseline)
      CTLineDraw(row.line, context)
    }
    context.restoreGState()
  }

  private func setInk(_ ink: NSColor, in text: NSMutableAttributedString, range: NSRange) {
    text.addAttributes(
      [
        .foregroundColor: ink,
        NSAttributedString.Key(kCTForegroundColorAttributeName as String): ink.cgColor,
      ], range: range)
  }
}

/// Measurement and rendering share these exact lines and baseline positions.
/// Explicit baselines avoid CATextLayer's different paragraph/emoji spacing.
struct CursorCaptionLayout {
  struct Row {
    let line: CTLine
    /// Distance down from the top of the caption, including the glyph ascent.
    let baseline: CGFloat
    let ascent: CGFloat
    let descent: CGFloat
    let height: CGFloat
    let isTruncated: Bool
  }

  let rows: [Row]
  let size: CGSize
  let text: String

  /// Keep the newest complete graphemes visible. The full candidate plus at
  /// most eight binary-search candidates bounds each new prefix to nine plans.
  static func makeTrailingWindow(
    _ attributed: NSAttributedString, width: CGFloat, minimumLineHeight: CGFloat = 17
  ) -> Self {
    guard attributed.length > 0, width.isFinite, width > 0 else {
      return .init(rows: [], size: .zero, text: "")
    }
    let source = attributed.string
    let start =
      source.index(source.endIndex, offsetBy: -220, limitedBy: source.startIndex)
      ?? source.startIndex
    let clipped = start != source.startIndex
    let startOffset = start.utf16Offset(in: source)
    let bounded = attributed.attributedSubstring(
      from: NSRange(location: startOffset, length: attributed.length - startOffset))
    let full = make(bounded, width: width, minimumLineHeight: minimumLineHeight)
    if !clipped && full.rows.allSatisfy({ !$0.isTruncated }) { return full }

    let boundaries =
      bounded.string.indices.map { $0.utf16Offset(in: bounded.string) }
      + [bounded.length]
    var lower = 0
    var upper = boundaries.count - (clipped ? 1 : 2)
    var best: Self?
    while lower <= upper {
      let count = lower + (upper - lower) / 2
      let offset = boundaries[boundaries.count - 1 - count]
      let attributes = bounded.attributes(at: min(offset, bounded.length - 1), effectiveRange: nil)
      let candidate = NSMutableAttributedString(string: "…", attributes: attributes)
      candidate.append(
        bounded.attributedSubstring(
          from: NSRange(location: offset, length: bounded.length - offset)))
      let plan = make(candidate, width: width, minimumLineHeight: minimumLineHeight)
      if plan.rows.allSatisfy({ !$0.isTruncated }) {
        best = plan
        lower = count + 1
      } else {
        upper = count - 1
      }
    }
    return best ?? full
  }

  static func make(
    _ attributed: NSAttributedString, width: CGFloat, minimumLineHeight: CGFloat = 17
  ) -> Self {
    guard attributed.length > 0, width.isFinite, width > 0 else {
      return .init(rows: [], size: .zero, text: attributed.string)
    }
    let typesetter = CTTypesetterCreateWithAttributedString(attributed)
    let source = attributed.string as NSString
    var offset = 0
    var rows: [Row] = []
    var height: CGFloat = 0
    var measuredWidth: CGFloat = 0
    while offset < attributed.length && rows.count < 4 {
      let suggested = CTTypesetterSuggestLineBreak(typesetter, offset, Double(width))
      let count = min(
        attributed.length - offset,
        suggested > 0 ? suggested : source.rangeOfComposedCharacterSequence(at: offset).length)
      let truncated = rows.count == 3 && offset + count < attributed.length
      let line: CTLine
      if truncated {
        // Include an explicit ellipsis even when an early hard newline leaves
        // room on row four. CTLine truncation alone would omit it in that case.
        var visibleCount = count
        while visibleCount > 0,
          isLineEnding(source.character(at: offset + visibleCount - 1))
        {
          visibleCount -= 1
        }
        let candidate = NSMutableAttributedString(
          attributedString: attributed.attributedSubstring(
            from: NSRange(location: offset, length: visibleCount)))
        let token = NSAttributedString(
          string: "…", attributes: attributed.attributes(at: offset, effectiveRange: nil))
        candidate.append(token)
        let completeLine = CTLineCreateWithAttributedString(candidate)
        let tokenLine = CTLineCreateWithAttributedString(token)
        line =
          CTLineCreateTruncatedLine(completeLine, Double(width), .end, tokenLine)
          ?? (CTLineGetTypographicBounds(tokenLine, nil, nil, nil) <= Double(width)
            ? tokenLine : CTLineCreateWithAttributedString(NSAttributedString(string: "")))
      } else {
        line = CTTypesetterCreateLine(typesetter, CFRange(location: offset, length: count))
      }
      var ascent: CGFloat = 0
      var descent: CGFloat = 0
      var leading: CGFloat = 0
      let lineWidth = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
      let rowHeight = max(minimumLineHeight, ceil(ascent + descent + max(0, leading)))
      let baseline = height + (rowHeight - ascent - descent) / 2 + ascent
      rows.append(
        .init(
          line: line, baseline: baseline, ascent: ascent, descent: descent,
          height: rowHeight, isTruncated: truncated))
      height += rowHeight
      measuredWidth = max(measuredWidth, lineWidth)
      offset += count
    }
    // Keep the line-breaking width for multiline captions. Shrinking it to a
    // glyph bound and wrapping again could otherwise create an extra row.
    return .init(
      rows: rows,
      size: CGSize(width: rows.count > 1 ? width : min(width, measuredWidth), height: height),
      text: attributed.string)
  }

  private static func isLineEnding(_ value: unichar) -> Bool {
    [10, 11, 12, 13, 0x85, 0x2028, 0x2029].contains(value)
  }
}
