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

/// Generated visuals remain click-through until Option explicitly arms a real
/// visible mesh. During that interaction the bounded visual panel owns input;
/// no transparent-pixel mouse holes or event reposting are assumed.
@MainActor final class ExplanationOverlay {
  private weak var model: AppModel?
  private let onClear: @MainActor () -> Void
  private var visualPanel: AnnotationPanel?
  private var clearPanel: AnnotationPanel?
  private var canvas: RetainedCanvasView?
  private var orbitController: ExplanationOrbitController?
  private var orbitHint: NSTextField?
  private let observeOrbitInput: Bool
  private var subscriptions = Set<AnyCancellable>()
  private var refreshScheduled = false
  private var availability = ExplanationOverlayAvailability()
  private var displayID: CGDirectDisplayID?
  private(set) var documentID: String?
  private(set) var presentationLease: UUID?
  private struct NarratedFocus {
    let context: VoiceNarrationContext
    let authority: SceneFocusAuthority
  }
  private var narratedFocus: NarratedFocus?
  var onSceneFocusPoint: ((SceneFocusAuthority, CGPoint) -> Void)?
  var onSceneFocusEnded: ((SceneFocusAuthority) -> Void)?

  init(
    model: AppModel, observeOrbitInput: Bool = true,
    onClear: @escaping @MainActor () -> Void
  ) {
    self.model = model
    self.observeOrbitInput = observeOrbitInput
    self.onClear = onClear
    model.objectWillChange.sink { [weak self] in
      MainActor.assumeIsolated { self?.scheduleRefresh() }
    }.store(in: &subscriptions)
    NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
      .sink { [weak self] _ in
        MainActor.assumeIsolated {
          self?.revokeUnavailableSurface()
          self?.dismiss()
        }
      }
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
          self.revokeUnavailableSurface()
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
    view.onSceneFocusProjectionChanged = { [weak self] projection in
      self?.publishSceneFocus(projection)
    }
    let hint = NSTextField(labelWithString: "⌥ Drag to rotate")
    hint.font = .systemFont(ofSize: 11, weight: .medium)
    hint.textColor = .white
    hint.backgroundColor = NSColor.black.withAlphaComponent(0.82)
    hint.drawsBackground = true
    hint.alignment = .center
    hint.wantsLayer = true
    hint.layer?.cornerRadius = 9
    hint.layer?.masksToBounds = true
    hint.layer?.zPosition = 2_000_000
    hint.frame = CGRect(x: 12, y: 12, width: 128, height: 25)
    hint.isHidden = true
    hint.setAccessibilityIdentifier("explanation.orbit.hint")
    view.addSubview(hint)
    orbitHint = hint
    view.setAccessibilityHelp(
      "Hold Option over a visible 3D part, then drag to rotate. Release Option to finish. Control and Option starts voice."
    )
    orbitController = ExplanationOrbitController(
      canvas: view, panel: visual, observeInput: observeOrbitInput,
      authority: { [weak self] in self?.orbitAuthority() },
      available: { [weak self] in
        guard let self, let model = self.model else { return false }
        return self.availability.canPresent && !model.listening && !model.pushToTalkActive
          && ![
            "Preparing microphone", "Listening", "Finishing speech",
            "Release Control+Option to send",
          ].contains(model.voiceInputState)
      },
      onPhaseChange: { [weak self] phase in
        guard let self, let hint = self.orbitHint else { return }
        if phase != .passive { self.endSceneFocus() }
        hint.stringValue = phase == .dragging ? "Rotating · release ⌥" : "⌥ Drag to rotate"
        hint.isHidden = phase == .passive
        if phase != .passive { self.canvas?.addSubview(hint, positioned: .above, relativeTo: nil) }
      })
    refresh()
    visual.orderFrontRegardless()
    clear.orderFrontRegardless()
    // Visibility starts the native clock only after the view is on screen.
    refresh()
  }

  func dismiss() {
    endSceneFocus()
    orbitController?.shutdown()
    orbitController = nil
    orbitHint = nil
    documentID = nil
    presentationLease = nil
    displayID = nil
    canvas?.onTimeChange = nil
    canvas?.onSceneFocusProjectionChanged = nil
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

  private func revokeUnavailableSurface() {
    guard let documentID else { return }
    model?.explanationSurfaceBecameUnavailable(documentID: documentID)
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

  /// Generated-scene ownership is independent of screen-guidance evidence.
  /// The model selects a part ID; only this mounted native view supplies points.
  func beginSceneFocus(context: VoiceNarrationContext, presentation: ExplanationPresentation) {
    guard context.narrationID == presentation.beatID,
      context.generation == presentation.generation,
      let focusID = presentation.focusID, let lease = presentationLease,
      let model, let canvas, visualPanel?.isVisible == true,
      canvas.renderedDocumentID == presentation.document.id,
      canvas.renderedDocumentRevision == presentation.document.revision,
      let authority = try? SceneFocusAuthority.make(
        presentationLease: lease, generation: context.generation, beatID: presentation.beatID,
        document: presentation.document, focusID: focusID),
      model.explanationFocusIsCurrent(authority), orbitController?.diagnostics.phase == "passive"
    else { return }
    if narratedFocus?.authority != authority {
      endSceneFocus()
      narratedFocus = .init(context: context, authority: authority)
    }
    let projection = canvas.focusPoint(for: focusID)
    publishSceneFocus(projection)
  }

  func endSceneFocus(context: VoiceNarrationContext? = nil) {
    guard let owned = narratedFocus, context == nil || owned.context == context else { return }
    // Revoke before callbacks or resolver cleanup, both of which may reenter.
    narratedFocus = nil
    canvas?.clearSceneFocus()
    onSceneFocusEnded?(owned.authority)
  }

  /// A cheap authority/bounds read for the cursor clock. It never captures or
  /// ray-tests; projection changes arrive from the native scene/camera clock.
  func sceneNodeVisitBounds(authority: SceneFocusAuthority) -> CGRect? {
    guard narratedFocus?.authority == authority, presentationLease == authority.presentationLease,
      availability.canPresent, let model, model.explanationFocusIsCurrent(authority),
      let visualPanel, visualPanel.isVisible, let canvas,
      let projection = canvas.currentSceneFocusProjection,
      projection.targetID == authority.focusID,
      projection.documentID == authority.documentID,
      projection.documentRevision == authority.documentRevision,
      projection.generation == authority.generation,
      orbitController?.diagnostics.phase == "passive"
    else { return nil }
    return visualPanel.frame
  }

  private func publishSceneFocus(_ projection: SceneFocusProjection?) {
    guard let owned = narratedFocus else { return }
    guard let projection,
      sceneNodeVisitBounds(authority: owned.authority) != nil,
      projection.targetID == owned.authority.focusID,
      projection.documentID == owned.authority.documentID,
      projection.documentRevision == owned.authority.documentRevision,
      projection.generation == owned.authority.generation
    else {
      onSceneFocusEnded?(owned.authority)
      return
    }
    onSceneFocusPoint?(owned.authority, projection.globalPoint)
  }

  static func makeVisualPanel(frame: CGRect, canvas: RetainedCanvasView) -> AnnotationPanel {
    canvas.presentation = .passiveOverlay
    let panel = basePanel(frame: frame)
    panel.title = "OpenCompanion Explanation"
    panel.identifier = NSUserInterfaceItemIdentifier("org.opencompanion.explanation.visual")
    panel.ignoresMouseEvents = true
    panel.acceptsMouseMovedEvents = true
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
    guard let documentID, let model, let document = model.explanationDisplayDocument else { return }
    guard document.id == documentID else {
      dismiss()
      return
    }
    if let owned = narratedFocus, !model.explanationFocusIsCurrent(owned.authority) {
      endSceneFocus()
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
    let submitted = canvas.render(
      document, time: canvas.currentTime, selectedID: nil,
      presentationGeneration: model.taskGeneration)
    orbitController?.refresh()
    // This acknowledges native render submission on a mounted visible surface,
    // not GPU completion or acoustic playback. Do not acknowledge pre-mount.
    if submitted, visualPanel?.isVisible == true, let presentation = model.explanationPresentation,
      presentation.document == document
    {
      model.acknowledgeExplanationRenderSubmitted(presentation)
    }
  }

  private func orbitAuthority() -> ExplanationOrbitState.Authority? {
    guard let lease = presentationLease, let documentID, let displayID, let model,
      model.explanationDisplayDocument?.id == documentID,
      model.explanationDisplayDocument?.nodes.contains(where: {
        $0.kind == .mesh && $0.spatial3D?.geometry != nil
      })
        == true,
      NSScreen.screens.contains(where: {
        ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
          == displayID
      })
    else { return nil }
    return .init(
      lease: lease, documentID: documentID, generation: model.taskGeneration, displayID: displayID)
  }

  var orbitDiagnostics: ExplanationOrbitDiagnostics? { orbitController?.diagnostics }
  var orbitControllerForAcceptance: ExplanationOrbitController? {
    observeOrbitInput ? nil : orbitController
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
