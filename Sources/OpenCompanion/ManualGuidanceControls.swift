import AppKit
import Combine
import QuartzCore
import SwiftUI

enum ManualGuidanceControlsLayout {
  static let size = CGSize(width: 230, height: 54)

  static func frame(target: CGRect, visibleFrame: CGRect) -> CGRect? {
    guard target.origin.x.isFinite, target.origin.y.isFinite,
      target.width.isFinite, target.height.isFinite, target.width > 0, target.height > 0,
      visibleFrame.origin.x.isFinite, visibleFrame.origin.y.isFinite,
      visibleFrame.width.isFinite, visibleFrame.height.isFinite,
      visibleFrame.width >= size.width + 16, visibleFrame.height >= size.height + 16
    else { return nil }
    let x = min(
      max(target.midX - size.width / 2, visibleFrame.minX + 8),
      visibleFrame.maxX - size.width - 8)
    let below = target.minY - size.height - 14
    let y =
      below >= visibleFrame.minY + 8
      ? below
      : min(
        target.maxY + 14, visibleFrame.maxY - size.height - 8)
    return CGRect(x: x, y: max(visibleFrame.minY + 8, y), width: size.width, height: size.height)
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
    panel.contentView = NSHostingView(
      rootView: ManualGuidanceControlsView(
        proceed: { [weak self] in self?.coordinator?.continueManualStep(id: step.id) },
        stop: { [weak self] in
          guard self?.coordinator?.manualStep?.id == step.id else { return }
          self?.model?.stop()
        }))
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

  private func hide() {
    panel?.orderOut(nil)
    panel?.contentView = nil
    panel = nil
  }
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
