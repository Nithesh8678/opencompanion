import AppKit
import CompanionCore
import SceneKit
import Testing

@testable import OpenCompanion

@Suite @MainActor struct SpatialRendererTests {
  @Test func retainedStudioRigAndPhysicalMaterialDoNotAllocateAgainOnPlayback() throws {
    let view = RetainedCanvasView(frame: CGRect(x: 0, y: 0, width: 620, height: 420))
    let document = try fixture().validated()
    view.render(document, time: 0, selectedID: nil)
    let stage = try #require(view.spatialStage)
    let camera = try #require(stage.pointOfView)
    let material = try #require(view.spatialNode(id: "rotor")?.geometry?.firstMaterial)
    #expect(stage.antialiasingMode == .multisampling4X && !stage.rendersContinuously)
    #expect(!stage.autoenablesDefaultLighting && camera.childNodes.count == 4)
    #expect(camera.camera?.wantsHDR == true)
    #expect(material.lightingModel == .physicallyBased)
    #expect(material.diffuse.contents is NSColor)
    view.render(document, time: 0.3, selectedID: nil)
    #expect(view.spatialNode(id: "rotor")?.geometry?.firstMaterial === material)
    #expect(camera.childNodes.count == 4)
  }

  @Test func localSwipePreservesDistanceAndDocumentAndReprojectsLabels() throws {
    let view = RetainedCanvasView(
      frame: CGRect(x: 0, y: 0, width: 620, height: 420), motionPolicy: .reducedMotion)
    view.presentation = .passiveOverlay
    view.overlaySurfaceInteractive = true
    view.overlayHeaderInset = 44
    let document = try fixture().validated()
    view.render(document, time: 0, selectedID: nil)
    let stage = try #require(view.spatialStage)
    let camera = try #require(stage.pointOfView)
    let before = camera.position
    let target = stage.defaultCameraController.target
    let initialLeader = try #require(view.projectedLeaderPath(id: "label"))
    let radius = hypot(hypot(before.x - target.x, before.y - target.y), before.z - target.z)
    #expect(view.orbitOverlayCamera(delta: CGPoint(x: 0.18, y: 0.072)))
    let after = camera.position
    let newRadius = hypot(hypot(after.x - target.x, after.y - target.y), after.z - target.z)
    #expect(abs(radius - newRadius) < 0.0001)
    #expect(abs(after.x - before.x) > 0.01)
    let movedLeader = try #require(view.projectedLeaderPath(id: "label"))
    #expect(movedLeader.boundingBoxOfPath != initialLeader.boundingBoxOfPath)
    #expect(
      view.renderedDocumentID == document.id && view.renderedDocumentRevision == document.revision)
    #expect(stage.frame.minY >= 44)
    let renderedLabel = try #require(view.projectedLabelFrame(id: "label"))
    #expect(view.canvasFrame(forDocumentRect: renderedLabel).minY >= 44)
    #expect(!view.orbitOverlayCamera(delta: CGPoint(x: CGFloat.nan, y: 1)))
    #expect(!view.orbitOverlayCamera(delta: CGPoint(x: 1, y: CGFloat.infinity)))
    #expect(!view.orbitOverlayCamera(delta: .zero))
    view.overlaySurfaceInteractive = false
    #expect(!view.orbitOverlayCamera(delta: CGPoint(x: 1, y: 1)))
    #expect(
      camera.position.x == after.x && camera.position.y == after.y && camera.position.z == after.z)
  }

  @Test func failedRuntimePoseCannotClaimSuccessfulRenderOrReplaceRetainedNativeIdentity() throws {
    let view = RetainedCanvasView(frame: CGRect(x: 0, y: 0, width: 620, height: 420))
    let original = try fixture().validated()
    #expect(view.render(original, time: 0, selectedID: nil))
    var body = SceneNode(
      id: "large-body", kind: .mesh,
      spatial3D: .init(geometry: .box(width: 1_000, height: 1, depth: 1)))
    body.parentID = "large-group"
    body.bindings["spatial3D.transform.scale.x"] = .operation(
      .add, [.number(1), .operation(.mul, [.number(99), .operation(.sin, [.reference("time")])])])
    let group = SceneNode(
      id: "large-group", kind: .group,
      spatial3D: .init(transform: .init(scale: .init(x: 10, y: 1, z: 1))))
    let proposal = try SceneDocument(nodes: [body, group]).validated()
    #expect(!view.render(proposal, time: .pi / 2, selectedID: nil, presentationGeneration: 8))
    #expect(
      view.renderedDocumentID == original.id && view.renderedDocumentRevision == original.revision)
    #expect(view.spatialNode(id: "rotor") != nil && view.spatialNode(id: "large-body") == nil)
    #expect(view.render(proposal, time: 0, selectedID: nil, presentationGeneration: 8))
    #expect(view.renderedDocumentID == proposal.id)
  }

  @Test func nativeHierarchyUsesLocalTransformsAndOneParentOpacity() throws {
    let document = try fixture().validated()
    let view = RetainedCanvasView(frame: CGRect(x: 0, y: 0, width: 620, height: 420))
    view.render(document, time: 0, selectedID: nil)
    let child = try #require(view.spatialNode(id: "rotor"))
    let parent = try #require(view.spatialNode(id: "assembly"))
    #expect(child.parent === parent)
    #expect(child.geometry is SCNCylinder)
    let world = child.convertPosition(SCNVector3Zero, to: nil)
    let expected = try #require(document.spatialWorldPoses(at: 0).first { $0.node.id == "rotor" })
      .transform.applying(to: .zero)
    #expect(abs(Double(world.x) - expected.x) < 0.0001)
    #expect(abs(Double(world.y) - expected.y) < 0.0001)
    #expect(abs(Double(world.z) - expected.z) < 0.0001)
    #expect(abs(child.opacity - 0.8) < 0.000_001)
    #expect(abs(parent.opacity - 0.5) < 0.000_001)
  }

  @Test func projectedLabelAndLeaderFollowTheActualCamera() throws {
    let view = RetainedCanvasView(frame: CGRect(x: 0, y: 0, width: 620, height: 420))
    view.render(try fixture().validated(), time: 0, selectedID: nil)
    let initial = try #require(view.projectedLabelFrame(id: "label"))
    let oldLeader = try #require(view.projectedLeaderPath(id: "label"))
    let stage = try #require(view.spatialStage)
    let camera = try #require(stage.pointOfView)
    camera.position = SCNVector3(5, 2, 5)
    camera.look(at: SCNVector3Zero)
    view.updateCameraProjection()
    let updated = try #require(view.projectedLabelFrame(id: "label"))
    let newLeader = try #require(view.projectedLeaderPath(id: "label"))
    #expect(hypot(updated.minX - initial.minX, updated.minY - initial.minY) > 1)
    #expect(oldLeader.boundingBoxOfPath != newLeader.boundingBoxOfPath)
    #expect(CGRect(x: 0, y: 0, width: 900, height: 560).contains(updated))
  }

  @Test func animationReusesGeometryAndDoesNotResetAnEditedCamera() throws {
    var document = fixture()
    document.animations = [.init(id: "spin", targetID: "rotor", speed: 90, axis3D: .z)]
    document = try document.validated()
    let view = RetainedCanvasView(frame: CGRect(x: 0, y: 0, width: 620, height: 420))
    view.render(document, time: 0, selectedID: nil)
    let node = try #require(view.spatialNode(id: "rotor"))
    let geometry = try #require(node.geometry)
    let camera = try #require(view.spatialStage?.pointOfView)
    camera.position.x += 1
    let cameraX = camera.position.x
    let before = node.simdTransform
    view.render(document, time: 0.5, selectedID: nil)
    #expect(node.geometry === geometry)
    #expect(camera.position.x == cameraX)
    #expect(node.simdTransform != before)
  }

  @Test func typedEditorIsLegibleAndPassivePresentationKeepsTransparentBackdrop() throws {
    let view = RetainedCanvasView(frame: CGRect(x: 0, y: 0, width: 620, height: 420))
    view.render(try fixture().validated(), time: 0, selectedID: nil)
    #expect(view.layer?.backgroundColor?.alpha == 1)
    #expect(view.spatialStage?.allowsCameraControl == true)
    view.presentation = .passiveOverlay
    #expect(view.layer?.backgroundColor?.alpha == 0)
    #expect(view.spatialStage?.backgroundColor.alphaComponent == 0)
    #expect(view.spatialStage?.allowsCameraControl == false)
  }

  @Test func groupOnlyFirstUnitDoesNotCountAsVisibleVisualContent() {
    let group = SceneNode(id: "empty", kind: .group, spatial3D: .init())
    #expect(!ExplanationOverlay.hasRenderableContent(SceneDocument(nodes: [group])))
    let label = SceneNode(
      id: "pending-label", kind: .text, text: "Assembly", color: "#FFFFFF",
      spatial3D: .init(labelAnchor: .init(targetID: "empty")))
    #expect(!ExplanationOverlay.hasRenderableContent(SceneDocument(nodes: [group, label])))
    #expect(ExplanationOverlay.hasRenderableContent(fixture()))
  }

  @Test func obliqueCameraFitsEveryWorldCornerWithoutDiagonalSpherePadding() throws {
    let cases: [(Geometry3D, Transform3D)] = [
      (.box(width: 2, height: 2, depth: 2), .identity),
      (
        .box(width: 6, height: 0.3, depth: 0.5),
        .init(
          position: .init(x: -3, y: 2, z: 1),
          rotationDegrees: .init(x: 15, y: 35, z: 30))
      ),
    ]
    for size in [CGSize(width: 620, height: 420), CGSize(width: 420, height: 620)] {
      for (geometry, transform) in cases {
        let document = try SceneDocument(
          nodes: [
            .init(
              id: "body", kind: .mesh,
              spatial3D: .init(transform: transform, geometry: geometry))
          ]).validated()
        let view = RetainedCanvasView(frame: CGRect(origin: .zero, size: size))
        view.render(document, time: 0, selectedID: nil)
        let stage = try #require(view.spatialStage)
        let body = try #require(view.spatialNode(id: "body"))
        let box = body.boundingBox
        var largestExtent = 0.0
        for x in [box.min.x, box.max.x] {
          for y in [box.min.y, box.max.y] {
            for z in [box.min.z, box.max.z] {
              let world = body.convertPosition(SCNVector3(x, y, z), to: nil)
              let projected = stage.projectPoint(world)
              let horizontal = abs(2 * Double(projected.x) / stage.bounds.width - 1)
              let vertical = abs(2 * Double(projected.y) / stage.bounds.height - 1)
              #expect(projected.z.isFinite && projected.z >= 0 && projected.z <= 1)
              #expect(horizontal <= 0.9 && vertical <= 0.9)
              largestExtent = max(largestExtent, max(horizontal, vertical))
            }
          }
        }
        // At least one corner should use the available FOV within the authored
        // 12% margin; merely keeping tiny geometry inside the view is insufficient.
        #expect(largestExtent > 0.85)
        #expect(largestExtent < 0.9)
      }
    }
  }

  private func fixture() -> SceneDocument {
    SceneDocument(
      id: "native-spatial-fixture", title: "Authored native hierarchy", width: 900, height: 560,
      nodes: [
        SceneNode(
          id: "rotor", kind: .mesh, color: "#E49D4F", opacity: 0.8, parentID: "assembly",
          spatial3D: .init(
            transform: .init(position: .init(x: 1, y: 0, z: 0)),
            geometry: .cylinder(radius: 0.45, height: 1.2))),
        SceneNode(
          id: "assembly", kind: .group, opacity: 0.5,
          spatial3D: .init(
            transform: .init(
              position: .init(x: 0.2, y: 0, z: 0), rotationDegrees: .init(x: 0, y: 0, z: 30)))),
        SceneNode(
          id: "label", kind: .text, text: "Rotor", color: "#FFFFFF", fontSize: 18,
          spatial3D: .init(
            labelAnchor: .init(
              targetID: "rotor", point: .init(x: 0.4, y: 0.5, z: 0),
              screenOffset: .init(x: 20, y: -24)))),
      ])
  }
}
