import AppKit
import Combine
import QuartzCore
import SwiftUI

enum ManualGuidanceControlsLayout {
  static let size = CGSize(width: 230, height: 54)

  static func frame(target: CGRect, visibleFrame: CGRect) -> CGRect? {
    let values = [target.origin.x, target.origin.y, target.size.width, target.size.height,
      visibleFrame.origin.x, visibleFrame.origin.y, visibleFrame.size.width, visibleFrame.size.height]
    guard values.allSatisfy({ $0.isFinite && abs($0) <= 10_000_000 }),
      target.size.width > 0, target.size.height > 0,
      target.size.width <= 100_000, target.size.height <= 100_000,
      visibleFrame.size.width >= size.width + 16,
      visibleFrame.size.height >= size.height + 16,
      visibleFrame.size.width <= 100_000, visibleFrame.size.height <= 100_000
    else { return nil }
    let safe = visibleFrame.insetBy(dx: 8, dy: 8)
    let origins = [
      CGPoint(x: target.midX - size.width / 2, y: target.minY - size.height - 14),
      CGPoint(x: target.midX - size.width / 2, y: target.maxY + 14),
      CGPoint(x: target.maxX + 14, y: target.midY - size.height / 2),
      CGPoint(x: target.minX - size.width - 14, y: target.midY - size.height / 2),
    ]
    let candidates = origins.map { origin in
      CGRect(
        x: min(max(origin.x, safe.minX), safe.maxX - size.width),
        y: min(max(origin.y, safe.minY), safe.maxY - size.height),
        width: size.width, height: size.height)
    }
    // Prefer the familiar below/above placement, then spare side space. If a
    // target fills the screen, keep the only Continue/Stop surface available.
    return candidates.first { !$0.intersects(target) } ?? candidates.first
  }
}

/// The small interactive surface is separate from click-through annotations.
/// Its nonactivating panel leaves keyboard focus in the app the user is editing.
@MainActor final class ManualGuidanceControls {
  private weak var coordinator: ScreenGuidanceCoordinator?
  private weak var model: AppModel?
  private var panel: AnnotationPanel?
  private var subscription: AnyCancellable?

  init(coordinator: ScreenGuidanceCoordinator, model: AppModel) {
    self.coordinator = coordinator
    self.model = model
    subscription = coordinator.$manualStep.sink { [weak self] step in
      MainActor.assumeIsolated { self?.present(step) }
    }
  }

  func shutdown() {
    subscription?.cancel()
    subscription = nil
    hide()
  }

  private func present(_ step: ManualGuidanceStep?) {
    hide()
    guard let step,
      NSWorkspace.shared.frontmostApplication?.processIdentifier == step.evidence.foregroundPID,
      let screen = NSScreen.screens.max(by: {
        $0.frame.intersection(step.evidence.screenRect).area
          < $1.frame.intersection(step.evidence.screenRect).area
      }), screen.frame.intersects(step.evidence.screenRect),
      let frame = ManualGuidanceControlsLayout.frame(
        target: step.targetRect, visibleFrame: screen.visibleFrame)
    else { return }
    let panel = AnnotationPanel(
      contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered,
      defer: false)
    panel.identifier = NSUserInterfaceItemIdentifier("org.opencompanion.guidance.manual")
    panel.title = "Screen guidance"
    panel.setAccessibilityLabel("Manual screen guidance controls")
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = true
    panel.hidesOnDeactivate = false
    panel.ignoresMouseEvents = false
    panel.isReleasedWhenClosed = false
    panel.level = .floating
    panel.sharingType = .none
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    panel.contentView = Self.makeContentView(
      proceed: { [weak self] in self?.coordinator?.continueManualStep(id: step.id) },
      stop: { [weak self] in
        guard self?.coordinator?.manualStep?.id == step.id else { return }
        self?.model?.stop()
      })
    self.panel = panel
    panel.alphaValue = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 1 : 0
    panel.orderFrontRegardless()
    if panel.alphaValue == 0 {
      NSAnimationContext.runAnimationGroup { context in
        context.duration = 0.18
        context.timingFunction = CAMediaTimingFunction(name: .easeOut)
        panel.animator().alphaValue = 1
      }
    }
  }

  static func makeContentView(proceed: @escaping () -> Void, stop: @escaping () -> Void) -> NSView {
    let view = ManualGuidanceHostingView(
      rootView: ManualGuidanceControlsView(proceed: proceed, stop: stop))
    view.frame = CGRect(origin: .zero, size: ManualGuidanceControlsLayout.size)
    return view
  }

  private func hide() {
    panel?.orderOut(nil)
    panel?.contentView = nil
    panel = nil
  }
}

/// These mouse controls intentionally live in a window that cannot become key.
/// Admit the first click instead of waiting for an activation click to precede it.
private final class ManualGuidanceHostingView<Content: View>: NSHostingView<Content> {
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
  override var needsPanelToBecomeKey: Bool { false }
}

extension CGRect {
  fileprivate var area: CGFloat { isNull || isInfinite ? 0 : max(0, width) * max(0, height) }
}

private struct ManualGuidanceControlsView: View {
  let proceed: () -> Void
  let stop: () -> Void
  var body: some View {
    HStack(spacing: 9) {
      Button(action: proceed) {
        HStack(spacing: 8) {
          Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold))
          Text("Done, continue").font(.system(size: 12, weight: .semibold, design: .rounded))
          Image(systemName: "arrow.right").font(.system(size: 10, weight: .semibold))
        }.foregroundStyle(Color(red: 0.18, green: 0.07, blue: 0.09))
          .frame(maxWidth: .infinity, minHeight: 34)
          .background(
            LinearGradient(
              colors: [
                Color(red: 1, green: 0.96, blue: 0.96), Color(red: 1, green: 0.69, blue: 0.72),
              ],
              startPoint: .top, endPoint: .bottom), in: Capsule())
      }.buttonStyle(.plain)
        .accessibilityLabel("Continue screen guidance")
        .accessibilityHint("Check a fresh screen after your manual step")
        .accessibilityIdentifier("guidance.continue")
      Button(action: stop) {
        Image(systemName: "xmark").font(.system(size: 10, weight: .semibold))
          .foregroundStyle(.white.opacity(0.7)).frame(width: 25, height: 30)
      }.buttonStyle(.plain).accessibilityLabel("Stop screen guidance")
        .accessibilityIdentifier("guidance.stop")
    }.padding(.horizontal, 10).padding(.vertical, 10)
      .background(Color(white: 0.045), in: RoundedRectangle(cornerRadius: 19))
      .environment(\.colorScheme, .dark)
  }
}
