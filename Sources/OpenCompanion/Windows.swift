import AppKit
import Carbon
import SwiftUI

final class AnnotationPanel: NSPanel {
  override var canBecomeKey: Bool { false }
  override var canBecomeMain: Bool { false }
}
@MainActor final class OverlayHost {
  private var panels: [NSPanel] = []
  private var expiry: Task<Void, Never>?
  func clear() {
    expiry?.cancel()
    panels.forEach { $0.orderOut(nil) }
    panels.removeAll()
  }
  func show(target: ProviderTarget, evidence: ScreenEvidence) throws {
    guard target.x.isFinite, target.y.isFinite, target.width.isFinite, target.height.isFinite,
      target.x >= 0, target.y >= 0, target.width > 0, target.height > 0,
      target.x + target.width <= 1.001, target.y + target.height <= 1.001,
      ProcessInfo.processInfo.systemUptime - evidence.capturedAt < 15,
      NSWorkspace.shared.frontmostApplication?.processIdentifier == evidence.foregroundPID
    else {
      throw ProviderError.message(
        "Screen target expired or was invalid. Capture again to refresh guidance.")
    }
    clear()
    let display = evidence.screenRect
    let panel = AnnotationPanel(
      contentRect: display, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered,
      defer: false)
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = false
    panel.ignoresMouseEvents = true
    panel.level = .floating
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    let rect = CGRect(
      x: target.x * display.width, y: target.y * display.height,
      width: target.width * display.width, height: target.height * display.height)
    panel.contentView = NSHostingView(
      rootView: AnnotationView(rect: rect, text: target.instruction))
    panel.orderFrontRegardless()
    panels.append(panel)
    expiry = Task { @MainActor [weak self] in
      for _ in 0..<30 {
        try? await Task.sleep(for: .milliseconds(250))
        guard !Task.isCancelled else { return }
        if NSWorkspace.shared.frontmostApplication?.processIdentifier != evidence.foregroundPID {
          self?.clear()
          return
        }
      }
      self?.clear()
    }
  }
}
struct AnnotationView: View {
  let rect: CGRect
  let text: String
  @Environment(\.accessibilityReduceMotion) var reduceMotion
  var body: some View {
    GeometryReader { geometry in
      ZStack(alignment: .topLeading) {
        RoundedRectangle(cornerRadius: 8).stroke(Color.blue, lineWidth: 3.5).shadow(
          color: .blue.opacity(0.5), radius: 10
        ).frame(width: rect.width, height: rect.height).offset(x: rect.minX, y: rect.minY)
        Text(text).font(.system(size: 15, weight: .semibold)).foregroundStyle(.white).padding(10)
          .background(.blue, in: RoundedRectangle(cornerRadius: 9)).frame(
            maxWidth: 330, alignment: .leading
          ).offset(x: min(rect.minX, max(0, geometry.size.width - 340)), y: max(8, rect.minY - 58))
      }
    }.allowsHitTesting(false)
  }
}
@MainActor final class HotkeyService {
  private var hotkey: EventHotKeyRef?
  private var handler: EventHandlerRef?
  private var callback: (() -> Void)?
  func register(keyCode: UInt32 = UInt32(kVK_Space), action: @escaping () -> Void) {
    unregister()
    callback = action
    var spec = EventTypeSpec(
      eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
    let pointer = Unmanaged.passUnretained(self).toOpaque()
    InstallEventHandler(
      GetApplicationEventTarget(),
      { _, _, userData in
        guard let userData else { return noErr }
        let service = Unmanaged<HotkeyService>.fromOpaque(userData).takeUnretainedValue()
        MainActor.assumeIsolated { service.callback?() }
        return noErr
      }, 1, &spec, pointer, &handler)
    let identifier = EventHotKeyID(signature: 0x4F43_4F4D, id: 1)
    RegisterEventHotKey(
      keyCode, UInt32(cmdKey | shiftKey), identifier, GetApplicationEventTarget(), 0, &hotkey)
  }
  func unregister() {
    if let hotkey { UnregisterEventHotKey(hotkey) }
    if let handler { RemoveEventHandler(handler) }
    hotkey = nil
    handler = nil
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
