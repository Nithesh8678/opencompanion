import AppKit

enum SpatialSelectionMode: String, Sendable { case region, scribble }

struct SpatialSelection: Sendable {
    /// Global AppKit screen points (bottom-left origin), suitable for capture cropping.
    let rect: CGRect
    /// Points in the selection's local top-left coordinate space, measured in logical points.
    /// Scribble mode retains the whole selected screen so strokes align with the capture.
    let strokes: [[CGPoint]]
    var normalizedStrokes: [[CGPoint]] {
        guard rect.width > 0, rect.height > 0 else { return [] }
        return strokes.map { $0.map { CGPoint(x: $0.x / rect.width, y: $0.y / rect.height) } }
    }
}

/// Explicit, temporary mouse ownership. This selector performs no screen capture.
@MainActor final class SpatialContextSelector {
    private var panel: SpatialSelectionPanel?
    private var continuation: CheckedContinuation<SpatialSelection?, Never>?
    private var activeID: UUID?
    private weak var previousKeyWindow: NSWindow?

    func choose(screen: NSScreen, mode: SpatialSelectionMode) async -> SpatialSelection? {
        finish(nil)
        guard !Task.isCancelled else { return nil }
        let requestID = UUID()
        activeID = requestID
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                previousKeyWindow = NSApp.keyWindow
                let selectionPanel = SpatialSelectionPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
                selectionPanel.isOpaque = false
                selectionPanel.backgroundColor = .clear
                selectionPanel.hasShadow = false
                selectionPanel.ignoresMouseEvents = false
                selectionPanel.hidesOnDeactivate = false
                selectionPanel.level = .screenSaver
                selectionPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
                let view = SpatialSelectionView(frame: CGRect(origin: .zero, size: screen.frame.size), screenFrame: screen.frame, mode: mode)
                view.onFinish = { [weak self] selection in
                    guard self?.activeID == requestID else { return }; self?.finish(selection)
                }
                selectionPanel.contentView = view
                panel = selectionPanel
                selectionPanel.makeKeyAndOrderFront(nil)
                selectionPanel.makeFirstResponder(view)
                view.window?.invalidateCursorRects(for: view)
                NSCursor.crosshair.set()
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard self?.activeID == requestID else { return }; self?.finish(nil)
            }
        }
    }
    func cancel() { finish(nil) }
    private func finish(_ selection: SpatialSelection?) {
        guard let continuation else { return }
        self.continuation = nil; activeID = nil
        panel?.ignoresMouseEvents = true
        panel?.orderOut(nil)
        panel?.contentView = nil
        panel?.close(); panel = nil
        NSCursor.arrow.set()
        previousKeyWindow?.makeKeyAndOrderFront(nil); previousKeyWindow = nil
        continuation.resume(returning: selection)
    }
}

@MainActor private final class SpatialSelectionPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor private final class SpatialSelectionView: NSView {
    let screenFrame: CGRect
    let mode: SpatialSelectionMode
    var onFinish: ((SpatialSelection?) -> Void)?
    private var anchor: CGPoint?
    private var region: CGRect?
    private var strokes: [[CGPoint]] = []
    private var pointCount = 0
    private let maximumPoints = 8_192
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    init(frame: CGRect, screenFrame: CGRect, mode: SpatialSelectionMode) {
        self.screenFrame = screenFrame; self.mode = mode
        super.init(frame: frame)
    }
    required init?(coder: NSCoder) { nil }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }
    override func mouseDown(with event: NSEvent) {
        let point = boundedPoint(event)
        if mode == .region { anchor = point; region = CGRect(origin: point, size: .zero) }
        else if strokes.count < 128, pointCount < maximumPoints { strokes.append([point]); pointCount += 1 }
        needsDisplay = true
    }
    override func mouseDragged(with event: NSEvent) {
        let point = boundedPoint(event)
        if mode == .region, let anchor {
            region = CGRect(x: min(anchor.x, point.x), y: min(anchor.y, point.y), width: abs(point.x - anchor.x), height: abs(point.y - anchor.y))
        } else if mode == .scribble, !strokes.isEmpty, pointCount < maximumPoints {
            let index = strokes.count - 1
            if let previous = strokes[index].last, hypot(previous.x - point.x, previous.y - point.y) >= 1.5 {
                strokes[index].append(point); pointCount += 1
            }
        }
        needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) {
        if mode == .region { mouseDragged(with: event); anchor = nil }
        if mode == .scribble, strokes.last?.count == 1 { pointCount -= 1; strokes.removeLast() }
        needsDisplay = true
    }
    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: onFinish?(nil)
        case 36, 76: complete()
        case 51, 117:
            region = nil; strokes.removeAll(); pointCount = 0; needsDisplay = true
        case 6 where event.modifierFlags.contains(.command):
            if let removed = strokes.popLast() { pointCount -= removed.count }; needsDisplay = true
        default: NSSound.beep()
        }
    }
    private func boundedPoint(_ event: NSEvent) -> CGPoint {
        let point = convert(event.locationInWindow, from: nil)
        return CGPoint(x: min(max(0, point.x), bounds.width), y: min(max(0, point.y), bounds.height))
    }
    private func complete() {
        if mode == .region {
            guard let region, region.width >= 8, region.height >= 8 else { NSSound.beep(); return }
            let global = CGRect(x: screenFrame.minX + region.minX, y: screenFrame.maxY - region.maxY, width: region.width, height: region.height)
            onFinish?(SpatialSelection(rect: global, strokes: []))
        } else {
            guard !strokes.isEmpty else { NSSound.beep(); return }
            onFinish?(SpatialSelection(rect: screenFrame, strokes: strokes))
        }
    }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.26).setFill()
        if let region, mode == .region {
            let shade = NSBezierPath(rect: bounds)
            shade.appendRect(region); shade.windingRule = .evenOdd; shade.fill()
            NSColor.white.setStroke(); let border = NSBezierPath(rect: region); border.lineWidth = 2; border.stroke()
            let sizeText = "\(Int(region.width)) × \(Int(region.height)) points"
            drawLabel(sizeText, at: CGPoint(x: region.minX + 8, y: min(bounds.height - 30, region.maxY + 8)))
        } else { bounds.fill() }
        NSColor.systemYellow.setStroke()
        for points in strokes where points.count >= 2 {
            let path = NSBezierPath(); path.move(to: points[0]); for point in points.dropFirst() { path.line(to: point) }
            path.lineWidth = 3.5; path.lineCapStyle = .round; path.lineJoinStyle = .round; path.stroke()
        }
        let title = mode == .region ? "Drag to select a region" : "Draw the area or relationship you mean"
        let instructions = "Return to attach · Escape to cancel · Delete to clear" + (mode == .scribble ? " · ⌘Z to undo" : "")
        let box = CGRect(x: max(20, bounds.midX - 240), y: 34, width: 480, height: 75)
        NSColor.windowBackgroundColor.withAlphaComponent(0.96).setFill(); NSBezierPath(roundedRect: box, xRadius: 16, yRadius: 16).fill()
        (title as NSString).draw(at: CGPoint(x: box.minX + 18, y: box.minY + 14), withAttributes: [.font: NSFont.systemFont(ofSize: 17, weight: .semibold), .foregroundColor: NSColor.labelColor])
        (instructions as NSString).draw(at: CGPoint(x: box.minX + 18, y: box.minY + 42), withAttributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.secondaryLabelColor])
    }
    private func drawLabel(_ text: String, at point: CGPoint) {
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor.white]
        let size = (text as NSString).size(withAttributes: attributes)
        NSColor.black.withAlphaComponent(0.75).setFill(); NSBezierPath(roundedRect: CGRect(origin: point, size: CGSize(width: size.width + 12, height: size.height + 8)), xRadius: 5, yRadius: 5).fill()
        (text as NSString).draw(at: CGPoint(x: point.x + 6, y: point.y + 4), withAttributes: attributes)
    }
}
