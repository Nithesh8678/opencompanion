import AppKit
import CompanionCore
import CoreText
import SceneKit
import SwiftUI
import simd

extension NSColor {
  convenience init(sceneHex: String) {
    guard sceneHex != "transparent" else {
      self.init(white: 0, alpha: 0)
      return
    }
    let clean = String(sceneHex.dropFirst())
    let value = UInt64(clean, radix: 16) ?? 0x2458A6
    let shift = clean.count == 8 ? 8 : 0
    self.init(
      srgbRed: Double((value >> (16 + shift)) & 255) / 255,
      green: Double((value >> (8 + shift)) & 255) / 255, blue: Double((value >> shift) & 255) / 255,
      alpha: shift == 8 ? Double(value & 255) / 255 : 1)
  }
}

enum CanvasPresentation: Sendable, Equatable {
  case editor
  case passiveOverlay
}

/// Local renderer timing only. Contains no document text, screenshot pixels,
/// foreground application identity, or user-input events.
struct CanvasDisplayClockDiagnostics: Codable, Sendable {
  let linkExists: Bool
  let linkPaused: Bool
  let windowBound: Bool
  let windowVisible: Bool
  let windowOnDisplay: Bool
  let windowOcclusionVisible: Bool
  let hiddenAncestor: Bool
  let reduceMotion: Bool
  let scenePlaying: Bool
  let pendingLabels: Bool
  let callbackCount: Int
  let acceptedCallbackCount: Int
  let labelAdvanceCount: Int
  let renderCount: Int
  let reconcileCount: Int
  let stopCount: Int
  let accumulatedDelta: Double
  let lastCallbackAge: Double?
  let visibleLabelCount: Int
  let nonemptyVisibleLabelCount: Int
}

struct SceneCanvas: NSViewRepresentable {
  var document: SceneDocument
  var time: Double
  var selectedID: String?
  var onSelect: (String?) -> Void
  var onMove: (String, Double, Double) -> Void
  var playing: Bool? = nil
  var speed: Double = 1
  var seekRevision: Int = 0
  var onTimeChange: ((Double) -> Void)? = nil
  var drawing: Bool = false
  var onStroke: (([Point2D]) -> Void)? = nil
  var onBeginEdit: (() -> Void)? = nil
  var presentation: CanvasPresentation = .editor
  func makeNSView(context: Context) -> RetainedCanvasView {
    let view = RetainedCanvasView()
    view.onSelect = onSelect
    view.onMove = onMove
    return view
  }
  func updateNSView(_ view: RetainedCanvasView, context: Context) {
    view.onSelect = onSelect
    view.onMove = onMove
    view.onTimeChange = onTimeChange
    view.onStroke = onStroke
    view.onBeginEdit = onBeginEdit
    view.presentation = presentation
    view.drawing = presentation == .editor && drawing
    view.configureClock(
      documentID: document.id, time: time, playing: playing, speed: speed,
      seekRevision: seekRevision)
    view.render(
      document, time: view.currentTime, selectedID: presentation == .editor ? selectedID : nil)
  }
  static func dismantleNSView(_ view: RetainedCanvasView, coordinator: ()) {
    view.stopDisplayLink()
  }
}
@MainActor final class RetainedCanvasView: NSView {
  override var isFlipped: Bool { true }
  override var acceptsFirstResponder: Bool { presentation == .editor }
  private var nodeLayers: [String: CALayer] = [:]
  private var originals: [String: SceneNode] = [:]
  private var layerKinds: [String: SceneNode.Kind] = [:]
  private var pathKeys: [String: PathKey] = [:]
  private var textKeys: [String: TextKey] = [:]
  private var textSizes: [String: CGSize] = [:]
  private var content = CALayer()
  private let spatialLabels = CALayer()
  private var leaderLayers: [String: CAShapeLayer] = [:]
  private struct LabelLayoutKey: Equatable {
    let documentID: String
    let items: [SpatialLabelLayout.Item]
    let bounds: CGRect
    let objectBounds: CGRect?
    let gap: CGFloat
  }
  private var labelLayoutKey: LabelLayoutKey?
  private var labelLayout = SpatialLabelLayout.Result(frames: [:], overlappingPairs: 0)
  private(set) var unresolvedLabelOverlapCount = 0
  private var document = SceneDocument()
  private var selection: String?
  private var dragStart: CGPoint?
  private var nodeStart: CGPoint?
  private var ratio = 1.0
  private var stage: SCNView?
  private var meshNodes: [String: SCNNode] = [:]
  private var geometryCache: [String: SCNGeometry] = [:]
  private var meshKeys: [String: String] = [:]
  private var spatialGeometryKeys: [String: Geometry3D] = [:]
  private var materialKeys: [String: String] = [:]
  private var spatialPoses: [String: ScenePose3D] = [:]
  private var cameraFitKeys: [CameraFitKey] = []
  private var cameraFitDocumentID: String?
  private var cameraFitSize: CGSize = .zero
  private var hasTypedSpatialContent = false
  private var poses: [ScenePose] = []
  private var dragParentInverse: AffineTransform2D = .identity
  private let ink = CAShapeLayer()
  private var activeStroke: [Point2D] = []
  private var nativeDisplayLink: CADisplayLink?
  private weak var displayClockWindow: NSWindow?
  private var displayCallbackCount = 0
  private var acceptedDisplayCallbackCount = 0
  private var displayLabelAdvanceCount = 0
  private var displayRenderCount = 0
  private var displayReconcileCount = 0
  private var displayStopCount = 0
  private var displayAccumulatedDelta = 0.0
  private var lastObservedDisplayCallback: Double?
  private var labelReveal = SpatialLabelReveal()
  private var labelGeneration: UInt64 = 0
  private var lastDisplayTime: Double?
  private var clock: AnimationClock?
  private var nativePlaying = false
  private var clockDocumentID: String?
  private var lastSeekRevision = -1
  private var windowObservation: NSObjectProtocol?
  private var motionObservation: NSObjectProtocol?
  private(set) var currentTime: Double = 0
  var onTimeChange: ((Double) -> Void)?
  var onStroke: (([Point2D]) -> Void)?
  var onBeginEdit: (() -> Void)?
  var drawing = false {
    didSet {
      stage?.isHidden = drawing
      if !drawing {
        activeStroke.removeAll()
        ink.path = nil
      }
    }
  }
  var presentation: CanvasPresentation = .editor {
    didSet {
      guard presentation != oldValue else { return }
      updateCanvasBackground()
      stage?.allowsCameraControl = presentation == .editor
      if presentation == .passiveOverlay {
        drawing = false
        selection = nil
        dragStart = nil
        nodeStart = nil
        activeStroke.removeAll()
        ink.path = nil
      }
      setAccessibilityLabel(
        presentation == .editor
          ? "Editable lesson canvas. Select a part to edit its text or position."
          : "Visual explanation. Open Notebook to edit.")
      reconcileLabelReveal()
      updateProjectedLabels()
      updateDisplayLink()
    }
  }
  var onSelect: ((String?) -> Void)?
  var onMove: ((String, Double, Double) -> Void)?
  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    layer?.backgroundColor = NSColor.white.cgColor
    layer?.addSublayer(content)
    spatialLabels.zPosition = 100_000
    layer?.addSublayer(spatialLabels)
    ink.strokeColor = NSColor.systemBlue.cgColor
    ink.fillColor = nil
    ink.lineWidth = 3
    ink.lineCap = .round
    ink.lineJoin = .round
    ink.zPosition = 1_000_000
    content.addSublayer(ink)
    setAccessibilityElement(true)
    setAccessibilityRole(.group)
    setAccessibilityLabel("Editable lesson canvas. Select a part to edit its text or position.")
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
  override func hitTest(_ point: NSPoint) -> NSView? {
    guard presentation == .editor else { return nil }
    return super.hitTest(point)
  }
  override func layout() {
    super.layout()
    applyLayout()
  }
  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    if let windowObservation { NotificationCenter.default.removeObserver(windowObservation) }
    windowObservation = nil
    if let motionObservation {
      NSWorkspace.shared.notificationCenter.removeObserver(motionObservation)
    }
    motionObservation = nil
    if let window {
      windowObservation = NotificationCenter.default.addObserver(
        forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
      ) { [weak self] _ in Task { @MainActor in self?.visibilityChanged() } }
      motionObservation = NSWorkspace.shared.notificationCenter.addObserver(
        forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil,
        queue: .main
      ) { [weak self] _ in
        Task { @MainActor in
          guard let self else { return }
          if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            self.layer?.removeAllAnimations()
            for node in self.nodeLayers.values { node.removeAllAnimations() }
            for node in self.meshNodes.values { node.removeAllAnimations() }
          }
          self.visibilityChanged()
        }
      }
    }
    visibilityChanged()
  }
  override func viewWillMove(toWindow newWindow: NSWindow?) {
    if newWindow == nil {
      stopDisplayLink()
      if let windowObservation { NotificationCenter.default.removeObserver(windowObservation) }
      windowObservation = nil
      if let motionObservation {
        NSWorkspace.shared.notificationCenter.removeObserver(motionObservation)
      }
      motionObservation = nil
    }
    super.viewWillMove(toWindow: newWindow)
  }
  override func viewDidHide() {
    super.viewDidHide()
    visibilityChanged()
  }
  override func viewDidUnhide() {
    super.viewDidUnhide()
    visibilityChanged()
  }
  private func visibilityChanged() {
    try? clock?.setPlaying(
      nativePlaying && window?.isVisible == true && !isHiddenOrHasHiddenAncestor
        && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
      at: ProcessInfo.processInfo.systemUptime)
    updateDisplayLink()
  }
  func configureClock(
    documentID: String, time: Double, playing: Bool?, speed: Double, seekRevision: Int
  ) {
    let now = ProcessInfo.processInfo.systemUptime
    let wasPlaying = nativePlaying
    if let playing {
      let clockActive =
        playing && window?.isVisible == true && !isHiddenOrHasHiddenAncestor
        && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
      if clock == nil || clockDocumentID != documentID || lastSeekRevision != seekRevision {
        clock = AnimationClock(
          at: now, phase: max(0, time), speed: min(16, max(0, speed)), isPlaying: clockActive)
      } else {
        try? clock?.setSpeed(min(16, max(0, speed)), at: now)
        try? clock?.setPlaying(clockActive, at: now)
      }
      currentTime = (try? clock?.value(at: now)) ?? max(0, time)
      nativePlaying = playing
      clockDocumentID = documentID
      lastSeekRevision = seekRevision
    } else {
      clock = nil
      nativePlaying = false
      currentTime = max(0, time)
    }
    if wasPlaying && !nativePlaying {
      let time = currentTime
      let seek = lastSeekRevision
      Task { @MainActor [weak self] in
        guard let self, !self.nativePlaying, self.lastSeekRevision == seek else { return }
        self.onTimeChange?(time)
      }
    }
    updateDisplayLink()
  }
  private func updateDisplayLink() {
    let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    if reduceMotion, labelReveal.hasRevealableText {
      advanceSpatialLabels(by: 0, reduceMotion: true)
    }
    guard nativePlaying || labelReveal.hasRevealableText,
      let window, window.isVisible, !isHiddenOrHasHiddenAncestor, !reduceMotion
    else {
      nativeDisplayLink?.isPaused = true
      lastDisplayTime = nil
      return
    }
    if nativeDisplayLink == nil || displayClockWindow !== window {
      nativeDisplayLink?.invalidate()
      // The native window owns this clock. Transparent layer-only content must
      // not depend on AppKit classifying its backing NSView as drawable first.
      let link = window.displayLink(target: self, selector: #selector(displayFrame(_:)))
      link.isPaused = true
      link.add(to: .main, forMode: .common)
      nativeDisplayLink = link
      displayClockWindow = window
    }
    if nativeDisplayLink?.isPaused != false {
      lastDisplayTime = ProcessInfo.processInfo.systemUptime
    }
    nativeDisplayLink?.isPaused = false
  }
  func stopDisplayLink() {
    nativeDisplayLink?.invalidate()
    nativeDisplayLink = nil
    displayClockWindow = nil
    displayStopCount = min(1_000_000, displayStopCount + 1)
    lastDisplayTime = nil
    labelReveal.reset()
    stage?.isPlaying = false
  }
  @objc private func displayFrame(_ sender: CADisplayLink) {
    let now = ProcessInfo.processInfo.systemUptime
    displayCallbackCount = min(1_000_000, displayCallbackCount + 1)
    lastObservedDisplayCallback = now
    guard sender === nativeDisplayLink else { return }
    guard nativePlaying || labelReveal.hasRevealableText,
      !isHiddenOrHasHiddenAncestor, window?.isVisible == true,
      !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    else {
      sender.isPaused = true
      lastDisplayTime = nil
      return
    }
    acceptedDisplayCallbackCount = min(1_000_000, acceptedDisplayCallbackCount + 1)
    let delta = max(0, now - (lastDisplayTime ?? now))
    lastDisplayTime = now
    displayAccumulatedDelta = min(1_000_000, displayAccumulatedDelta + delta)
    let labelChanged = labelReveal.advance(by: delta)
    if labelChanged { displayLabelAdvanceCount = min(1_000_000, displayLabelAdvanceCount + 1) }
    if nativePlaying, let time = try? clock?.value(at: now) {
      currentTime = time
      render(document, time: time, selectedID: selection)
    } else if labelChanged {
      updateProjectedLabels()
    }
    updateDisplayLink()
  }
  private func applyLayout() {
    ratio = max(0.0001, min(bounds.width / document.width, bounds.height / document.height))
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    content.anchorPoint = .zero
    content.position = CGPoint(x: max(0, (bounds.width - document.width * ratio) / 2), y: 0)
    content.bounds = CGRect(x: 0, y: 0, width: document.width, height: document.height)
    content.setAffineTransform(CGAffineTransform(scaleX: ratio, y: ratio))
    spatialLabels.anchorPoint = .zero
    spatialLabels.position = content.position
    spatialLabels.bounds = content.bounds
    spatialLabels.setAffineTransform(CGAffineTransform(scaleX: ratio, y: ratio))
    CATransaction.commit()
    if let stage {
      stage.frame = CGRect(
        x: bounds.width * 0.08, y: bounds.height * 0.15, width: bounds.width * 0.84,
        height: bounds.height * 0.7)
      if hasTypedSpatialContent, cameraFitSize != stage.bounds.size {
        fitCameraToGeometry()
        cameraFitSize = stage.bounds.size
      }
    }
    updateProjectedLabels()
  }
  func render(
    _ document: SceneDocument, time: Double, selectedID: String?,
    presentationGeneration: UInt64? = nil
  ) {
    displayRenderCount = min(1_000_000, displayRenderCount + 1)
    let documentChanged = self.document != document
    self.document = document
    selection = selectedID
    guard let poses = try? document.worldPoses(at: time) else { return }
    self.poses = poses
    guard let typedPoses = try? document.spatialWorldPoses(at: time) else { return }
    spatialPoses = Dictionary(uniqueKeysWithValues: typedPoses.map { ($0.node.id, $0) })
    if let presentationGeneration { labelGeneration = presentationGeneration }
    reconcileLabelReveal()
    let nodes = poses.map(\.node)
    let ids = Set(nodes.map(\.id))
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    for id in Array(nodeLayers.keys)
    where !ids.contains(id) || nodes.first(where: { $0.id == id }).map(Self.isSpatialBody) == true {
      nodeLayers.removeValue(forKey: id)?.removeFromSuperlayer()
      originals.removeValue(forKey: id)
      layerKinds.removeValue(forKey: id)
      pathKeys.removeValue(forKey: id)
      textKeys.removeValue(forKey: id)
      textSizes.removeValue(forKey: id)
    }
    for id in Array(leaderLayers.keys)
    where !nodes.contains(where: { $0.id == id && $0.spatial3D?.labelAnchor != nil }) {
      leaderLayers.removeValue(forKey: id)?.removeFromSuperlayer()
    }
    // Layer creation precedes hierarchy attachment, so child-before-parent input is correct on its first frame.
    for node in nodes where !Self.isSpatialBody(node) {
      if layerKinds[node.id] != node.kind {
        nodeLayers.removeValue(forKey: node.id)?.removeFromSuperlayer()
        originals.removeValue(forKey: node.id)
        pathKeys.removeValue(forKey: node.id)
        textKeys.removeValue(forKey: node.id)
        textSizes.removeValue(forKey: node.id)
      }
      if nodeLayers[node.id] == nil {
        let target: CALayer =
          node.kind == .text ? CATextLayer() : node.kind == .group ? CALayer() : CAShapeLayer()
        target.contentsScale = window?.backingScaleFactor ?? 2
        target.anchorPoint = .zero
        nodeLayers[node.id] = target
        layerKinds[node.id] = node.kind
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
          let animation = CABasicAnimation(keyPath: "opacity")
          animation.fromValue = 0
          animation.toValue = node.opacity
          animation.duration = 0.3
          target.add(animation, forKey: "appear")
        }
      }
    }
    for (index, node) in nodes.enumerated() where !Self.isSpatialBody(node) {
      guard let target = nodeLayers[node.id] else { continue }
      let parent =
        node.spatial3D?.labelAnchor != nil
        ? spatialLabels : node.parentID.flatMap { nodeLayers[$0] } ?? content
      if target.superlayer !== parent { parent.addSublayer(target) }
      if node.spatial3D?.labelAnchor == nil { target.isHidden = false }
      target.zPosition = Double(index)
      if originals[node.id] != node {
        let anchored = node.spatial3D?.labelAnchor != nil
        let size =
          node.kind == .text
          ? (anchored ? target.bounds.size : measureText(node))
          : CGSize(width: node.width, height: node.height)
        target.anchorPoint = .zero
        target.bounds = CGRect(origin: .zero, size: size)
        target.position = CGPoint(x: node.x, y: node.y)
        target.setAffineTransform(
          CGAffineTransform(rotationAngle: node.rotation * .pi / 180).scaledBy(
            x: node.scaleX, y: node.scaleY))
        target.opacity = Float(node.opacity)
        if let textLayer = target as? CATextLayer {
          if !anchored, originals[node.id]?.text != node.text { textLayer.string = node.text }
          if !anchored {
            textLayer.font = NSFont.systemFont(
              ofSize: max(10, node.fontSize), weight: node.fontSize >= 24 ? .semibold : .regular)
            textLayer.fontSize = max(10, node.fontSize)
          }
          textLayer.foregroundColor = NSColor(sceneHex: node.color).cgColor
          textLayer.isWrapped = true
          textLayer.truncationMode = .end
          textLayer.alignmentMode = .left
        } else if let shape = target as? CAShapeLayer {
          shape.strokeColor = NSColor(sceneHex: node.color).cgColor
          shape.fillColor = NSColor(sceneHex: node.fill).cgColor
          shape.lineWidth = node.strokeWidth
          shape.lineCap = .round
          shape.lineJoin = .round
          let key = PathKey(
            kind: node.kind, width: node.width, height: node.height, points: node.points,
            subpaths: node.subpaths)
          if pathKeys[node.id] != key {
            shape.path = makePath(node)
            pathKeys[node.id] = key
          }
        }
        originals[node.id] = node
      }
      target.borderWidth = node.id == selectedID ? 1.5 : 0
      target.borderColor = NSColor.systemBlue.cgColor
    }
    renderMeshes(nodes.filter(Self.isSpatialBody))
    CATransaction.commit()
    applyLayout()
    updateDisplayLink()
    if documentChanged {
      setAccessibilityValue(
        document.title + ". "
          + document.nodes.filter { !$0.text.isEmpty }.map(\.text).joined(separator: ". "))
    }
  }
  private struct PathKey: Equatable {
    var kind: SceneNode.Kind
    var width, height: Double
    var points: [Point2D]
    var subpaths: [[Point2D]]
  }
  private struct TextKey: Equatable {
    var text: String
    var size, width, height, canvasHeight, y: Double
    var medium = false
    var fontName = ""
    var maximumWidth = 0.0
  }
  private func measureText(_ node: SceneNode) -> CGSize {
    let width = max(1, min(node.width > 0 ? node.width : 300, document.width - max(0, node.x)))
    let key = TextKey(
      text: node.text, size: node.fontSize, width: width, height: node.height,
      canvasHeight: document.height, y: node.y)
    if textKeys[node.id] == key, let size = textSizes[node.id] { return size }
    let measured = NSString(string: node.text).boundingRect(
      with: NSSize(width: width, height: 100000),
      options: [.usesLineFragmentOrigin, .usesFontLeading],
      attributes: [
        .font: NSFont.systemFont(
          ofSize: max(10, node.fontSize), weight: node.fontSize >= 24 ? .semibold : .regular)
      ])
    let height = max(
      1, min(max(node.height, ceil(measured.height) + 6), document.height - max(0, node.y)))
    let size = CGSize(width: width, height: height)
    textKeys[node.id] = key
    textSizes[node.id] = size
    return size
  }

  private func spatialLabelFont(_ node: SceneNode) -> NSFont {
    let size = min(22, max(15, node.fontSize * ratio)) / ratio
    if presentation == .passiveOverlay,
      let handwritten = NSFont(name: "ChalkboardSE-Regular", size: size)
    {
      return handwritten
    }
    return NSFont.systemFont(ofSize: size, weight: .medium)
  }

  private func measureSpatialLabel(_ node: SceneNode, font: NSFont) -> CGSize {
    let maximumWidth = max(1, min(260 / ratio, document.width))
    let preferredWidth = max(1, min(node.width > 0 ? node.width : maximumWidth, maximumWidth))
    let key = TextKey(
      text: node.text, size: font.pointSize, width: preferredWidth, height: 0,
      canvasHeight: document.height, y: 0, medium: true, fontName: font.fontName,
      maximumWidth: maximumWidth)
    if textKeys[node.id] == key, let size = textSizes[node.id] { return size }
    let attributes: [NSAttributedString.Key: Any] = [.font: font]
    let padding = 4 / ratio
    // Model widths are preferences. Keep a word which fits the native cap on
    // one line rather than splitting its final letter into an orphaned row.
    var minimumWordWidth = CGFloat.zero
    for word in node.text.split(whereSeparator: { $0.isWhitespace }) {
      let line = CTLineCreateWithAttributedString(
        NSAttributedString(string: String(word), attributes: attributes))
      minimumWordWidth = max(
        minimumWordWidth, CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)))
    }
    let width = min(maximumWidth, max(preferredWidth, ceil(minimumWordWidth) + padding))
    let measured = NSString(string: node.text).boundingRect(
      with: CGSize(width: width, height: 100_000),
      options: [.usesLineFragmentOrigin, .usesFontLeading],
      attributes: attributes)
    let size = CGSize(
      width: max(1, min(maximumWidth, max(ceil(measured.width), ceil(minimumWordWidth)) + padding)),
      height: max(1, min(document.height, ceil(measured.height) + 4 / ratio)))
    textKeys[node.id] = key
    textSizes[node.id] = size
    return size
  }
  private func makePath(_ node: SceneNode) -> CGPath {
    let path = CGMutablePath()
    switch node.kind {
    case .rectangle:
      path.addRoundedRect(
        in: CGRect(x: 0, y: 0, width: node.width, height: node.height), cornerWidth: 10,
        cornerHeight: 10)
    case .ellipse: path.addEllipse(in: CGRect(x: 0, y: 0, width: node.width, height: node.height))
    case .line, .arrow, .path:
      let paths = node.subpaths.isEmpty ? [node.points] : node.subpaths
      for points in paths {
        if let first = points.first {
          path.move(to: CGPoint(x: first.x, y: first.y))
          for point in points.dropFirst() { path.addLine(to: CGPoint(x: point.x, y: point.y)) }
        }
        if node.kind == .arrow, let end = points.last,
          let before = points.dropLast().last(where: { hypot($0.x - end.x, $0.y - end.y) > 1e-8 })
        {
          let angle = atan2(end.y - before.y, end.x - before.x)
          for direction in [-1.0, 1.0] {
            path.move(to: CGPoint(x: end.x, y: end.y))
            path.addLine(
              to: CGPoint(
                x: end.x - 13 * cos(angle + direction * 0.4),
                y: end.y - 13 * sin(angle + direction * 0.4)))
          }
        }
      }
    default: break
    }
    return path
  }
  private func renderMeshes(_ nodes: [SceneNode]) {
    hasTypedSpatialContent = nodes.contains { $0.spatial3D != nil }
    updateCanvasBackground()
    guard !nodes.isEmpty else {
      stage?.isPlaying = false
      stage?.removeFromSuperview()
      stage = nil
      meshNodes.removeAll()
      meshKeys.removeAll()
      spatialGeometryKeys.removeAll()
      materialKeys.removeAll()
      cameraFitKeys.removeAll()
      cameraFitDocumentID = nil
      return
    }
    if stage == nil {
      let view = ExplanationSceneView(
        frame: bounds,
        options: [SCNView.Option.preferredRenderingAPI.rawValue: SCNRenderingAPI.metal.rawValue])
      view.scene = SCNScene()
      view.allowsCameraControl = presentation == .editor
      view.autoenablesDefaultLighting = true
      view.backgroundColor = .clear
      view.scene?.background.contents = NSColor.clear
      let camera = SCNNode()
      camera.camera = SCNCamera()
      camera.position = SCNVector3(0, 1.5, 9)
      view.scene?.rootNode.addChildNode(camera)
      view.pointOfView = camera
      view.defaultCameraController.inertiaEnabled = false
      view.onCameraChanged = { [weak self] in self?.updateCameraProjection() }
      addSubview(view)
      stage = view
    }
    stage?.isHidden = drawing
    let ids = Set(nodes.map(\.id))
    for id in Array(meshNodes.keys) where !ids.contains(id) {
      meshNodes.removeValue(forKey: id)?.removeFromParentNode()
      meshKeys.removeValue(forKey: id)
      spatialGeometryKeys.removeValue(forKey: id)
      materialKeys.removeValue(forKey: id)
    }
    // Create every body before attaching hierarchy; provider order may put a
    // child before its group. Typed transforms are local native 3D transforms.
    for source in nodes {
      if meshNodes[source.id] == nil {
        let node = SCNNode()
        node.name = source.id
        meshNodes[source.id] = node
        if source.kind == .mesh, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
          let fade = CABasicAnimation(keyPath: "opacity")
          fade.fromValue = 0
          fade.toValue = source.opacity
          fade.duration = 0.28
          node.addAnimation(fade, forKey: "partAppear")
        }
      }
    }
    for source in nodes {
      guard let node = meshNodes[source.id], let root = stage?.scene?.rootNode else { continue }
      let parent =
        source.spatial3D != nil ? source.parentID.flatMap { meshNodes[$0] } ?? root : root
      if node.parent !== parent { parent.addChildNode(node) }
      if let spatial = source.spatial3D {
        if let descriptor = spatial.geometry {
          if spatialGeometryKeys[source.id] != descriptor {
            node.geometry = try? Spatial3DGeometryFactory.make(descriptor)
            materialKeys.removeValue(forKey: source.id)
            spatialGeometryKeys[source.id] = node.geometry == nil ? nil : descriptor
          }
        } else {
          node.geometry = nil
          spatialGeometryKeys.removeValue(forKey: source.id)
          materialKeys.removeValue(forKey: source.id)
        }
        meshKeys.removeValue(forKey: source.id)
        node.simdTransform = Self.nativeMatrix(spatial.transform.matrix)
        node.opacity = CGFloat(source.opacity)
        updateMaterial(node: node, source: source)
        continue
      }
      spatialGeometryKeys.removeValue(forKey: source.id)
      // Legacy documents keep their original 2D-positioned primitive fallback.
      let key = "\(source.text):\(source.width):\(source.height)"
      let geometry: SCNGeometry
      if let cached = geometryCache[key] {
        geometry = cached
      } else {
        geometry =
          source.text.lowercased().contains("sphere")
          ? SCNSphere(radius: max(0.05, source.width / 200))
          : source.text.lowercased().contains("cylinder")
            ? SCNCylinder(
              radius: max(0.05, source.width / 200), height: max(0.05, source.height / 100))
            : SCNBox(
              width: max(0.05, source.width / 100), height: max(0.05, source.height / 100),
              length: 0.35, chamferRadius: 0.04)
        if geometryCache.count >= 128, let first = geometryCache.keys.first {
          geometryCache.removeValue(forKey: first)
        }
        geometryCache[key] = geometry
      }
      if meshKeys[source.id] != key {
        node.geometry = geometry.copy() as? SCNGeometry
        node.geometry?.materials = geometry.materials.compactMap { $0.copy() as? SCNMaterial }
        meshKeys[source.id] = key
        materialKeys.removeValue(forKey: source.id)
      }
      let pose = poses.first { $0.node.id == source.id }
      let world = pose?.transform.applying(to: .init(x: 0, y: 0)) ?? .init(x: source.x, y: source.y)
      node.position = SCNVector3(
        Float((world.x - document.width / 2) / 100), Float((document.height / 2 - world.y) / 100), 0
      )
      node.eulerAngles = SCNVector3(
        0, Float(pose.map { atan2($0.transform.b, $0.transform.a) } ?? source.rotation * .pi / 180),
        0)
      node.opacity = CGFloat(pose?.effectiveOpacity ?? source.opacity)
      updateMaterial(node: node, source: source)
    }
    let fitKeys = document.nodes.filter(Self.isSpatialBody).map(CameraFitKey.init)
    if hasTypedSpatialContent,
      cameraFitDocumentID != document.id || cameraFitKeys != fitKeys
    {
      fitCameraToGeometry()
      cameraFitDocumentID = document.id
      cameraFitKeys = fitKeys
    }
  }

  private static func isSpatialBody(_ node: SceneNode) -> Bool {
    node.kind == .mesh || (node.kind == .group && node.spatial3D != nil)
  }

  private func updateCanvasBackground() {
    layer?.backgroundColor =
      presentation == .passiveOverlay
      ? NSColor.clear.cgColor
      : (hasTypedSpatialContent ? NSColor(white: 0.055, alpha: 1) : NSColor.white).cgColor
  }

  private func updateMaterial(node: SCNNode, source: SceneNode) {
    guard let geometry = node.geometry else { return }
    let key = source.fill == "transparent" ? source.color : source.fill
    guard materialKeys[source.id] != key || geometry.firstMaterial == nil else { return }
    let material = geometry.firstMaterial ?? SCNMaterial()
    material.diffuse.contents = NSColor(
      sceneHex: source.fill == "transparent" ? source.color : source.fill)
    material.lightingModel = .blinn
    material.specular.contents = NSColor(white: 0.6, alpha: 1)
    material.shininess = 0.35
    geometry.materials = [material]
    materialKeys[source.id] = key
  }

  private struct CameraFitKey: Equatable {
    let id: String
    let parentID: String?
    let spatial: SceneSpatial3D?
    let legacyWidth: Double
    let legacyHeight: Double
    let legacyText: String
    init(_ node: SceneNode) {
      id = node.id
      parentID = node.parentID
      spatial = node.spatial3D
      legacyWidth = node.spatial3D == nil ? node.width : 0
      legacyHeight = node.spatial3D == nil ? node.height : 0
      legacyText = node.spatial3D == nil ? node.text : ""
    }
  }

  private static func nativeMatrix(_ matrix: Matrix4x4D) -> simd_float4x4 {
    let values = matrix.elements
    return simd_float4x4(
      columns: (
        SIMD4(Float(values[0]), Float(values[1]), Float(values[2]), Float(values[3])),
        SIMD4(Float(values[4]), Float(values[5]), Float(values[6]), Float(values[7])),
        SIMD4(Float(values[8]), Float(values[9]), Float(values[10]), Float(values[11])),
        SIMD4(Float(values[12]), Float(values[13]), Float(values[14]), Float(values[15]))
      ))
  }

  private func fitCameraToGeometry() {
    guard let stage, let camera = stage.pointOfView else { return }
    var points: [SCNVector3] = []
    for node in meshNodes.values where node.geometry != nil {
      let box = node.boundingBox
      for x in [box.min.x, box.max.x] {
        for y in [box.min.y, box.max.y] {
          for z in [box.min.z, box.max.z] {
            let point = node.convertPosition(SCNVector3(x, y, z), to: nil)
            if point.x.isFinite && point.y.isFinite && point.z.isFinite { points.append(point) }
          }
        }
      }
    }
    guard let first = points.first else { return }
    var low = first
    var high = first
    for point in points {
      low = SCNVector3(min(low.x, point.x), min(low.y, point.y), min(low.z, point.z))
      high = SCNVector3(max(high.x, point.x), max(high.y, point.y), max(high.z, point.z))
    }
    let center = SCNVector3((low.x + high.x) / 2, (low.y + high.y) / 2, (low.z + high.z) / 2)
    guard stage.bounds.width.isFinite, stage.bounds.height.isFinite,
      stage.bounds.width > 0, stage.bounds.height > 0, let lens = camera.camera
    else { return }
    let origin = SIMD3(Double(center.x), Double(center.y), Double(center.z))
    let back = simd_normalize(SIMD3<Double>(0.55, 0.3, 1))
    let right = simd_normalize(simd_cross(SIMD3<Double>(0, 1, 0), back))
    let up = simd_cross(back, right)
    let verticalTangent = tan(25 * Double.pi / 180)
    let horizontalTangent = verticalTangent * Double(stage.bounds.width / stage.bounds.height)
    guard horizontalTangent.isFinite, horizontalTangent > 0 else { return }
    // Solve perspective bounds directly in this fixed oblique camera basis.
    // A diagonal bounding sphere needlessly shrinks thin/rotated assemblies.
    let margin = 1.12
    var distance = 0.01
    var minimumBack = Double.infinity
    var maximumBack = -Double.infinity
    for point in points {
      let relative = SIMD3(Double(point.x), Double(point.y), Double(point.z)) - origin
      let x = simd_dot(relative, right)
      let y = simd_dot(relative, up)
      let z = simd_dot(relative, back)
      distance = max(
        distance, z + 0.001,
        z + margin * abs(x) / horizontalTangent,
        z + margin * abs(y) / verticalTangent)
      minimumBack = min(minimumBack, z)
      maximumBack = max(maximumBack, z)
    }
    let nearestDepth = distance - maximumBack
    let farthestDepth = distance - minimumBack
    let position = origin + back * distance
    guard distance.isFinite, nearestDepth > 0, farthestDepth.isFinite,
      position.x.isFinite, position.y.isFinite, position.z.isFinite
    else { return }
    lens.projectionDirection = .vertical
    lens.fieldOfView = 50
    let radius = max(0.01, Double(hypot(hypot(high.x - low.x, high.y - low.y), high.z - low.z)) / 2)
    lens.zNear = max(0.000_01, min(max(0.001, radius / 1_000), nearestDepth * 0.5))
    // Retain zoom/orbit headroom; fitting the initial view must not clip an
    // editor camera once it moves farther away from the same retained assembly.
    lens.zFar = max(farthestDepth + 0.01, distance + radius * 8)
    camera.position = SCNVector3(Float(position.x), Float(position.y), Float(position.z))
    camera.look(at: center)
    stage.defaultCameraController.automaticTarget = false
    stage.defaultCameraController.target = center
    SCNTransaction.flush()
  }

  /// Project each retained label's actual world anchor through the current
  /// camera. No screen-fixed approximation is used for orbiting geometry.
  private func updateProjectedLabels() {
    guard let stage else { return }
    var visible: [(SceneNode, LabelAnchor3D, CATextLayer, CGPoint)] = []
    var items: [SpatialLabelLayout.Item] = []
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    for pose in poses {
      let source = pose.node
      guard let anchor = source.spatial3D?.labelAnchor,
        let text = nodeLayers[source.id] as? CATextLayer
      else {
        continue
      }
      let visibleText =
        presentation == .passiveOverlay
        ? labelReveal.visibleText(id: source.id) ?? "" : source.text
      if text.string as? String != visibleText { text.string = visibleText }
      // Label glyphs remain legible in a compact stage rather than shrinking
      // with the document. Measurements stay cached by the effective font size.
      let font = spatialLabelFont(source)
      text.bounds.size = measureSpatialLabel(source, font: font)
      text.contentsScale = max(0.0001, min(16, ratio * (window?.backingScaleFactor ?? 2)))
      if text.fontSize != font.pointSize || (text.font as? NSFont)?.fontName != font.fontName {
        text.font = font
        text.fontSize = font.pointSize
      }
      guard let target = spatialPoses[anchor.targetID], target.effectiveOpacity > 0 else {
        text.isHidden = true
        leaderLayers[source.id]?.isHidden = true
        continue
      }
      let world = target.transform.applying(to: anchor.point)
      let projected = stage.projectPoint(SCNVector3(Float(world.x), Float(world.y), Float(world.z)))
      guard projected.x.isFinite, projected.y.isFinite, projected.z.isFinite,
        projected.z >= 0, projected.z <= 1,
        stage.bounds.contains(CGPoint(x: CGFloat(projected.x), y: CGFloat(projected.y)))
      else {
        text.isHidden = true
        leaderLayers[source.id]?.isHidden = true
        continue
      }
      // SceneKit projects in the viewport's lower-left coordinates. Convert
      // explicitly into this flipped canvas before applying native point offsets.
      let native = stage.convert(
        CGPoint(x: CGFloat(projected.x), y: CGFloat(projected.y)), to: self)
      let point = CGPoint(x: (native.x - content.position.x) / ratio, y: native.y / ratio)
      items.append(
        .init(
          id: source.id, anchor: point,
          preferredOrigin: CGPoint(
            x: point.x + anchor.screenOffset.x / ratio,
            y: point.y + anchor.screenOffset.y / ratio), size: text.bounds.size))
      visible.append((source, anchor, text, point))
    }
    let key = LabelLayoutKey(
      documentID: document.id, items: items,
      bounds: CGRect(x: 0, y: 0, width: document.width, height: document.height),
      objectBounds: projectedGeometryBounds(), gap: 6 / ratio)
    if labelLayoutKey != key {
      let previous = labelLayoutKey?.documentID == document.id ? labelLayout.frames : [:]
      labelLayout = SpatialLabelLayout.place(
        items, in: key.bounds, objectBounds: key.objectBounds, gap: key.gap, previous: previous)
      labelLayoutKey = key
      unresolvedLabelOverlapCount = labelLayout.overlappingPairs
    }
    for (source, anchor, text, point) in visible {
      guard let frame = labelLayout.frames[source.id] else {
        text.isHidden = true
        leaderLayers[source.id]?.isHidden = true
        continue
      }
      text.isHidden = false
      text.position = frame.origin
      text.setAffineTransform(.identity)
      let leader = leaderLayers[source.id] ?? CAShapeLayer()
      if leaderLayers[source.id] == nil {
        leaderLayers[source.id] = leader
        spatialLabels.addSublayer(leader)
      }
      leader.isHidden = !anchor.leader
      leader.fillColor = NSColor(sceneHex: source.color).cgColor
      leader.strokeColor = NSColor(sceneHex: source.color).cgColor
      leader.lineWidth = 1.2 / ratio
      leader.lineCap = .round
      leader.opacity = Float(source.opacity)
      leader.zPosition = text.zPosition - 0.5
      let end = SpatialLabelLayout.closestPoint(point, on: frame)
      let path = CGMutablePath()
      path.move(to: point)
      path.addLine(to: end)
      path.addEllipse(
        in: CGRect(
          x: point.x - 2 / ratio, y: point.y - 2 / ratio, width: 4 / ratio, height: 4 / ratio))
      leader.path = path
    }
    CATransaction.commit()
  }

  private func projectedGeometryBounds() -> CGRect? {
    guard let stage else { return nil }
    var minimum = CGPoint(x: CGFloat.infinity, y: CGFloat.infinity)
    var maximum = CGPoint(x: -CGFloat.infinity, y: -CGFloat.infinity)
    for (id, node) in meshNodes where node.geometry != nil {
      guard (spatialPoses[id]?.effectiveOpacity ?? 1) > 0 else { continue }
      let box = node.boundingBox
      for x in [box.min.x, box.max.x] {
        for y in [box.min.y, box.max.y] {
          for z in [box.min.z, box.max.z] {
            let world = node.convertPosition(SCNVector3(x, y, z), to: nil)
            let projected = stage.projectPoint(world)
            guard projected.x.isFinite, projected.y.isFinite, projected.z.isFinite,
              projected.z >= 0, projected.z <= 1
            else { continue }
            let native = stage.convert(
              CGPoint(x: CGFloat(projected.x), y: CGFloat(projected.y)), to: self)
            let point = CGPoint(x: (native.x - content.position.x) / ratio, y: native.y / ratio)
            minimum = CGPoint(x: min(minimum.x, point.x), y: min(minimum.y, point.y))
            maximum = CGPoint(x: max(maximum.x, point.x), y: max(maximum.y, point.y))
          }
        }
      }
    }
    guard minimum.x.isFinite, minimum.y.isFinite,
      maximum.x > minimum.x, maximum.y > minimum.y
    else { return nil }
    return CGRect(
      x: minimum.x, y: minimum.y, width: maximum.x - minimum.x, height: maximum.y - minimum.y)
  }

  func spatialNode(id: String) -> SCNNode? { meshNodes[id] }

  func projectedLabelFrame(id: String) -> CGRect? {
    guard let layer = nodeLayers[id], layer.superlayer === spatialLabels, !layer.isHidden else {
      return nil
    }
    return layer.frame
  }

  var projectedLabelFrames: [String: CGRect] {
    var frames: [String: CGRect] = [:]
    for (id, layer) in nodeLayers where layer.superlayer === spatialLabels && !layer.isHidden {
      frames[id] = layer.frame
    }
    return frames
  }

  var spatialStage: SCNView? { stage }
  var renderedDocumentID: String { document.id }

  func updateCameraProjection() {
    SCNTransaction.flush()
    updateProjectedLabels()
  }

  func projectedLeaderPath(id: String) -> CGPath? {
    guard let leader = leaderLayers[id], !leader.isHidden else { return nil }
    return leader.path
  }

  var hasPendingSpatialLabels: Bool { labelReveal.hasRevealableText }
  var needsDisplayClock: Bool { nativePlaying || labelReveal.hasRevealableText }
  var isDisplayClockRunning: Bool { nativeDisplayLink?.isPaused == false }
  var displayClockDiagnostics: CanvasDisplayClockDiagnostics {
    let frames = projectedLabelFrames
    let lastAge = lastObservedDisplayCallback.map {
      max(0, ProcessInfo.processInfo.systemUptime - $0)
    }
    return .init(
      linkExists: nativeDisplayLink != nil, linkPaused: nativeDisplayLink?.isPaused ?? true,
      windowBound: window != nil && displayClockWindow === window,
      windowVisible: window?.isVisible == true, windowOnDisplay: window?.screen != nil,
      windowOcclusionVisible: window?.occlusionState.contains(.visible) == true,
      hiddenAncestor: isHiddenOrHasHiddenAncestor,
      reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
      scenePlaying: nativePlaying, pendingLabels: hasPendingSpatialLabels,
      callbackCount: displayCallbackCount, acceptedCallbackCount: acceptedDisplayCallbackCount,
      labelAdvanceCount: displayLabelAdvanceCount, renderCount: displayRenderCount,
      reconcileCount: displayReconcileCount, stopCount: displayStopCount,
      accumulatedDelta: displayAccumulatedDelta, lastCallbackAge: lastAge,
      visibleLabelCount: frames.count,
      nonemptyVisibleLabelCount: frames.keys.filter {
        projectedLabelText(id: $0)?.isEmpty == false
      }.count)
  }
  func projectedLabelText(id: String) -> String? {
    (nodeLayers[id] as? CATextLayer)?.string as? String
  }

  /// Shared by native display ticks and deterministic tests; geometry and label
  /// measurements stay unchanged while only the retained glyph prefix changes.
  @discardableResult func advanceSpatialLabels(by delta: Double, reduceMotion: Bool = false) -> Bool
  {
    let changed = labelReveal.advance(by: delta, reduceMotion: reduceMotion)
    if changed { updateProjectedLabels() }
    return changed
  }

  private func reconcileLabelReveal() {
    displayReconcileCount = min(1_000_000, displayReconcileCount + 1)
    guard presentation == .passiveOverlay else {
      labelReveal.reset()
      return
    }
    let labels = poses.compactMap { pose -> SpatialLabelReveal.Label? in
      guard let anchor = pose.node.spatial3D?.labelAnchor else { return nil }
      return .init(id: pose.node.id, text: pose.node.text, anchor: anchor)
    }
    labelReveal.reconcile(
      documentID: document.id, generation: labelGeneration, labels: labels,
      reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
  }

  func canvasFrame(forDocumentRect rect: CGRect) -> CGRect {
    CGRect(
      x: content.position.x + rect.minX * ratio, y: content.position.y + rect.minY * ratio,
      width: rect.width * ratio, height: rect.height * ratio)
  }

  /// Native SceneKit snapshot plus the same retained 2D/label layers. This is
  /// an own-view diagnostic, not a WindowServer capture or FPS measurement.
  func explanationSnapshot(includeSpatialLabels: Bool = true) throws -> NSBitmapImageRep {
    let scale = min(2, max(1, window?.backingScaleFactor ?? 2))
    let pixelWidth = ceil(bounds.width * scale)
    let pixelHeight = ceil(bounds.height * scale)
    guard bounds.width.isFinite, bounds.height.isFinite,
      bounds.width > 0, bounds.height > 0, bounds.width <= 4096, bounds.height <= 4096,
      pixelWidth * pixelHeight <= 8_000_000,
      let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(pixelWidth),
        pixelsHigh: Int(pixelHeight), bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0,
        bitsPerPixel: 0), let graphics = NSGraphicsContext(bitmapImageRep: bitmap)
    else { throw ProviderError.message("Could not allocate the bounded explanation snapshot.") }
    let context = graphics.cgContext
    bitmap.size = bounds.size
    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    context.scaleBy(x: scale, y: scale)
    context.translateBy(x: 0, y: bounds.height)
    context.scaleBy(x: 1, y: -1)
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
    context.clear(bounds)
    if let color = layer?.backgroundColor {
      context.setFillColor(color)
      context.fill(bounds)
    }
    func draw(_ layer: CALayer) {
      context.saveGState()
      context.translateBy(x: layer.position.x, y: layer.position.y)
      context.scaleBy(x: ratio, y: ratio)
      layer.render(in: context)
      context.restoreGState()
    }
    draw(content)
    if let stage {
      stage.snapshot().draw(
        in: stage.frame, from: .zero, operation: .sourceOver, fraction: 1,
        respectFlipped: true, hints: nil)
    }
    if includeSpatialLabels { draw(spatialLabels) }
    return bitmap
  }
  override func mouseDown(with event: NSEvent) {
    guard presentation == .editor else { return }
    let point = convert(event.locationInWindow, from: nil)
    let local = CGPoint(x: (point.x - content.position.x) / ratio, y: point.y / ratio)
    if drawing {
      guard CGRect(x: 0, y: 0, width: document.width, height: document.height).contains(local)
      else { return }
      onBeginEdit?()
      activeStroke = [.init(x: local.x, y: local.y)]
      return
    }
    let matchID = try? document.hitTest(
      .init(x: local.x, y: local.y), at: currentTime, tolerance: min(100, 6 / ratio))
    onSelect?(matchID)
    selection = matchID
    guard let matchID, let pose = poses.first(where: { $0.node.id == matchID }) else {
      dragStart = nil
      nodeStart = nil
      return
    }
    onBeginEdit?()
    let parent =
      pose.node.parentID.flatMap { id in poses.first { $0.node.id == id }?.transform } ?? .identity
    dragParentInverse = (try? parent.inverted()) ?? .identity
    let parentPoint = dragParentInverse.applying(to: .init(x: local.x, y: local.y))
    dragStart = CGPoint(x: parentPoint.x, y: parentPoint.y)
    nodeStart = CGPoint(x: pose.node.x, y: pose.node.y)
  }
  override func mouseDragged(with event: NSEvent) {
    let point = convert(event.locationInWindow, from: nil)
    let local = Point2D(x: (point.x - content.position.x) / ratio, y: point.y / ratio)
    if drawing {
      guard !activeStroke.isEmpty, activeStroke.count < 8192 else { return }
      let bounded = Point2D(
        x: min(document.width, max(0, local.x)), y: min(document.height, max(0, local.y)))
      if let previous = activeStroke.last,
        hypot(previous.x - bounded.x, previous.y - bounded.y) > 1 / ratio
      {
        activeStroke.append(bounded)
      }
      let path = CGMutablePath()
      path.addLines(between: activeStroke.map { CGPoint(x: $0.x, y: $0.y) })
      ink.path = path
      return
    }
    guard let selection, let start = dragStart, let original = nodeStart else { return }
    let parentPoint = dragParentInverse.applying(to: local)
    onMove?(selection, original.x + parentPoint.x - start.x, original.y + parentPoint.y - start.y)
  }
  override func mouseUp(with event: NSEvent) {
    if drawing {
      if activeStroke.count >= 2 { onStroke?(activeStroke) }
      activeStroke.removeAll()
      ink.path = nil
    }
    dragStart = nil
    nodeStart = nil
  }
  func pdfData() -> Data { dataWithPDF(inside: bounds) }
}

/// Editor-only camera interactions refresh projected labels after SceneKit
/// changes its camera. Inertia is disabled so there is no hidden idle clock.
@MainActor private final class ExplanationSceneView: SCNView {
  var onCameraChanged: (() -> Void)?
  override var isOpaque: Bool { false }
  override var isFlipped: Bool { false }
  override func mouseDragged(with event: NSEvent) {
    super.mouseDragged(with: event)
    onCameraChanged?()
  }
  override func scrollWheel(with event: NSEvent) {
    super.scrollWheel(with: event)
    onCameraChanged?()
  }
  override func magnify(with event: NSEvent) {
    super.magnify(with: event)
    onCameraChanged?()
  }
  override func rotate(with event: NSEvent) {
    super.rotate(with: event)
    onCameraChanged?()
  }
}
