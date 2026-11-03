import AppKit
import SwiftUI
import SceneKit
import CompanionCore

extension NSColor {
    convenience init(sceneHex: String) {
        guard sceneHex != "transparent" else { self.init(white:0,alpha:0); return }
        let clean = String(sceneHex.dropFirst()); let value = UInt64(clean,radix:16) ?? 0x2458A6
        let shift = clean.count == 8 ? 8 : 0
        self.init(srgbRed:Double((value >> (16+shift)) & 255)/255,green:Double((value >> (8+shift)) & 255)/255,blue:Double((value >> shift) & 255)/255,alpha:shift == 8 ? Double(value & 255)/255 : 1)
    }
}
struct SceneCanvas: NSViewRepresentable {
    var document: SceneDocument; var time: Double; var selectedID: String?; var onSelect: (String?) -> Void; var onMove: (String,Double,Double) -> Void
    var playing: Bool? = nil
    var speed: Double = 1
    var seekRevision: Int = 0
    var onTimeChange: ((Double) -> Void)? = nil
    var drawing: Bool = false
    var onStroke: (([Point2D]) -> Void)? = nil
    var onBeginEdit: (() -> Void)? = nil
    func makeNSView(context: Context) -> RetainedCanvasView { let view = RetainedCanvasView(); view.onSelect = onSelect; view.onMove = onMove; return view }
    func updateNSView(_ view: RetainedCanvasView,context: Context) {
        view.onSelect = onSelect; view.onMove = onMove; view.onTimeChange = onTimeChange
        view.onStroke = onStroke; view.onBeginEdit = onBeginEdit; view.drawing = drawing
        view.configureClock(documentID: document.id, time: time, playing: playing, speed: speed, seekRevision: seekRevision)
        view.render(document,time:view.currentTime,selectedID:selectedID)
    }
    static func dismantleNSView(_ view: RetainedCanvasView, coordinator: ()) { view.stopDisplayLink() }
}
@MainActor final class RetainedCanvasView: NSView {
    override var isFlipped: Bool { true }
    private var nodeLayers: [String:CALayer] = [:]
    private var originals: [String:SceneNode] = [:]
    private var layerKinds: [String:SceneNode.Kind] = [:]
    private var pathKeys: [String:PathKey] = [:]
    private var textKeys: [String:TextKey] = [:]
    private var textSizes: [String:CGSize] = [:]
    private var content = CALayer()
    private var document = SceneDocument()
    private var selection: String?
    private var dragStart: CGPoint?
    private var nodeStart: CGPoint?
    private var ratio = 1.0
    private var stage: SCNView?
    private var meshNodes: [String:SCNNode] = [:]
    private var geometryCache: [String:SCNGeometry] = [:]
    private var meshKeys: [String:String] = [:]
    private var poses: [ScenePose] = []
    private var dragParentInverse: AffineTransform2D = .identity
    private let ink = CAShapeLayer()
    private var activeStroke: [Point2D] = []
    private var nativeDisplayLink: CADisplayLink?
    private var clock: AnimationClock?
    private var nativePlaying = false
    private var clockDocumentID: String?
    private var lastSeekRevision = -1
    private(set) var currentTime: Double = 0
    var onTimeChange: ((Double)->Void)?
    var onStroke: (([Point2D])->Void)?
    var onBeginEdit: (() -> Void)?
    var drawing = false { didSet { stage?.isHidden = drawing; if !drawing { activeStroke.removeAll(); ink.path = nil } } }
    var onSelect: ((String?) -> Void)?; var onMove: ((String,Double,Double) -> Void)?
    override init(frame:NSRect) { super.init(frame:frame); wantsLayer = true; layer?.backgroundColor = NSColor.white.cgColor; layer?.addSublayer(content); ink.strokeColor = NSColor.systemBlue.cgColor; ink.fillColor = nil; ink.lineWidth = 3; ink.lineCap = .round; ink.lineJoin = .round; ink.zPosition = 1_000_000; content.addSublayer(ink); setAccessibilityElement(true); setAccessibilityRole(.group); setAccessibilityLabel("Editable lesson canvas. Select a part to edit its text or position.") }
    required init?(coder:NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layout() { super.layout(); applyLayout() }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); updateDisplayLink() }
    override func viewWillMove(toWindow newWindow: NSWindow?) { if newWindow == nil { stopDisplayLink() }; super.viewWillMove(toWindow: newWindow) }
    override func viewDidHide() { super.viewDidHide(); nativeDisplayLink?.isPaused = true }
    override func viewDidUnhide() { super.viewDidUnhide(); updateDisplayLink() }
    func configureClock(documentID: String, time: Double, playing: Bool?, speed: Double, seekRevision: Int) {
        let now = ProcessInfo.processInfo.systemUptime; let wasPlaying = nativePlaying
        if let playing {
            if clock == nil || clockDocumentID != documentID || lastSeekRevision != seekRevision {
                clock = AnimationClock(at: now, phase: max(0,time), speed: min(16,max(0,speed)), isPlaying: playing)
            } else { try? clock?.setSpeed(min(16,max(0,speed)),at:now); try? clock?.setPlaying(playing,at:now) }
            currentTime = (try? clock?.value(at:now)) ?? max(0,time); nativePlaying = playing
            clockDocumentID = documentID; lastSeekRevision = seekRevision
        } else { clock = nil; nativePlaying = false; currentTime = max(0,time) }
        if wasPlaying && !nativePlaying { onTimeChange?(currentTime) }
        updateDisplayLink()
    }
    private func updateDisplayLink() {
        guard nativePlaying,window != nil,!isHiddenOrHasHiddenAncestor,!NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { nativeDisplayLink?.isPaused = true; return }
        if nativeDisplayLink == nil { let link = displayLink(target:self,selector:#selector(displayFrame(_:))); link.add(to:.main,forMode:.common); nativeDisplayLink = link }
        nativeDisplayLink?.isPaused = false
    }
    func stopDisplayLink() { nativeDisplayLink?.invalidate(); nativeDisplayLink = nil; stage?.isPlaying = false }
    @objc private func displayFrame(_ sender: CADisplayLink) {
        guard nativePlaying,!isHiddenOrHasHiddenAncestor,window?.isVisible == true else { sender.isPaused = true; return }
        if let time = try? clock?.value(at:ProcessInfo.processInfo.systemUptime) { currentTime = time; render(document,time:time,selectedID:selection) }
    }
    private func applyLayout() {
        ratio = max(0.0001,min(bounds.width/document.width,bounds.height/document.height))
        CATransaction.begin(); CATransaction.setDisableActions(true)
        content.anchorPoint = .zero; content.position = CGPoint(x:max(0,(bounds.width-document.width*ratio)/2),y:0)
        content.bounds = CGRect(x:0,y:0,width:document.width,height:document.height)
        content.setAffineTransform(CGAffineTransform(scaleX:ratio,y:ratio)); CATransaction.commit()
        if let stage { stage.frame = CGRect(x:bounds.width*0.08,y:bounds.height*0.15,width:bounds.width*0.84,height:bounds.height*0.7) }
    }
    func render(_ document:SceneDocument,time:Double,selectedID:String?) {
        self.document = document; selection = selectedID
        guard let nodes = try? document.resolvedNodes(at:time) else { return }
        let ids = Set(nodes.map(\.id)); CATransaction.begin(); CATransaction.setDisableActions(true)
        for id in Array(nodeLayers.keys) where !ids.contains(id) { nodeLayers.removeValue(forKey:id)?.removeFromSuperlayer(); originals.removeValue(forKey:id) }
        for node in nodes where node.kind != .mesh {
            let target:CALayer
            if let retained = nodeLayers[node.id] { target = retained }
            else {
                target = node.kind == .text ? CATextLayer() : node.kind == .group ? CALayer() : CAShapeLayer()
                target.contentsScale = window?.backingScaleFactor ?? 2; nodeLayers[node.id] = target
                content.addSublayer(target)
                if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                    let animation = CABasicAnimation(keyPath:"opacity"); animation.fromValue = 0; animation.toValue = node.opacity; animation.duration = 0.3; target.add(animation,forKey:"appear")
                }
            }
            let parent = node.parentID.flatMap { nodeLayers[$0] } ?? content
            if target.superlayer !== parent { parent.addSublayer(target) }
            if originals[node.id] != node {
                target.anchorPoint = CGPoint(x:0.5,y:0.5); let measured = node.kind == .text ? NSString(string:node.text).boundingRect(with:NSSize(width:max(node.width,100),height:10000),options:[.usesLineFragmentOrigin,.usesFontLeading],attributes:[.font:NSFont.systemFont(ofSize:node.fontSize)]) : .zero
                let effectiveHeight = node.kind == .text ? max(node.height,ceil(measured.height)+6) : node.height
                target.bounds = CGRect(x:0,y:0,width:node.width,height:effectiveHeight)
                target.position = CGPoint(x:node.x+node.width/2,y:node.y+effectiveHeight/2)
                target.setAffineTransform(CGAffineTransform(rotationAngle:node.rotation * .pi/180).scaledBy(x:node.scaleX,y:node.scaleY))
                target.opacity = Float(node.opacity)
                if let textLayer = target as? CATextLayer {
                    textLayer.string = node.text; textLayer.font = NSFont.systemFont(ofSize:node.fontSize,weight:node.fontSize >= 24 ? .semibold : .regular)
                    textLayer.fontSize = node.fontSize; textLayer.foregroundColor = NSColor(sceneHex:node.color).cgColor
                    textLayer.isWrapped = true; textLayer.truncationMode = .end; textLayer.alignmentMode = .left
                } else if let shape = target as? CAShapeLayer {
                    shape.strokeColor = NSColor(sceneHex:node.color).cgColor; shape.fillColor = NSColor(sceneHex:node.fill).cgColor
                    shape.lineWidth = node.strokeWidth; shape.lineCap = .round; shape.lineJoin = .round
                    shape.path = makePath(node)
                }
                originals[node.id] = node
            }
            target.borderWidth = node.id == selectedID ? 1.5 : 0; target.borderColor = NSColor.systemBlue.cgColor
        }
        renderMeshes(nodes.filter { $0.kind == .mesh }); CATransaction.commit(); applyLayout()
        setAccessibilityValue(document.title + ". " + nodes.filter { !$0.text.isEmpty }.map(\.text).joined(separator:". "))
    }
    private func makePath(_ node:SceneNode) -> CGPath {
        let path = CGMutablePath()
        switch node.kind {
        case .rectangle: path.addRoundedRect(in:CGRect(x:0,y:0,width:node.width,height:node.height),cornerWidth:10,cornerHeight:10)
        case .ellipse: path.addEllipse(in:CGRect(x:0,y:0,width:node.width,height:node.height))
        case .line,.arrow,.path:
            let paths = node.subpaths.isEmpty ? [node.points] : node.subpaths
            for points in paths {
                if let first = points.first { path.move(to:CGPoint(x:first.x,y:first.y)); for point in points.dropFirst() { path.addLine(to:CGPoint(x:point.x,y:point.y)) } }
                if node.kind == .arrow, points.count >= 2 {
                    let end = points[points.count-1], before = points[points.count-2]; let angle = atan2(end.y-before.y,end.x-before.x)
                    for direction in [-1.0,1.0] { path.move(to:CGPoint(x:end.x,y:end.y)); path.addLine(to:CGPoint(x:end.x-13*cos(angle+direction*0.4),y:end.y-13*sin(angle+direction*0.4))) }
                }
            }
        default: break
        }
        return path
    }
    private func renderMeshes(_ nodes:[SceneNode]) {
        guard !nodes.isEmpty else { stage?.removeFromSuperview(); stage = nil; meshNodes.removeAll(); return }
        if stage == nil {
            let view = SCNView(frame:bounds,options:[SCNView.Option.preferredRenderingAPI.rawValue:SCNRenderingAPI.metal.rawValue]); view.scene = SCNScene(); view.allowsCameraControl = true; view.autoenablesDefaultLighting = true; view.backgroundColor = .clear
            let camera = SCNNode(); camera.camera = SCNCamera(); camera.position = SCNVector3(0,1.5,9); view.scene?.rootNode.addChildNode(camera); view.pointOfView = camera
            addSubview(view); stage = view
        }
        let ids = Set(nodes.map(\.id)); for id in Array(meshNodes.keys) where !ids.contains(id) { meshNodes.removeValue(forKey:id)?.removeFromParentNode() }
        for source in nodes {
            let key = "\(source.text):\(source.width):\(source.height)"
            let geometry:SCNGeometry
            if let cached = geometryCache[key] { geometry = cached }
            else { geometry = source.text.lowercased().contains("sphere") ? SCNSphere(radius:max(0.05,source.width/200)) : source.text.lowercased().contains("cylinder") ? SCNCylinder(radius:max(0.05,source.width/200),height:max(0.05,source.height/100)) : SCNBox(width:max(0.05,source.width/100),height:max(0.05,source.height/100),length:0.35,chamferRadius:0.04); geometryCache[key] = geometry }
            let node = meshNodes[source.id] ?? SCNNode(geometry:geometry)
            if meshNodes[source.id] == nil { meshNodes[source.id] = node; stage?.scene?.rootNode.addChildNode(node); node.geometry = geometry.copy() as? SCNGeometry }
            node.position = SCNVector3(Float((source.x-document.width/2)/100),Float((document.height/2-source.y)/100),0)
            node.eulerAngles = SCNVector3(0,Float(source.rotation * .pi/180),0); node.opacity = CGFloat(source.opacity)
            node.geometry?.firstMaterial?.diffuse.contents = NSColor(sceneHex:source.fill == "transparent" ? source.color : source.fill)
        }
    }
    override func mouseDown(with event:NSEvent) {
        let point = convert(event.locationInWindow,from:nil); let local = CGPoint(x:(point.x-content.position.x)/ratio,y:point.y/ratio)
        let match = document.nodes.reversed().first { node in node.kind != .group && CGRect(x:node.x,y:node.y,width:max(node.width,15),height:max(node.height,15)).contains(local) }
        onSelect?(match?.id); selection = match?.id; dragStart = local; nodeStart = match.map { CGPoint(x:$0.x,y:$0.y) }
    }
    override func mouseDragged(with event:NSEvent) {
        guard let selection, let start = dragStart, let original = nodeStart else { return }
        let point = convert(event.locationInWindow,from:nil)
        onMove?(selection,max(0,min(document.width-10,original.x+(point.x-content.position.x)/ratio-start.x)),max(0,min(document.height-10,original.y+point.y/ratio-start.y)))
    }
    func pdfData() -> Data { dataWithPDF(inside:bounds) }
}
