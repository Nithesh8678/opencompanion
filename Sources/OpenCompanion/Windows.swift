import AppKit
import Carbon
import SwiftUI

final class AnnotationPanel: NSPanel {
  override var canBecomeKey: Bool { false }
  override var canBecomeMain: Bool { false }
}
@MainActor final class OverlayHost {
  private struct Mark {
    let panel: NSPanel
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
    append: Bool = false, lifetime: TimeInterval = 45, introDelay: TimeInterval = 0
  ) throws {
    guard lifetime.isFinite, lifetime > 0, introDelay.isFinite, introDelay >= 0, introDelay <= 2 else {
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
    let panel = AnnotationPanel(
      contentRect: display, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered,
      defer: false)
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = false
    panel.ignoresMouseEvents = true
    panel.isReleasedWhenClosed = false
    panel.level = .floating
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
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
    marks.append(Mark(panel: panel, expiresAt: now + min(45, lifetime)))
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
