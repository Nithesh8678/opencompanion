import AppKit
import CompanionCore
import SceneKit
import Testing
import simd

@testable import OpenCompanion

/// Authored own-view events exercise the native camera controller. They do not
/// synthesize system input, establish human input or test cross-app click routing.
@Suite @MainActor struct CanvasOverlayCameraTests {
  @Test func passiveDefaultAndHostVetoCannotBeginOrStealKeyboardFocus() throws {
    let view = try makeView()
    let point = try projectedCenter("body", in: view)
    var events: [CanvasCameraInteractionEvent] = []
    view.onOverlayCameraInteraction = { events.append($0) }
    #expect(view.visibleSpatialMesh(atCanvasPoint: point) == "body")
    #expect(!view.acceptsFirstResponder)
    #expect(view.spatialStage?.acceptsFirstResponder == false)
    #expect(view.spatialStage?.allowsCameraControl == false)
    view.mouseDown(with: try mouse(.leftMouseDown, point: point, view: view))
    #expect(!view.isOverlayCameraDragging && events.isEmpty)
    view.overlayCameraArmed = true
    var receivedFlags: NSEvent.ModifierFlags = []
    view.shouldBeginOverlayCameraInteraction = { _, flags in
      receivedFlags = flags
      return false
    }
    view.mouseDown(with: try mouse(.leftMouseDown, point: point, view: view))
    #expect(receivedFlags.contains(.option))
    #expect(!view.isOverlayCameraDragging && events.isEmpty)
    #expect(!view.acceptsFirstResponder && view.spatialStage?.acceptsFirstResponder == false)
    view.presentation = .editor
    #expect(view.acceptsFirstResponder && view.spatialStage?.acceptsFirstResponder == true)
    #expect(view.spatialStage?.allowsCameraControl == true)
  }

  @Test func closestTriangleQueryRejectsEmptyHiddenTransparentAndOccludedGeometry() throws {
    let document = try SceneDocument(
      id: "public-occlusion",
      nodes: [
        .init(id: "body", kind: .mesh, spatial3D: .init(geometry: .sphere(radius: 0.8))),
        .init(
          id: "front", kind: .mesh,
          spatial3D: .init(
            transform: .init(position: .init(x: 0, y: 0, z: 2)),
            geometry: .box(width: 2, height: 2, depth: 0.4))),
      ]
    ).validated()
    let view = try makeView(document)
    let stage = try #require(view.spatialStage)
    let camera = try #require(stage.pointOfView)
    camera.position = SCNVector3(0, 0, 8)
    camera.look(at: SCNVector3Zero)
    view.updateCameraProjection()
    let point = try projectedCenter("body", in: view)
    #expect(view.visibleSpatialMesh(atCanvasPoint: point) == "front")
    #expect(view.visibleSpatialMesh(atCanvasPoint: .zero) == nil)
    #expect(view.visibleSpatialMesh(atCanvasPoint: CGPoint(x: CGFloat.infinity, y: 0)) == nil)
    let front = try #require(view.spatialNode(id: "front"))
    front.isHidden = true
    SCNTransaction.flush()
    #expect(view.visibleSpatialMesh(atCanvasPoint: point) == "body")
    front.isHidden = false
    front.opacity = 0
    SCNTransaction.flush()
    #expect(view.visibleSpatialMesh(atCanvasPoint: point) == "body")
    front.opacity = 1
    let material = try #require(front.geometry?.firstMaterial)
    material.diffuse.contents = NSColor.clear
    SCNTransaction.flush()
    #expect(view.visibleSpatialMesh(atCanvasPoint: point) == "body")
    material.diffuse.contents = NSColor.red
    SCNTransaction.flush()
    #expect(view.visibleSpatialMesh(atCanvasPoint: point) == "front")
    let body = try #require(view.spatialNode(id: "body"))
    body.isHidden = true
    front.isHidden = true
    #expect(view.visibleSpatialMesh(atCanvasPoint: point) == nil)
  }

  @Test func actualDragEventsRotateCameraAndEndWithoutInertiaOrDocumentMutation() throws {
    let document = try fixture().validated()
    let view = try makeView(document)
    let point = try projectedCenter("body", in: view)
    let stage = try #require(view.spatialStage)
    let camera = try #require(stage.pointOfView)
    let before = camera.simdWorldTransform
    var events: [CanvasCameraInteractionEvent] = []
    view.onOverlayCameraInteraction = { events.append($0) }
    view.shouldBeginOverlayCameraInteraction = { _, flags in flags.contains(.option) }
    view.overlayCameraArmed = true
    view.mouseDown(with: try mouse(.leftMouseDown, point: point, view: view))
    #expect(view.isOverlayCameraDragging)
    let moved = CGPoint(x: point.x + 70, y: point.y + 25)
    view.mouseDragged(with: try mouse(.leftMouseDragged, point: moved, view: view))
    view.mouseUp(with: try mouse(.leftMouseUp, point: moved, view: view))
    #expect(events == [.began, .ended])
    #expect(!view.isOverlayCameraDragging && view.overlayCameraDragEventCount == 1)
    #expect(camera.simdWorldTransform != before)
    #expect(!stage.defaultCameraController.inertiaEnabled)
    #expect(!stage.defaultCameraController.isInertiaRunning)
    let stopped = camera.simdWorldTransform
    view.mouseDragged(with: try mouse(.leftMouseDragged, point: point, view: view))
    #expect(camera.simdWorldTransform == stopped && view.overlayCameraDragEventCount == 1)
    view.render(document, time: 0, selectedID: nil, presentationGeneration: 1)
    #expect(camera.simdWorldTransform == stopped)
    #expect(document == fixture())
  }

  @Test func stopLeaseLossGenerationReplacementAndHiddenViewCancelExactlyOnce() throws {
    for cause in 0..<5 {
      let document = try fixture().validated()
      let view = try makeView(document)
      let point = try projectedCenter("body", in: view)
      var events: [CanvasCameraInteractionEvent] = []
      view.onOverlayCameraInteraction = { events.append($0) }
      view.overlayCameraArmed = true
      view.mouseDown(with: try mouse(.leftMouseDown, point: point, view: view))
      #expect(view.isOverlayCameraDragging)
      switch cause {
      case 0: view.stopDisplayLink()
      case 1: view.overlayCameraArmed = false
      case 2: view.render(document, time: 0, selectedID: nil, presentationGeneration: 2)
      case 3:
        var replacement = document
        replacement.id = "replacement"
        view.render(replacement, time: 0, selectedID: nil, presentationGeneration: 1)
      default: view.isHidden = true
      }
      view.cancelOverlayCameraInteraction()
      #expect(!view.isOverlayCameraDragging)
      #expect(events == [.began, .cancelled])
      #expect(view.spatialStage?.defaultCameraController.isInertiaRunning == false)
      view.mouseUp(with: try mouse(.leftMouseUp, point: point, view: view))
      #expect(events == [.began, .cancelled])
    }
  }

  @Test func progressiveGeometryRefitPreservesOrbitedDirectionAndFitsNewCorners() throws {
    var document = try fixture().validated()
    let view = try makeView(document)
    let point = try projectedCenter("body", in: view)
    let stage = try #require(view.spatialStage)
    let camera = try #require(stage.pointOfView)
    view.overlayCameraArmed = true
    view.mouseDown(with: try mouse(.leftMouseDown, point: point, view: view))
    let moved = CGPoint(x: point.x + 85, y: point.y - 18)
    view.mouseDragged(with: try mouse(.leftMouseDragged, point: moved, view: view))
    view.mouseUp(with: try mouse(.leftMouseUp, point: moved, view: view))
    let back = direction(camera.worldPosition, from: stage.defaultCameraController.target)
    document.nodes.append(
      .init(
        id: "new-part", kind: .mesh,
        spatial3D: .init(
          transform: .init(position: .init(x: 4, y: 1, z: -1)),
          geometry: .box(width: 1.2, height: 0.6, depth: 1))))
    document = try document.validated()
    view.render(document, time: 0, selectedID: nil, presentationGeneration: 1)
    let after = direction(camera.worldPosition, from: stage.defaultCameraController.target)
    #expect(simd_dot(back, after) > 0.999_9)
    for id in ["body", "new-part"] {
      let node = try #require(view.spatialNode(id: id))
      let box = node.boundingBox
      for x in [box.min.x, box.max.x] {
        for y in [box.min.y, box.max.y] {
          for z in [box.min.z, box.max.z] {
            let world = node.convertPosition(SCNVector3(x, y, z), to: nil)
            let projected = stage.projectPoint(world)
            #expect(projected.x >= 0 && Double(projected.x) <= stage.bounds.width)
            #expect(projected.y >= 0 && Double(projected.y) <= stage.bounds.height)
            #expect(projected.z >= 0 && projected.z <= 1)
          }
        }
      }
    }
    view.render(document, time: 0, selectedID: nil, presentationGeneration: 2)
    var reset = document
    reset.nodes[0].spatial3D?.geometry = .box(width: 2.1, height: 1, depth: 0.8)
    view.render(reset, time: 0, selectedID: nil, presentationGeneration: 2)
    let defaultDirection = simd_normalize(SIMD3<Float>(0.55, 0.3, 1))
    #expect(
      simd_dot(
        direction(camera.worldPosition, from: stage.defaultCameraController.target),
        defaultDirection) > 0.999_9)
  }

  private func fixture() -> SceneDocument {
    .init(
      id: "public-camera-fixture",
      nodes: [
        .init(
          id: "body", kind: .mesh, fill: "#4488CC",
          spatial3D: .init(geometry: .box(width: 2, height: 1, depth: 0.8)))
      ])
  }

  private func makeView(_ document: SceneDocument? = nil) throws -> RetainedCanvasView {
    let view = RetainedCanvasView(
      frame: CGRect(x: 0, y: 0, width: 620, height: 420), motionPolicy: .reducedMotion)
    view.presentation = .passiveOverlay
    view.render(
      try (document ?? fixture()).validated(), time: 0, selectedID: nil, presentationGeneration: 1)
    view.layoutSubtreeIfNeeded()
    SCNTransaction.flush()
    return view
  }

  private func projectedCenter(_ id: String, in view: RetainedCanvasView) throws -> CGPoint {
    let stage = try #require(view.spatialStage)
    let node = try #require(view.spatialNode(id: id))
    let projected = stage.projectPoint(node.worldPosition)
    return view.convert(CGPoint(x: CGFloat(projected.x), y: CGFloat(projected.y)), from: stage)
  }

  private func mouse(_ type: NSEvent.EventType, point: CGPoint, view: NSView) throws -> NSEvent {
    try #require(
      NSEvent.mouseEvent(
        with: type, location: view.convert(point, to: nil), modifierFlags: .option,
        timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: view.window?.windowNumber ?? 0,
        context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 0.5))
  }

  private func direction(_ position: SCNVector3, from target: SCNVector3) -> SIMD3<Float> {
    simd_normalize(
      SIMD3(
        Float(position.x - target.x), Float(position.y - target.y), Float(position.z - target.z)))
  }
}
