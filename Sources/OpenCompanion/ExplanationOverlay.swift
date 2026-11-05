import AppKit
import Combine
import CompanionCore
import SwiftUI

struct ExplanationOverlayFrames: Sendable, Equatable {
  let stage: CGRect
  let clear: CGRect
}

struct ExplanationOverlayAvailability: Sendable {
  var awake = true
  var sessionActive = true
  var canPresent: Bool { awake && sessionActive }
}

enum ExplanationOverlayLayout {
  static let maximumStageSize = CGSize(width: 620, height: 420)
  static let clearSize = CGSize(width: 74, height: 32)

  static func frames(documentSize: CGSize, visibleFrame: CGRect) -> ExplanationOverlayFrames? {
    guard documentSize.width.isFinite, documentSize.height.isFinite,
      documentSize.width > 0, documentSize.height > 0,
      visibleFrame.origin.x.isFinite, visibleFrame.origin.y.isFinite,
      visibleFrame.size.width.isFinite, visibleFrame.size.height.isFinite,
      visibleFrame.size.width >= 180, visibleFrame.size.height >= 180,
      visibleFrame.maxX.isFinite, visibleFrame.maxY.isFinite
    else { return nil }
    let available = CGSize(
      width: min(maximumStageSize.width, visibleFrame.width - 40),
      height: min(maximumStageSize.height, visibleFrame.height - 88))
    let scale = min(available.width / documentSize.width, available.height / documentSize.height)
    let size = CGSize(width: documentSize.width * scale, height: documentSize.height * scale)
    guard size.width.isFinite, size.height.isFinite, size.width >= 1, size.height >= 1 else {
      return nil
    }
    let stage = CGRect(
      x: visibleFrame.maxX - size.width - 20, y: visibleFrame.minY + 24,
      width: size.width, height: size.height)
    let clear = CGRect(
      x: min(
        max(stage.midX - clearSize.width / 2, visibleFrame.minX + 8),
        visibleFrame.maxX - clearSize.width - 8),
      y: min(stage.maxY + 10, visibleFrame.maxY - clearSize.height - 8),
      width: clearSize.width, height: clearSize.height)
    return ExplanationOverlayFrames(stage: stage, clear: clear)
  }
}

/// Generated visuals use a completely click-through native window. The only
/// interactive window is the tightly bounded Clear pill. No pointer polling,
/// event reposting, desktop capture, or transparent hit-test inference is used.
@MainActor final class ExplanationOverlay {
  private weak var model: AppModel?
  private let onClear: @MainActor () -> Void
  private var visualPanel: AnnotationPanel?
  private var clearPanel: AnnotationPanel?
  private var canvas: RetainedCanvasView?
  private var subscriptions = Set<AnyCancellable>()
  private var refreshScheduled = false
  private var availability = ExplanationOverlayAvailability()
  private var displayID: CGDirectDisplayID?
  private(set) var documentID: String?
  private(set) var presentationLease: UUID?

  init(model: AppModel, onClear: @escaping @MainActor () -> Void) {
    self.model = model
    self.onClear = onClear
    model.objectWillChange.sink { [weak self] in
      MainActor.assumeIsolated { self?.scheduleRefresh() }
    }.store(in: &subscriptions)
    NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
      .sink { [weak self] _ in MainActor.assumeIsolated { self?.dismiss() } }
      .store(in: &subscriptions)
    let center = NSWorkspace.shared.notificationCenter
    for event in [
      NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification,
    ] {
      center.publisher(for: event).sink { [weak self] _ in
        MainActor.assumeIsolated {
          guard let self else { return }
          if event == NSWorkspace.willSleepNotification {
            self.availability.awake = false
          } else {
            self.availability.sessionActive = false
          }
          self.dismiss()
        }
      }.store(in: &subscriptions)
    }
    for event in [NSWorkspace.didWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
      center.publisher(for: event).sink { [weak self] _ in
        MainActor.assumeIsolated {
          guard let self else { return }
          if event == NSWorkspace.didWakeNotification {
            self.availability.awake = true
          } else {
            self.availability.sessionActive = true
          }
        }
      }.store(in: &subscriptions)
    }
  }

  func isVisible(documentID: String) -> Bool {
    self.documentID == documentID && visualPanel?.isVisible == true && canvas != nil
  }

  func show(document: SceneDocument, on screen: NSScreen) {
    dismiss()
    guard availability.canPresent else { return }
    documentID = document.id
    presentationLease = UUID()
    displayID =
      (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    // The first streamed scene unit can contain an empty assembly group. Arm
    // observation, but expose neither an empty stage nor a Clear-only window.
    guard Self.hasRenderableContent(document) else { return }
    mount(document: document, on: screen)
  }

  private func mount(document: SceneDocument, on screen: NSScreen) {
    guard availability.canPresent, let lease = presentationLease,
      let frames = ExplanationOverlayLayout.frames(
        documentSize: CGSize(width: document.width, height: document.height),
        visibleFrame: screen.visibleFrame)
    else { return }
    let view = RetainedCanvasView(frame: CGRect(origin: .zero, size: frames.stage.size))
    view.presentation = .passiveOverlay
    let visual = Self.makeVisualPanel(frame: frames.stage, canvas: view)
    let clear = Self.makeClearPanel(frame: frames.clear) { [weak self] in
      self?.clearPresentation(lease: lease, documentID: document.id)
    }
    canvas = view
    visualPanel = visual
    clearPanel = clear
    refresh()
    visual.orderFrontRegardless()
    clear.orderFrontRegardless()
    // Visibility starts the native clock only after the view is on screen.
    refresh()
  }

  func dismiss() {
    documentID = nil
    presentationLease = nil
    displayID = nil
    canvas?.onTimeChange = nil
    canvas?.stopDisplayLink()
    canvas = nil
    for panel in [visualPanel, clearPanel].compactMap({ $0 }) {
      panel.orderOut(nil)
      panel.contentView = nil
      panel.close()
    }
    visualPanel = nil
    clearPanel = nil
  }

  func shutdown() {
    subscriptions.removeAll()
    dismiss()
  }

  func clearPresentation(lease: UUID, documentID: String) {
    guard presentationLease == lease, self.documentID == documentID else { return }
    dismiss()
    onClear()
  }

  static func makeVisualPanel(frame: CGRect, canvas: RetainedCanvasView) -> AnnotationPanel {
    canvas.presentation = .passiveOverlay
    let panel = basePanel(frame: frame)
    panel.title = "OpenCompanion Explanation"
    panel.identifier = NSUserInterfaceItemIdentifier("org.opencompanion.explanation.visual")
    panel.ignoresMouseEvents = true
    panel.contentView = canvas
    return panel
  }

  static func makeClearPanel(frame: CGRect, action: @escaping @MainActor () -> Void)
    -> AnnotationPanel
  {
    let panel = basePanel(frame: frame)
    panel.title = "Clear explanation"
    panel.identifier = NSUserInterfaceItemIdentifier("org.opencompanion.explanation.clear")
    panel.ignoresMouseEvents = false
    panel.contentView = NSHostingView(rootView: ExplanationClearButton(clear: action))
    return panel
  }

  private static func basePanel(frame: CGRect) -> AnnotationPanel {
    let panel = AnnotationPanel(
      contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered,
      defer: false)
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = false
    panel.hidesOnDeactivate = false
    panel.isReleasedWhenClosed = false
    panel.level = .floating
    panel.sharingType = .none
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    return panel
  }

  private func scheduleRefresh() {
    guard documentID != nil, !refreshScheduled else { return }
    refreshScheduled = true
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      self.refreshScheduled = false
      self.refresh()
    }
  }

  private func refresh() {
    guard let documentID, let model, let document = model.scene else { return }
    guard document.id == documentID else {
      dismiss()
      return
    }
    guard let canvas else {
      if Self.hasRenderableContent(document),
        let screen = NSScreen.screens.first(where: {
          ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
            == displayID
        })
      {
        mount(document: document, on: screen)
      }
      return
    }
    canvas.onTimeChange = { [weak model] time in model?.playTime = time }
    canvas.configureClock(
      documentID: document.id, time: model.playTime,
      playing: model.playing && !document.animations.isEmpty,
      speed: model.speed, seekRevision: model.seekRevision)
    canvas.render(
      document, time: canvas.currentTime, selectedID: nil,
      presentationGeneration: model.taskGeneration)
  }

  static func hasRenderableContent(_ document: SceneDocument) -> Bool {
    document.nodes.contains { node in
      switch node.kind {
      case .group: return false
      case .mesh: return node.spatial3D?.geometry != nil || node.spatial3D == nil
      case .text: return node.spatial3D?.labelAnchor == nil && !node.text.isEmpty
      case .path, .line, .arrow:
        return node.points.count >= 2 || node.subpaths.contains { $0.count >= 2 }
      case .rectangle, .ellipse: return node.width > 0 && node.height > 0
      }
    }
  }
}

private struct ExplanationClearButton: View {
  let clear: @MainActor () -> Void
  var body: some View {
    Button(action: clear) {
      HStack(spacing: 5) {
        Image(systemName: "xmark").font(.system(size: 9, weight: .semibold))
        Text("Clear").font(.system(size: 12, weight: .medium, design: .rounded))
      }.foregroundStyle(Color(white: 0.18)).frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(white: 0.96).opacity(0.96), in: Capsule())
    }.buttonStyle(.plain).accessibilityLabel("Clear explanation")
      .accessibilityHint("Stop this response and hide the visual. Keep its notebook document.")
      .accessibilityIdentifier("explanation.clear")
  }
}
