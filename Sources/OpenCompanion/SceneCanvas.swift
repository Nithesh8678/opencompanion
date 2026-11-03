import AppKit
import CompanionCore
import SceneKit
import SwiftUI

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
    view.drawing = drawing
    view.configureClock(
      documentID: document.id, time: time, playing: playing, speed: speed,
      seekRevision: seekRevision)
    view.render(document, time: view.currentTime, selectedID: selectedID)
  }
  static func dismantleNSView(_ view: RetainedCanvasView, coordinator: ()) {
    view.stopDisplayLink()
  }
}
@MainActor final class RetainedCanvasView: NSView {
  override var isFlipped: Bool { true }
  private var nodeLayers: [String: CALayer] = [:]
  private var originals: [String: SceneNode] = [:]
  private var layerKinds: [String: SceneNode.Kind] = [:]
  private var pathKeys: [String: PathKey] = [:]
  private var textKeys: [String: TextKey] = [:]
  private var textSizes: [String: CGSize] = [:]
  private var content = CALayer()
  private var document = SceneDocument()
  private var selection: String?
  private var dragStart: CGPoint?
  private var nodeStart: CGPoint?
  private var ratio = 1.0
  private var stage: SCNView?
  private var meshNodes: [String: SCNNode] = [:]
  private var geometryCache: [String: SCNGeometry] = [:]
  private var meshKeys: [String: String] = [:]
  private var poses: [ScenePose] = []
  private var dragParentInverse: AffineTransform2D = .identity
  private let ink = CAShapeLayer()
  private var activeStroke: [Point2D] = []
  private var nativeDisplayLink: CADisplayLink?
  private var clock: AnimationClock?
  private var nativePlaying = false
  private var clockDocumentID: String?
  private var lastSeekRevision = -1
  private var windowObservation: NSObjectProtocol?
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
  var onSelect: ((String?) -> Void)?
  var onMove: ((String, Double, Double) -> Void)?
  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    layer?.backgroundColor = NSColor.white.cgColor
    layer?.addSublayer(content)
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
  override func layout() {
    super.layout()
    applyLayout()
  }
  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    if let windowObservation { NotificationCenter.default.removeObserver(windowObservation) }
    windowObservation = nil
    if let window {
      windowObservation = NotificationCenter.default.addObserver(
        forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
      ) { [weak self] _ in Task { @MainActor in self?.visibilityChanged() } }
    }
    visibilityChanged()
  }
  override func viewWillMove(toWindow newWindow: NSWindow?) {
    if newWindow == nil {
      stopDisplayLink()
      if let windowObservation { NotificationCenter.default.removeObserver(windowObservation) }
      windowObservation = nil
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
      nativePlaying && window?.isVisible == true && !isHiddenOrHasHiddenAncestor,
      at: ProcessInfo.processInfo.systemUptime)
    updateDisplayLink()
  }
  func configureClock(
    documentID: String, time: Double, playing: Bool?, speed: Double, seekRevision: Int
  ) {
    let now = ProcessInfo.processInfo.systemUptime
    let wasPlaying = nativePlaying
    if let playing {
      let playing = playing && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
      let clockActive = playing && window?.isVisible == true && !isHiddenOrHasHiddenAncestor
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
    guard nativePlaying, window?.isVisible == true, !isHiddenOrHasHiddenAncestor,
      !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    else {
      nativeDisplayLink?.isPaused = true
      return
    }
    if nativeDisplayLink == nil {
      let link = displayLink(target: self, selector: #selector(displayFrame(_:)))
      link.add(to: .main, forMode: .common)
      nativeDisplayLink = link
    }
    nativeDisplayLink?.isPaused = false
  }
  func stopDisplayLink() {
    nativeDisplayLink?.invalidate()
    nativeDisplayLink = nil
    stage?.isPlaying = false
  }
  @objc private func displayFrame(_ sender: CADisplayLink) {
    guard nativePlaying, !isHiddenOrHasHiddenAncestor, window?.isVisible == true else {
      sender.isPaused = true
      return
    }
    if let time = try? clock?.value(at: ProcessInfo.processInfo.systemUptime) {
      currentTime = time
      render(document, time: time, selectedID: selection)
    }
  }
  private func applyLayout() {
    ratio = max(0.0001, min(bounds.width / document.width, bounds.height / document.height))
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    content.anchorPoint = .zero
    content.position = CGPoint(x: max(0, (bounds.width - document.width * ratio) / 2), y: 0)
    content.bounds = CGRect(x: 0, y: 0, width: document.width, height: document.height)
    content.setAffineTransform(CGAffineTransform(scaleX: ratio, y: ratio))
    CATransaction.commit()
    if let stage {
      stage.frame = CGRect(
        x: bounds.width * 0.08, y: bounds.height * 0.15, width: bounds.width * 0.84,
        height: bounds.height * 0.7)
    }
  }
  func render(_ document: SceneDocument, time: Double, selectedID: String?) {
    let documentChanged = self.document != document
    self.document = document
    selection = selectedID
    guard let poses = try? document.worldPoses(at: time) else { return }
    self.poses = poses
    let nodes = poses.map(\.node)
    let ids = Set(nodes.map(\.id))
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    for id in Array(nodeLayers.keys)
    where !ids.contains(id) || nodes.first(where: { $0.id == id })?.kind == .mesh {
      nodeLayers.removeValue(forKey: id)?.removeFromSuperlayer()
      originals.removeValue(forKey: id)
      layerKinds.removeValue(forKey: id)
      pathKeys.removeValue(forKey: id)
      textKeys.removeValue(forKey: id)
      textSizes.removeValue(forKey: id)
    }
    // Layer creation precedes hierarchy attachment, so child-before-parent input is correct on its first frame.
    for node in nodes where node.kind != .mesh {
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
    for (index, node) in nodes.enumerated() where node.kind != .mesh {
      guard let target = nodeLayers[node.id] else { continue }
      let parent = node.parentID.flatMap { nodeLayers[$0] } ?? content
      if target.superlayer !== parent { parent.addSublayer(target) }
      target.zPosition = Double(index)
      if originals[node.id] != node {
        let size =
          node.kind == .text ? measureText(node) : CGSize(width: node.width, height: node.height)
        target.anchorPoint = .zero
        target.bounds = CGRect(origin: .zero, size: size)
        target.position = CGPoint(x: node.x, y: node.y)
        target.setAffineTransform(
          CGAffineTransform(rotationAngle: node.rotation * .pi / 180).scaledBy(
            x: node.scaleX, y: node.scaleY))
        target.opacity = Float(node.opacity)
        if let textLayer = target as? CATextLayer {
          if originals[node.id]?.text != node.text { textLayer.string = node.text }
          textLayer.font = NSFont.systemFont(
            ofSize: max(10, node.fontSize), weight: node.fontSize >= 24 ? .semibold : .regular)
          textLayer.fontSize = max(10, node.fontSize)
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
    renderMeshes(nodes.filter { $0.kind == .mesh })
    CATransaction.commit()
    applyLayout()
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
    guard !nodes.isEmpty else {
      stage?.removeFromSuperview()
      stage = nil
      meshNodes.removeAll()
      meshKeys.removeAll()
      return
    }
    if stage == nil {
      let view = SCNView(
        frame: bounds,
        options: [SCNView.Option.preferredRenderingAPI.rawValue: SCNRenderingAPI.metal.rawValue])
      view.scene = SCNScene()
      view.allowsCameraControl = true
      view.autoenablesDefaultLighting = true
      view.backgroundColor = .clear
      let camera = SCNNode()
      camera.camera = SCNCamera()
      camera.position = SCNVector3(0, 1.5, 9)
      view.scene?.rootNode.addChildNode(camera)
      view.pointOfView = camera
      addSubview(view)
      stage = view
    }
    stage?.isHidden = drawing
    let ids = Set(nodes.map(\.id))
    for id in Array(meshNodes.keys) where !ids.contains(id) {
      meshNodes.removeValue(forKey: id)?.removeFromParentNode()
      meshKeys.removeValue(forKey: id)
    }
    for source in nodes {
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
      let node = meshNodes[source.id] ?? SCNNode(geometry: geometry)
      if meshNodes[source.id] == nil {
        meshNodes[source.id] = node
        stage?.scene?.rootNode.addChildNode(node)
      }
      if meshKeys[source.id] != key {
        node.geometry = geometry.copy() as? SCNGeometry
        node.geometry?.materials = geometry.materials.compactMap { $0.copy() as? SCNMaterial }
        meshKeys[source.id] = key
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
      node.geometry?.firstMaterial?.diffuse.contents = NSColor(
        sceneHex: source.fill == "transparent" ? source.color : source.fill)
    }
  }
  override func mouseDown(with event: NSEvent) {
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
