import AppKit
import Carbon
import QuartzCore
import SwiftUI

final class AnnotationPanel: NSPanel {
  override var canBecomeKey: Bool { false }
  override var canBecomeMain: Bool { false }
}

/// Content-free observation of an existing mark, not WindowServer visibility
/// evidence. The host token and model turn generation are separate authorities.
struct GuidanceMarkPresentation: Codable, Sendable {
  let id: UUID
  let hostGeneration: UInt64
  let ownerGeneration: UInt64?
  let frameID: UUID
  let evidenceRevision: UInt64
  let displayID: UInt32
  let foregroundPID: Int32
  let windowID: UInt32?
  let sourceRect: CGRect
  let targetRect: CGRect
  let shape: String
  let createdAt: TimeInterval
  let expiresAt: TimeInterval
  let panelFrame: CGRect
  let panelVisible: Bool
  let panelAlpha: Double
  let panelIgnoresMouseEvents: Bool
  let panelHidesOnDeactivate: Bool
  let panelCanBecomeKey: Bool
  let panelIsKey: Bool
  let viewMounted: Bool
  let viewHidden: Bool
  let rootHidden: Bool
  let rootOpacity: Double
  let outlineHidden: Bool
  let outlineOpacity: Double
  let outlineStrokeEnd: Double
  let outlinePathBounds: CGRect
  let outlineLineWidth: Double
  let outlineDashed: Bool
  let presentationOutlineAvailable: Bool
  let presentationOutlineHidden: Bool?
  let presentationOutlineOpacity: Double?
  let presentationOutlineStrokeEnd: Double?
  let labelFrame: CGRect
  let labelHidden: Bool
  let presentationLabelOpacity: Double?
}

/// A bounded render of the retained annotation's model layers only. It contains
/// no underlying window pixels, capture evidence, OCR or serialized label text.
struct GuidanceMarkRaster {
  let image: CGImage
  let localBounds: CGRect
  let scale: Double

  @MainActor static func render(view: GuidanceAnnotationView) throws -> Self {
    guard let root = view.layer,
      let outline = root.sublayers?.first(where: { $0.name == "guidance.outline" })
        as? CAShapeLayer,
      let path = outline.path,
      let label = root.sublayers?.first(where: { $0.name == "guidance.label" })
    else { throw ProviderError.message("The retained guidance layers were unavailable.") }
    var region = path.boundingBoxOfPath.insetBy(dx: -14, dy: -14)
    if !label.isHidden { region = region.union(label.frame.insetBy(dx: -12, dy: -12)) }
    region = region.integral.intersection(view.bounds)
    guard [region.minX, region.minY, region.width, region.height].allSatisfy({ $0.isFinite }),
      region.width > 0, region.height > 0, region.width <= 4_096, region.height <= 4_096
    else { throw ProviderError.message("The own-mark render exceeded its geometry budget.") }
    let nativeScale = view.window?.backingScaleFactor ?? 1
    guard nativeScale.isFinite, nativeScale > 0 else {
      throw ProviderError.message("The own-mark backing scale was unavailable.")
    }
    let scale = min(2, max(1, nativeScale))
    let width = Int(ceil(region.width * scale))
    let height = Int(ceil(region.height * scale))
    guard width > 0, height > 0, width <= 8_192, height <= 8_192,
      width * height <= 2_000_000,
      let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue
          | CGImageAlphaInfo.premultipliedLast.rawValue)
    else { throw ProviderError.message("The own-mark bitmap exceeded its pixel budget.") }
    // Match the flipped annotation view. Pixel-row mapping is also recorded by
    // the acceptance oracle; no synthetic replacement mark is rendered here.
    context.scaleBy(x: scale, y: scale)
    context.translateBy(x: -region.minX, y: region.maxY)
    context.scaleBy(x: 1, y: -1)
    root.displayIfNeeded()
    root.render(in: context)
    guard let image = context.makeImage() else {
      throw ProviderError.message("The retained own-mark render failed.")
    }
    return Self(image: image, localBounds: region, scale: Double(scale))
  }
}

@MainActor final class OverlayHost {
  private struct Mark {
    let id: UUID
    let panel: NSPanel
    let evidence: ScreenEvidenceIdentity
    let ownerGeneration: UInt64?
    let hostGeneration: UInt64
    let targetRect: CGRect
    let shape: String
    let createdAt: TimeInterval
    let expiresAt: TimeInterval
  }
  private var marks: [Mark] = []
  private var expiry: Task<Void, Never>?
  private var evidenceIdentity: ScreenEvidenceIdentity?
  private var generation: UInt64 = 0

  func clear() {
    generation &+= 1
    expiry?.cancel()
    expiry = nil
    marks.forEach { Self.remove($0.panel) }
    marks.removeAll()
    evidenceIdentity = nil
  }

  func show(
    target: ProviderTarget, evidence: ScreenEvidence, showInstruction: Bool = true,
    append: Bool = false, lifetime: TimeInterval = 45, introDelay: TimeInterval = 0,
    ownerGeneration: UInt64? = nil
  ) throws {
    guard lifetime.isFinite, lifetime > 0, introDelay.isFinite, introDelay >= 0, introDelay <= 2
    else {
      throw ProviderError.message("Screen guidance timing was invalid.")
    }
    let shape = try validatedShape(target: target, evidence: evidence)
    let now = ProcessInfo.processInfo.systemUptime
    let display = evidence.screenRect
    let identity = ScreenEvidenceIdentity(evidence)
    if !append || evidenceIdentity != identity { clear() }
    evidenceIdentity = identity
    // Sequential targets from the same captured scene can remain together.
    // Each mark retains its own deadline, so appending never extends old marks.
    while marks.count >= 8 { Self.remove(marks.removeFirst().panel) }
    let panel = Self.makePanel(display: display)
    let proposed = CGRect(
      x: target.x * display.width, y: target.y * display.height,
      width: target.width * display.width, height: target.height * display.height)
    let rect = proposed.intersection(CGRect(origin: .zero, size: display.size))
    let annotation = GuidanceAnnotationView(
      frame: CGRect(origin: .zero, size: display.size), target: rect, shape: shape,
      text: GuidanceAnnotationLayout.labelText(target: target, showInstruction: showInstruction),
      reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
    panel.contentView = annotation
    panel.orderFrontRegardless()
    annotation.animateAppearance(introDelay: introDelay)
    marks.append(
      Mark(
        id: UUID(), panel: panel, evidence: identity, ownerGeneration: ownerGeneration,
        hostGeneration: generation, targetRect: rect, shape: shape.rawValue,
        createdAt: now, expiresAt: now + min(45, lifetime)))
    guard expiry == nil else { return }
    let token = generation
    let foregroundPID = evidence.foregroundPID
    expiry = Task { @MainActor [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: .milliseconds(250))
        guard !Task.isCancelled, let self, self.generation == token else { return }
        if NSWorkspace.shared.frontmostApplication?.processIdentifier != foregroundPID {
          self.clear()
          return
        }
        let currentTime = ProcessInfo.processInfo.systemUptime
        self.marks.removeAll { mark in
          guard mark.expiresAt <= currentTime else { return false }
          Self.remove(mark.panel)
          return true
        }
        if self.marks.isEmpty {
          self.clear()
          return
        }
      }
    }
  }

  /// This getter only inspects retained own-window/layer state; it never orders
  /// a window, changes animations, captures a display or refreshes evidence.
  var presentationDiagnostics: [GuidanceMarkPresentation] {
    marks.map { mark in
      let panel = mark.panel
      let view = panel.contentView as? GuidanceAnnotationView
      let root = view?.layer
      let outline = root?.sublayers?.first { $0.name == "guidance.outline" } as? CAShapeLayer
      let presented = outline?.presentation()
      let label = root?.sublayers?.first { $0.name == "guidance.label" }
      func finite(_ value: Double) -> Double { value.isFinite ? value : 0 }
      return GuidanceMarkPresentation(
        id: mark.id, hostGeneration: mark.hostGeneration, ownerGeneration: mark.ownerGeneration,
        frameID: mark.evidence.frameID, evidenceRevision: mark.evidence.revision,
        displayID: mark.evidence.displayID, foregroundPID: mark.evidence.foregroundPID,
        windowID: mark.evidence.windowID, sourceRect: mark.evidence.screenRect,
        targetRect: mark.targetRect, shape: mark.shape,
        createdAt: mark.createdAt, expiresAt: mark.expiresAt,
        panelFrame: panel.frame, panelVisible: panel.isVisible,
        panelAlpha: finite(Double(panel.alphaValue)),
        panelIgnoresMouseEvents: panel.ignoresMouseEvents,
        panelHidesOnDeactivate: panel.hidesOnDeactivate,
        panelCanBecomeKey: panel.canBecomeKey, panelIsKey: panel.isKeyWindow,
        viewMounted: view?.window === panel, viewHidden: view?.isHiddenOrHasHiddenAncestor ?? true,
        rootHidden: root?.isHidden ?? true, rootOpacity: finite(Double(root?.opacity ?? 0)),
        outlineHidden: outline?.isHidden ?? true,
        outlineOpacity: finite(Double(outline?.opacity ?? 0)),
        outlineStrokeEnd: finite(Double(outline?.strokeEnd ?? 0)),
        outlinePathBounds: outline?.path?.boundingBoxOfPath ?? .zero,
        outlineLineWidth: finite(Double(outline?.lineWidth ?? 0)),
        outlineDashed: !(outline?.lineDashPattern?.isEmpty ?? true),
        presentationOutlineAvailable: presented != nil,
        presentationOutlineHidden: presented?.isHidden,
        presentationOutlineOpacity: presented.map { finite(Double($0.opacity)) },
        presentationOutlineStrokeEnd: presented.map { finite(Double($0.strokeEnd)) },
        labelFrame: label?.frame ?? .zero, labelHidden: label?.isHidden ?? true,
        presentationLabelOpacity: (label?.presentation()).map { finite(Double($0.opacity)) })
    }
  }

  func renderMark(id: UUID) throws -> GuidanceMarkRaster {
    guard let mark = marks.first(where: { $0.id == id }),
      let view = mark.panel.contentView as? GuidanceAnnotationView, view.window === mark.panel
    else { throw ProviderError.message("The requested guidance mark is no longer mounted.") }
    return try GuidanceMarkRaster.render(view: view)
  }

  static func makePanel(display: CGRect) -> AnnotationPanel {
    let panel = AnnotationPanel(
      contentRect: display, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered,
      defer: false)
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = false
    panel.ignoresMouseEvents = true
    panel.hidesOnDeactivate = false
    panel.isReleasedWhenClosed = false
    panel.level = .floating
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    return panel
  }

  func validate(target: ProviderTarget, evidence: ScreenEvidence) throws {
    _ = try validatedShape(target: target, evidence: evidence)
  }

  private func validatedShape(
    target: ProviderTarget, evidence: ScreenEvidence
  ) throws -> GuidanceAnnotationView.Shape {
    let age = ProcessInfo.processInfo.systemUptime - evidence.capturedAt
    let display = evidence.screenRect
    let shapeName = target.shape ?? GuidanceAnnotationView.Shape.roundedRectangle.rawValue
    guard target.x.isFinite, target.y.isFinite, target.width.isFinite, target.height.isFinite,
      target.x >= 0, target.y >= 0, target.width > 0, target.height > 0,
      target.x + target.width <= 1.001, target.y + target.height <= 1.001,
      display.minX.isFinite, display.minY.isFinite,
      display.width.isFinite, display.height.isFinite,
      display.width > 0, display.height > 0, display.width <= 100_000, display.height <= 100_000,
      age.isFinite, age >= 0, age < 15,
      let shape = GuidanceAnnotationView.Shape(rawValue: shapeName),
      NSWorkspace.shared.frontmostApplication?.processIdentifier == evidence.foregroundPID
    else {
      throw ProviderError.message(
        "Screen target expired or was invalid. Capture again to refresh guidance.")
    }
    return shape
  }

  private static func remove(_ panel: NSPanel) {
    panel.orderOut(nil)
    panel.contentView = nil
  }
}
struct HotkeyRegistrationError: Error, Equatable, LocalizedError {
  let status: OSStatus
  let operation: String
  var errorDescription: String? {
    if status == OSStatus(eventHotKeyExistsErr) {
      return
        "This shortcut is already used by another app. Choose another combination (OSStatus \(status))."
    }
    return
      "Could not \(operation) (OSStatus \(status)). Use the companion menu or choose another shortcut."
  }
}

@MainActor final class HotkeyService {
  private var hotkey: EventHotKeyRef?
  private var handler: EventHandlerRef?
  private var callback: (() -> Void)?
  private static var nextID: UInt32 = 1
  private let identifier: UInt32
  private var registeredKeyCode: UInt32?
  private var registeredModifiers: UInt32?
  init() {
    identifier = Self.nextID
    Self.nextID += 1
  }
  @discardableResult func register(
    keyCode: UInt32 = UInt32(kVK_Space), modifiers: UInt32 = UInt32(cmdKey | shiftKey),
    action: @escaping () -> Void
  ) -> Result<Void, HotkeyRegistrationError> {
    if hotkey != nil, registeredKeyCode == keyCode, registeredModifiers == modifiers {
      callback = action
      return .success(())
    }
    var spec = EventTypeSpec(
      eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
    let pointer = Unmanaged.passUnretained(self).toOpaque()
    let hadHandler = handler != nil
    if !hadHandler {
      let status = InstallEventHandler(
        GetApplicationEventTarget(),
        { _, event, userData in
          guard let userData, let event else { return OSStatus(eventNotHandledErr) }
          let service = Unmanaged<HotkeyService>.fromOpaque(userData).takeUnretainedValue()
          var received = EventHotKeyID()
          guard
            GetEventParameter(
              event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
              nil,
              MemoryLayout<EventHotKeyID>.size, nil, &received) == noErr
          else { return OSStatus(eventNotHandledErr) }
          let matches = MainActor.assumeIsolated {
            received.signature == 0x4F43_4F4D && received.id == service.identifier
          }
          guard matches else { return OSStatus(eventNotHandledErr) }
          MainActor.assumeIsolated { service.callback?() }
          return noErr
        }, 1, &spec, pointer, &handler)
      guard status == noErr, handler != nil else {
        if let handler { RemoveEventHandler(handler) }
        handler = nil
        return .failure(
          .init(
            status: status == noErr ? OSStatus(paramErr) : status,
            operation: "install the shortcut handler"))
      }
    }
    let identifier = EventHotKeyID(signature: 0x4F43_4F4D, id: identifier)
    var replacement: EventHotKeyRef?
    let status = RegisterEventHotKey(
      keyCode, modifiers, identifier, GetApplicationEventTarget(), 0, &replacement)
    guard status == noErr, let replacement else {
      if !hadHandler, let handler {
        RemoveEventHandler(handler)
        self.handler = nil
      }
      return .failure(
        .init(
          status: status == noErr ? OSStatus(paramErr) : status,
          operation: "register the global shortcut"))
    }
    if let hotkey { UnregisterEventHotKey(hotkey) }
    hotkey = replacement
    registeredKeyCode = keyCode
    registeredModifiers = modifiers
    callback = action
    return .success(())
  }
  func unregister() {
    if let hotkey { UnregisterEventHotKey(hotkey) }
    if let handler { RemoveEventHandler(handler) }
    hotkey = nil
    handler = nil
    callback = nil
    registeredKeyCode = nil
    registeredModifiers = nil
  }
}
struct CompanionBadge: View {
  let state: String
  var body: some View {
    HStack(spacing: 10) {
      Image(
        systemName: state == "Listening"
          ? "waveform" : state == "Speaking" ? "speaker.wave.2.fill" : "sparkle"
      ).font(.system(size: 20, weight: .medium)).foregroundStyle(.blue)
      Text(state).font(.system(size: 13, weight: .medium))
      Text("⌘⇧Space").font(.system(size: 10)).foregroundStyle(.secondary)
    }.padding(.horizontal, 15).padding(.vertical, 11).background(.regularMaterial, in: Capsule())
      .overlay(Capsule().stroke(.white.opacity(0.65)))
  }
}
