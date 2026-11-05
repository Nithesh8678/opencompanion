import AppKit
import CompanionCore
import SceneKit
import Testing

@testable import OpenCompanion

/// Synthetic, directly dispatched own-window events only. No event posting,
/// desktop capture, external keyboard permission or physical-input claim.
@Suite @MainActor struct ExplanationOrbitControllerTests {
  @Test func modifierMappingPreservesSemanticVetoesAndIgnoresHardwareSideBits() {
    let mapped = ExplanationOrbitController.modifiers([
      .option, .control, .command, .shift, .function, .capsLock, .numericPad, .help,
    ])
    #expect(
      mapped == [.option, .control, .command, .shift, .function, .capsLock, .numericPad, .help])
    let lowHardwareBit = NSEvent.ModifierFlags(rawValue: NSEvent.ModifierFlags.option.rawValue | 2)
    #expect(ExplanationOrbitController.modifiers(lowHardwareBit) == .option)
    let unknownSemanticBit = NSEvent.ModifierFlags(
      rawValue: NSEvent.ModifierFlags.option.rawValue | (1 << 24))
    #expect(ExplanationOrbitController.modifiers(unknownSemanticBit) != .option)
    #expect(ExplanationOrbitController.modifiers([]).isEmpty)
  }

  @Test func manualAdmissionKeepsDefaultAndUnavailableOrBackgroundInputPassive() throws {
    let fixture = try Harness()
    defer { fixture.close() }
    #expect(fixture.panel.ignoresMouseEvents && !fixture.canvas.overlayCameraArmed)
    #expect(!fixture.controller.diagnostics.observationAvailable)
    let point = try fixture.meshPoint()
    fixture.reconcile(point, modifiers: [])
    #expect(fixture.controller.diagnostics.phase == "passive")
    fixture.reconcile(.zero)
    #expect(fixture.panel.ignoresMouseEvents)
    fixture.available = false
    fixture.reconcile(point)
    #expect(fixture.panel.ignoresMouseEvents && !fixture.canvas.overlayCameraArmed)
    fixture.available = true
    fixture.reconcile(point, modifiers: [.option, .capsLock, .numericPad])
    #expect(fixture.controller.diagnostics.phase == "armed")
    #expect(!fixture.panel.ignoresMouseEvents && fixture.canvas.overlayCameraArmed)
    #expect(fixture.controller.diagnostics.observationAvailable)
    #expect(
      !fixture.controller.diagnostics.tapEnabled
        && fixture.controller.diagnostics.observedModifiers == 0)
    #expect(!fixture.panel.canBecomeKey && !fixture.panel.canBecomeMain)
    #expect(!fixture.canvas.acceptsFirstResponder)
    #expect(fixture.canvas.spatialStage?.allowsCameraControl == false)
  }

  @Test func localMonitorLetsOwnDownAndUpReachNativeCameraBeforeGenericReconciliation() throws {
    let originalForeground = NSWorkspace.shared.frontmostApplication?.processIdentifier
    let fixture = try Harness()
    defer { fixture.close() }
    let point = try fixture.meshPoint()
    fixture.reconcile(point)
    let stage = try #require(fixture.canvas.spatialStage)
    let camera = try #require(stage.pointOfView)
    let initialCamera = camera.simdWorldTransform
    let down = try fixture.mouse(.leftMouseDown, point: point)
    #expect(down.window === fixture.panel)
    fixture.controller.consumeLocalEvent(down)
    #expect(fixture.controller.diagnostics.phase == "armed")
    fixture.canvas.mouseDown(with: down)
    #expect(fixture.canvas.isOverlayCameraDragging)
    #expect(
      fixture.controller.diagnostics.phase == "dragging"
        && fixture.controller.diagnostics.starts == 1)
    let moved = CGPoint(x: point.x + 65, y: point.y + 18)
    let drag = try fixture.mouse(.leftMouseDragged, point: moved)
    fixture.controller.consumeLocalEvent(drag)
    fixture.canvas.mouseDragged(with: drag)
    #expect(camera.simdWorldTransform != initialCamera)
    #expect(fixture.canvas.overlayCameraDragEventCount == 1)
    // Supply a current authored pointer position for the acceptance-only path;
    // it must ray-test again at end instead of reusing a stale pre-drag hit.
    let releasePoint = try fixture.meshPoint()
    fixture.reconcile(releasePoint, buttons: .left)
    let up = try fixture.mouse(.leftMouseUp, point: releasePoint)
    fixture.controller.consumeLocalEvent(up)
    #expect(fixture.canvas.isOverlayCameraDragging)
    fixture.canvas.mouseUp(with: up)
    #expect(!fixture.canvas.isOverlayCameraDragging)
    #expect(fixture.controller.diagnostics.phase == "armed")
    #expect(fixture.controller.diagnostics.ends == 1 && fixture.controller.diagnostics.cancels == 0)
    #expect(!stage.defaultCameraController.isInertiaRunning)
    #expect(NSWorkspace.shared.frontmostApplication?.processIdentifier == originalForeground)
    #expect(fixture.document.nodes[0].spatial3D?.transform == .identity)
  }

  @Test func ownMouseUpRechecksThePointerInsteadOfRearmingFromTheOriginalMeshHit() throws {
    let fixture = try Harness()
    defer { fixture.close() }
    let point = try fixture.meshPoint()
    fixture.reconcile(point)
    fixture.canvas.mouseDown(with: try fixture.mouse(.leftMouseDown, point: point))
    #expect(fixture.canvas.isOverlayCameraDragging)
    fixture.reconcile(.zero, buttons: .left)
    #expect(fixture.canvas.isOverlayCameraDragging)
    let up = try fixture.mouse(.leftMouseUp, point: .zero)
    fixture.controller.consumeLocalEvent(up)
    fixture.canvas.mouseUp(with: up)
    #expect(fixture.controller.diagnostics.phase == "passive")
    #expect(fixture.panel.ignoresMouseEvents && !fixture.canvas.overlayCameraArmed)
    #expect(fixture.controller.diagnostics.ends == 1 && fixture.controller.diagnostics.cancels == 0)
  }

  @Test(arguments: [false, true])
  func incomingOwnDragModifierEdgesCancelBeforeCanvasDispatch(controlPressed: Bool) throws {
    let fixture = try Harness()
    defer { fixture.close() }
    let point = try fixture.meshPoint()
    fixture.reconcile(point)
    let down = try fixture.mouse(.leftMouseDown, point: point)
    fixture.controller.consumeLocalEvent(down)
    fixture.canvas.mouseDown(with: down)
    let stage = try #require(fixture.canvas.spatialStage)
    let camera = try #require(stage.pointOfView)
    let before = camera.simdWorldTransform
    let flags: NSEvent.ModifierFlags = controlPressed ? [.control, .option] : []
    let drag = try fixture.mouse(
      .leftMouseDragged, point: CGPoint(x: point.x + 50, y: point.y), flags: flags)
    fixture.controller.consumeLocalEvent(drag)
    #expect(fixture.controller.diagnostics.phase == "passive")
    #expect(fixture.panel.ignoresMouseEvents && !fixture.canvas.isOverlayCameraDragging)
    #expect(!fixture.canvas.overlayCameraArmed && fixture.controller.diagnostics.cancels == 1)
    fixture.canvas.mouseDragged(with: drag)
    #expect(camera.simdWorldTransform == before && fixture.canvas.overlayCameraDragEventCount == 0)
    #expect(!stage.defaultCameraController.isInertiaRunning)
    #expect(fixture.controller.diagnostics.observedModifiers == 0)
  }

  @Test(arguments: [false, true])
  func freshMouseDownVetoImmediatelyDisarmsAStaleLeaseOrGeneration(changeGeneration: Bool) throws {
    let fixture = try Harness()
    defer { fixture.close() }
    let point = try fixture.meshPoint()
    fixture.reconcile(point)
    let old = try #require(fixture.authority)
    fixture.authority = .init(
      lease: changeGeneration ? old.lease : UUID(), documentID: old.documentID,
      generation: changeGeneration ? old.generation + 1 : old.generation, displayID: old.displayID)
    // Do not refresh first: the actual veto must query current ownership now.
    let down = try fixture.mouse(.leftMouseDown, point: point)
    fixture.controller.consumeLocalEvent(down)
    fixture.canvas.mouseDown(with: down)
    #expect(!fixture.canvas.isOverlayCameraDragging && !fixture.canvas.overlayCameraArmed)
    #expect(fixture.panel.ignoresMouseEvents && fixture.controller.diagnostics.phase == "passive")
    #expect(
      fixture.controller.diagnostics.starts == 0 && fixture.controller.diagnostics.cancels == 0)
  }

  @Test func freshAvailabilityAndRecordedMouseDownFlagsCanVetoAnAlreadyArmedPanel() throws {
    let fixture = try Harness()
    defer { fixture.close() }
    let point = try fixture.meshPoint()
    fixture.reconcile(point)
    fixture.available = false
    fixture.canvas.mouseDown(with: try fixture.mouse(.leftMouseDown, point: point))
    #expect(fixture.panel.ignoresMouseEvents && !fixture.canvas.isOverlayCameraDragging)
    fixture.available = true
    fixture.reconcile(point)
    fixture.canvas.mouseDown(
      with: try fixture.mouse(.leftMouseDown, point: point, flags: [.option, .control]))
    #expect(fixture.panel.ignoresMouseEvents && !fixture.canvas.isOverlayCameraDragging)
    #expect(fixture.controller.diagnostics.starts == 0)
  }

  @Test func shutdownCancelsNativeGestureRestoresPassivePanelAndRemovesCallbacks() throws {
    let fixture = try Harness()
    defer { fixture.close() }
    let point = try fixture.meshPoint()
    fixture.reconcile(point)
    fixture.canvas.mouseDown(with: try fixture.mouse(.leftMouseDown, point: point))
    #expect(fixture.canvas.isOverlayCameraDragging)
    fixture.controller.shutdown()
    fixture.controller.shutdown()
    #expect(fixture.panel.ignoresMouseEvents && !fixture.canvas.overlayCameraArmed)
    #expect(!fixture.canvas.isOverlayCameraDragging)
    #expect(fixture.canvas.shouldBeginOverlayCameraInteraction == nil)
    #expect(fixture.canvas.onOverlayCameraInteraction == nil)
    #expect(fixture.controller.diagnostics.phase == "passive")
    #expect(fixture.controller.diagnostics.cancels == 1)
    #expect(!fixture.controller.diagnostics.observationAvailable)
    fixture.reconcile(point)
    fixture.canvas.mouseDown(with: try fixture.mouse(.leftMouseDown, point: point))
    #expect(!fixture.canvas.isOverlayCameraDragging && fixture.panel.ignoresMouseEvents)
  }

  @MainActor private final class Harness {
    let document: SceneDocument
    let canvas: RetainedCanvasView
    let panel: AnnotationPanel
    var authority: ExplanationOrbitState.Authority?
    var available = true
    private var ownedController: ExplanationOrbitController?
    var controller: ExplanationOrbitController { ownedController! }

    init() throws {
      _ = NSApplication.shared
      document = try SceneDocument(
        id: "orbit-controller-public",
        nodes: [
          .init(
            id: "body", kind: .mesh, fill: "#4488CC",
            spatial3D: .init(geometry: .box(width: 2, height: 1, depth: 0.8))),
          .init(
            id: "label", kind: .text, width: 120, height: 36, text: "Body", color: "#FFFFFF",
            spatial3D: .init(
              labelAnchor: .init(
                targetID: "body", point: .init(x: 1, y: 0, z: 0), screenOffset: .init(x: 90, y: -60)
              ))),
        ]
      ).validated()
      canvas = RetainedCanvasView(
        frame: CGRect(x: 0, y: 0, width: 620, height: 420), motionPolicy: .reducedMotion)
      panel = ExplanationOverlay.makeVisualPanel(
        frame: CGRect(x: -20_000, y: -20_000, width: 620, height: 420), canvas: canvas)
      authority = .init(lease: UUID(), documentID: document.id, generation: 1, displayID: 1)
      canvas.render(document, time: 0, selectedID: nil, presentationGeneration: 1)
      panel.orderBack(nil)
      canvas.layoutSubtreeIfNeeded()
      SCNTransaction.flush()
      guard panel.isVisible else { throw HarnessError.noOwnWindow }
      ownedController = ExplanationOrbitController(
        canvas: canvas, panel: panel, observeInput: false,
        authority: { [weak self] in self?.authority },
        available: { [weak self] in self?.available == true })
    }
    func close() {
      ownedController?.shutdown()
      canvas.stopDisplayLink()
      panel.orderOut(nil)
      panel.contentView = nil
      panel.close()
    }
    func meshPoint() throws -> CGPoint {
      let stage = try #require(canvas.spatialStage)
      let mesh = try #require(canvas.spatialNode(id: "body"))
      let projected = stage.projectPoint(mesh.worldPosition)
      let point = canvas.convert(
        CGPoint(x: CGFloat(projected.x), y: CGFloat(projected.y)), from: stage)
      #expect(canvas.visibleSpatialMesh(atCanvasPoint: point) == "body")
      return point
    }
    func reconcile(
      _ point: CGPoint, modifiers: ExplanationOrbitState.Modifiers = .option,
      buttons: ExplanationOrbitState.Buttons = []
    ) {
      let screen = panel.convertPoint(toScreen: canvas.convert(point, to: nil))
      controller.reconcileForAcceptance(pointer: screen, modifiers: modifiers, buttons: buttons)
    }
    func mouse(_ type: NSEvent.EventType, point: CGPoint, flags: NSEvent.ModifierFlags = .option)
      throws -> NSEvent
    {
      try #require(
        NSEvent.mouseEvent(
          with: type, location: canvas.convert(point, to: nil), modifierFlags: flags,
          timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber,
          context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 0.5))
    }
    private enum HarnessError: Error { case noOwnWindow }
  }
}
