import AppKit
import CompanionCore
import SceneKit
import Testing

@testable import OpenCompanion

@Suite @MainActor struct SpatialLabelAttachmentTests {
  @Test func recordedHousingCavityAndMissingArcResolveToHousingTriangles() throws {
    let fixture = Harness()
    try fixture.add(
      "housing",
      geometry: .tube(
        innerRadius: 1.2, outerRadius: 1.42, height: 3.2, segments: 40,
        startAngleDegrees: 120, sweepAngleDegrees: 240))
    try fixture.add("rotor", geometry: .cylinder(radius: 0.6, height: 2.4))
    let requested = Vector3D(x: 0.7, y: 1.1, z: 0.7)
    let result = try #require(fixture.resolve(target: "housing", point: requested)["label"])
    #expect(result.requestedLocal == requested)
    #expect(result.isResolved && result.status == .surfaceSearch)
    #expect(result.surfaceNodeID == "housing")
    #expect(result.resolvedTargetLocal != requested)
    try fixture.assertSurface(result)
    #expect(result.candidateTests <= 32 && result.rayTests <= 33)
    let total = fixture.resolver.diagnostics.totalRayTests
    let repeated = try #require(fixture.resolve(target: "housing", point: requested)["label"])
    #expect(repeated.reusedCachedSurface && repeated.rayTests == 0)
    #expect(fixture.resolver.diagnostics.totalRayTests == total)
  }

  @Test func sphereCenterRetainsCanonicalPointAndUsesTheFrontVisibleSurface() throws {
    let fixture = Harness()
    try fixture.add("atom", geometry: .sphere(radius: 1))
    let result = try #require(fixture.resolve(target: "atom", point: .zero)["label"])
    #expect(result.requestedLocal == .zero && result.requestedWorld == .zero)
    #expect(result.status == .requestedProjection && result.surfaceNodeID == "atom")
    let resolved = try #require(result.resolvedGeometryLocal)
    #expect(hypot(hypot(resolved.x, resolved.y), resolved.z) > 0.95)
    try fixture.assertSurface(result)
  }

  @Test func parentTransformsAndOrbitRevalidateTheActualSurface() throws {
    let fixture = Harness()
    let group = SCNNode()
    group.position = SCNVector3(0.3, 0.2, 0)
    group.eulerAngles.z = 0.4
    fixture.scene.rootNode.addChildNode(group)
    fixture.nodes["assembly"] = group
    fixture.opacity["assembly"] = 1
    try fixture.add("atom", geometry: .sphere(radius: 0.8), parent: group)
    let first = try #require(fixture.resolve(target: "assembly", point: .zero)["label"])
    #expect(first.surfaceNodeID == "atom")
    try fixture.assertSurface(first)
    fixture.camera.position = SCNVector3(-3, 2, 6)
    fixture.camera.look(at: SCNVector3(0.3, 0.2, 0))
    let second = try #require(fixture.resolve(target: "assembly", point: .zero)["label"])
    #expect(second.isResolved && second.reusedCachedSurface)
    #expect(second.rayTests > 0 && second.candidateTests == 0)
    #expect(second.resolvedWorld != first.resolvedWorld)
    try fixture.assertSurface(second)
  }

  @Test func fullSceneOccludersCannotBeIgnoredAndTransparentMaterialDoesNotOcclude() throws {
    let fixture = Harness(frontCamera: true)
    try fixture.add("target", geometry: .sphere(radius: 0.5))
    try fixture.add("blocker", geometry: .box(width: 4, height: 4, depth: 0.4))
    fixture.nodes["blocker"]?.position.z = 2
    let blocked = try #require(fixture.resolve(target: "target", point: .zero)["label"])
    #expect(!blocked.isResolved && blocked.status == .occluded)
    #expect(blocked.surfaceNodeID == nil && blocked.resolvedWorld == nil)
    let total = fixture.resolver.diagnostics.totalRayTests
    _ = fixture.resolve(target: "target", point: .zero)
    #expect(fixture.resolver.diagnostics.totalRayTests == total)
    fixture.nodes["blocker"]?.geometry?.firstMaterial?.transparency = 0
    let visible = try #require(fixture.resolve(target: "target", point: .zero)["label"])
    #expect(visible.isResolved && visible.surfaceNodeID == "target")
    try fixture.assertSurface(visible)
    fixture.nodes["blocker"]?.geometry?.firstMaterial?.transparency = 1
    let opaqueAgain = try #require(fixture.resolve(target: "target", point: .zero)["label"])
    #expect(!opaqueAgain.isResolved && opaqueAgain.status == .occluded)
    fixture.opacity["blocker"] = 0
    let zeroOpacity = try #require(fixture.resolve(target: "target", point: .zero)["label"])
    #expect(zeroOpacity.isResolved)
    try fixture.assertSurface(zeroOpacity)
    fixture.opacity["blocker"] = 1
    fixture.nodes["blocker"]?.isHidden = true
    let hidden = try #require(fixture.resolve(target: "target", point: .zero)["label"])
    #expect(hidden.isResolved)
    try fixture.assertSurface(hidden)
    fixture.nodes["blocker"]?.isHidden = false
    fixture.nodes["blocker"]?.geometry?.firstMaterial?.diffuse.contents = NSColor.clear
    let clearColor = try #require(fixture.resolve(target: "target", point: .zero)["label"])
    #expect(clearColor.isResolved)
    try fixture.assertSurface(clearColor)
  }

  @Test func terminalMissRequeriesOnActualNativeWindowBindingThenSettles() throws {
    _ = NSApplication.shared
    let fixture = Harness(frontCamera: true)
    try fixture.add("target", geometry: .sphere(radius: 0.5))
    try fixture.add("blocker", geometry: .box(width: 4, height: 4, depth: 0.4))
    fixture.nodes["blocker"]?.position.z = 2
    let first = try #require(fixture.resolve(target: "target", point: .zero)["label"])
    #expect(first.status == .occluded && !first.isResolved)
    #expect(first.rayTests > 0 && first.rayTests <= 33)
    try fixture.assertClosestNode("blocker")
    let cached = try #require(fixture.resolve(target: "target", point: .zero)["label"])
    #expect(cached.status == .occluded && cached.reusedCachedSurface && cached.rayTests == 0)
    #expect(!fixture.resolver.hasPendingWork)
    let originalContext = fixture.resolver.diagnostics.contextChanges
    let originalBounds = fixture.stage.bounds
    let foreground = NSWorkspace.shared.frontmostApplication?.processIdentifier
    let panel = NSPanel(
      contentRect: fixture.stage.frame, styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered, defer: false)
    panel.isReleasedWhenClosed = false
    defer {
      panel.contentView = nil
      panel.close()
    }
    // Binding is real AppKit ownership, with no ordering, keying, activation,
    // screenshot, simulated hit result, or arbitrary readiness sleep.
    panel.contentView = fixture.stage
    #expect(fixture.stage.window === panel)
    #expect(!panel.isVisible && !panel.isKeyWindow)
    #expect(fixture.stage.bounds == originalBounds)
    let rebound = try #require(fixture.resolve(target: "target", point: .zero)["label"])
    #expect(fixture.resolver.diagnostics.contextChanges == originalContext + 1)
    #expect(!rebound.reusedCachedSurface && rebound.rayTests > 0 && rebound.rayTests <= 33)
    #expect(!rebound.isResolved && rebound.status == .occluded)
    try fixture.assertClosestNode("blocker")
    let queries = fixture.resolver.diagnostics.totalRayTests
    let settled = try #require(fixture.resolve(target: "target", point: .zero)["label"])
    #expect(settled.reusedCachedSurface && settled.rayTests == 0)
    #expect(fixture.resolver.diagnostics.totalRayTests == queries)
    #expect(!fixture.resolver.hasPendingWork)
    #expect(NSWorkspace.shared.frontmostApplication?.processIdentifier == foreground)
  }

  @Test func nativeStageVisibilityInvalidatesTerminalMissWithoutUnboundedRetries() throws {
    let fixture = Harness(frontCamera: true)
    try fixture.add("target", geometry: .sphere(radius: 0.5))
    try fixture.add("blocker", geometry: .box(width: 4, height: 4, depth: 0.4))
    fixture.nodes["blocker"]?.position.z = 2
    let first = try #require(fixture.resolve(target: "target", point: .zero)["label"])
    #expect(first.status == .occluded && !first.isResolved)
    for hidden in [true, false] {
      let oldContext = fixture.resolver.diagnostics.contextChanges
      fixture.stage.isHidden = hidden
      let changed = try #require(fixture.resolve(target: "target", point: .zero)["label"])
      #expect(fixture.resolver.diagnostics.contextChanges == oldContext + 1)
      #expect(!changed.reusedCachedSurface && changed.rayTests > 0 && changed.rayTests <= 33)
      #expect(!changed.isResolved)
      if !hidden {
        #expect(changed.status == .occluded)
        try fixture.assertClosestNode("blocker")
      }
      let total = fixture.resolver.diagnostics.totalRayTests
      let repeated = try #require(fixture.resolve(target: "target", point: .zero)["label"])
      #expect(repeated.reusedCachedSurface && repeated.rayTests == 0)
      #expect(fixture.resolver.diagnostics.totalRayTests == total)
      #expect(!fixture.resolver.hasPendingWork)
    }
  }

  @Test func sameNativeWindowShowAndHideInvalidateTerminalMissThenCacheAgain() throws {
    _ = NSApplication.shared
    let fixture = Harness(frontCamera: true)
    try fixture.add("target", geometry: .sphere(radius: 0.5))
    try fixture.add("blocker", geometry: .box(width: 4, height: 4, depth: 0.4))
    fixture.nodes["blocker"]?.position.z = 2
    let panel = NSPanel(
      contentRect: fixture.stage.frame, styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered, defer: false)
    panel.isReleasedWhenClosed = false
    panel.ignoresMouseEvents = true
    panel.sharingType = .none
    panel.contentView = fixture.stage
    defer {
      panel.orderOut(nil)
      panel.contentView = nil
      panel.close()
    }
    let foreground = NSWorkspace.shared.frontmostApplication?.processIdentifier
    let first = try #require(fixture.resolve(target: "target", point: .zero)["label"])
    #expect(!panel.isVisible && first.status == .occluded)
    for visible in [true, false] {
      let priorContext = fixture.resolver.diagnostics.contextChanges
      // Actual public native component visibility, not mocked window flags.
      // Neither path makes this nonactivating panel key or posts user input.
      if visible { panel.orderFrontRegardless() } else { panel.orderOut(nil) }
      #expect(panel.isVisible == visible && fixture.stage.window === panel)
      #expect(!panel.isKeyWindow)
      let changed = try #require(fixture.resolve(target: "target", point: .zero)["label"])
      #expect(fixture.resolver.diagnostics.contextChanges == priorContext + 1)
      #expect(!changed.reusedCachedSurface && changed.rayTests > 0 && changed.rayTests <= 33)
      #expect(!changed.isResolved && changed.status == .occluded)
      try fixture.assertClosestNode("blocker")
      let total = fixture.resolver.diagnostics.totalRayTests
      let cached = try #require(fixture.resolve(target: "target", point: .zero)["label"])
      #expect(cached.reusedCachedSurface && cached.rayTests == 0)
      #expect(fixture.resolver.diagnostics.totalRayTests == total)
      #expect(!fixture.resolver.hasPendingWork)
      #expect(NSWorkspace.shared.frontmostApplication?.processIdentifier == foreground)
    }
  }

  @Test func removalGeometryReplacementAndNewGenerationInvalidateCachedOwnership() throws {
    let fixture = Harness()
    try fixture.add("target", geometry: .sphere(radius: 0.5))
    let initial = try #require(fixture.resolve(target: "target", point: .zero)["label"])
    #expect(initial.isResolved)
    fixture.nodes.removeValue(forKey: "target")?.removeFromParentNode()
    fixture.geometries.removeValue(forKey: "target")
    let removed = try #require(fixture.resolve(target: "target", point: .zero)["label"])
    #expect(!removed.isResolved && removed.status == .missingTarget)
    try fixture.add("target", geometry: .sphere(radius: 1))
    let replaced = try #require(fixture.resolve(target: "target", point: .zero)["label"])
    #expect(replaced.isResolved && !replaced.reusedCachedSurface)
    #expect(replaced.resolvedWorld != initial.resolvedWorld)
    let regenerated = try #require(
      fixture.resolve(target: "target", point: .zero, generation: 2)["label"])
    #expect(regenerated.isResolved && !regenerated.reusedCachedSurface)
    let stale = try #require(
      fixture.resolve(target: "target", point: .zero, generation: 1)["label"])
    #expect(!stale.isResolved && stale.status == .staleGeneration && stale.rayTests == 0)
    fixture.resolver.reset()
    #expect(!fixture.resolver.hasPendingWork)
  }

  @Test func budgetsContinueFairlyAndTerminalOcclusionDoesNotKeepWorkPending() throws {
    let fixture = Harness(frontCamera: true)
    try fixture.add("target", geometry: .sphere(radius: 0.5))
    try fixture.add("blocker", geometry: .box(width: 4, height: 4, depth: 0.4))
    fixture.nodes["blocker"]?.position.z = 2
    let requests = (0..<128).map {
      SpatialLabelAttachmentResolver.Request(
        labelID: String(format: "label-%03d", $0), anchor: .init(targetID: "target"))
    }
    var result = fixture.resolve(requests)
    #expect(fixture.resolver.hasPendingWork)
    #expect(fixture.resolver.diagnostics.rayTestsThisLayout <= 512)
    for _ in 0..<16 where fixture.resolver.hasPendingWork {
      result = fixture.resolve(requests)
      #expect(fixture.resolver.diagnostics.rayTestsThisLayout <= 512)
      #expect(result.values.allSatisfy { $0.candidateTests <= 32 })
    }
    #expect(result.count == 128 && !fixture.resolver.hasPendingWork)
    #expect(result.values.allSatisfy { $0.status == .occluded && !$0.isResolved })
    let total = fixture.resolver.diagnostics.totalRayTests
    _ = fixture.resolve(requests)
    #expect(fixture.resolver.diagnostics.totalRayTests == total)
  }

  @Test func changingCameraCannotStarveLabelsBeyondTheSharedRayBudget() throws {
    let fixture = Harness(frontCamera: true)
    try fixture.add("target", geometry: .sphere(radius: 0.5))
    try fixture.add("blocker", geometry: .box(width: 4, height: 4, depth: 0.4))
    fixture.nodes["blocker"]?.position.z = 2
    let requests = (0..<128).map {
      SpatialLabelAttachmentResolver.Request(
        labelID: String(format: "label-%03d", $0), anchor: .init(targetID: "target"))
    }
    var attempted = Set<String>()
    for frame in 0..<16 {
      fixture.camera.position.x = CGFloat(frame) * 0.001
      fixture.camera.look(at: SCNVector3Zero)
      let result = fixture.resolve(requests)
      attempted.formUnion(result.values.filter { $0.rayTests > 0 }.map(\.labelID))
      #expect(fixture.resolver.diagnostics.rayTestsThisLayout <= 512)
      #expect(result.values.allSatisfy { $0.candidateTests <= 32 })
    }
    #expect(attempted.count == 128)
    for _ in 0..<16 where fixture.resolver.hasPendingWork {
      _ = fixture.resolve(requests)
    }
    #expect(!fixture.resolver.hasPendingWork)
    let rays = fixture.resolver.diagnostics.totalRayTests
    _ = fixture.resolve(requests)
    #expect(fixture.resolver.diagnostics.totalRayTests == rays)
  }

  @Test func retainedCanvasRendersOnlyVerifiedLeaderAndLeavesCanonicalDocumentUnchanged() throws {
    let requested = Vector3D(x: 0.7, y: 1.1, z: 0.7)
    let document = try SceneDocument(
      id: "recorded-cavity", width: 900, height: 560,
      nodes: [
        .init(
          id: "housing", kind: .mesh,
          spatial3D: .init(
            geometry: .tube(
              innerRadius: 1.2, outerRadius: 1.42, height: 3.2, segments: 40,
              startAngleDegrees: 120, sweepAngleDegrees: 240))),
        .init(
          id: "rotor", kind: .mesh, spatial3D: .init(geometry: .cylinder(radius: 0.6, height: 2.4))),
        .init(
          id: "label", kind: .text, text: "Housing", color: "#FFFFFF",
          spatial3D: .init(labelAnchor: .init(targetID: "housing", point: requested))),
      ]
    ).validated()
    let view = RetainedCanvasView(
      frame: CGRect(x: 0, y: 0, width: 620, height: 420), motionPolicy: .fullMotion)
    view.presentation = .passiveOverlay
    view.render(document, time: 0, selectedID: nil, presentationGeneration: 1)
    let attachment = try #require(view.projectedLabelAttachments["label"])
    #expect(attachment.isResolved && attachment.surfaceNodeID == "housing")
    #expect(attachment.requestedLocal == requested)
    #expect(document.nodes.last?.spatial3D?.labelAnchor?.point == requested)
    let path = try #require(view.projectedLeaderPath(id: "label"))
    var start: CGPoint?
    path.applyWithBlock { element in
      if start == nil, element.pointee.type == .moveToPoint { start = element.pointee.points[0] }
    }
    let actual = try #require(start)
    let stage = try #require(view.spatialStage)
    let world = try #require(attachment.resolvedWorld)
    let projected = stage.projectPoint(SCNVector3(Float(world.x), Float(world.y), Float(world.z)))
    let expected = stage.convert(
      CGPoint(x: CGFloat(projected.x), y: CGFloat(projected.y)), to: view)
    let nativeStart = view.canvasFrame(forDocumentRect: CGRect(origin: actual, size: .zero)).origin
    #expect(hypot(nativeStart.x - expected.x, nativeStart.y - expected.y) < 0.5)
    let rays = view.labelAttachmentDiagnostics.totalRayTests
    view.advanceSpatialLabels(by: 0.01)
    #expect(view.labelAttachmentDiagnostics.totalRayTests == rays)
    view.stopDisplayLink()
    #expect(view.projectedLabelAttachments.isEmpty && !view.hasPendingLabelAttachments)
  }

  @Test func reducedMotionCompletesBoundedPendingGeometryWorkWithoutAnimatingText() throws {
    let nodes: [SceneNode] =
      [
        .init(id: "target", kind: .mesh, spatial3D: .init(geometry: .sphere(radius: 0.5))),
        .init(
          id: "blocker", kind: .mesh,
          spatial3D: .init(
            transform: .init(position: .init(x: 0, y: 0, z: 2)),
            geometry: .box(width: 4, height: 4, depth: 0.4))),
      ]
      + (0..<126).map {
        .init(
          id: String(format: "label-%03d", $0), kind: .text, text: "X",
          spatial3D: .init(labelAnchor: .init(targetID: "target")))
      }
    let view = RetainedCanvasView(
      frame: CGRect(x: 0, y: 0, width: 620, height: 420), motionPolicy: .reducedMotion)
    view.presentation = .passiveOverlay
    view.render(try SceneDocument(nodes: nodes).validated(), time: 0, selectedID: nil)
    #expect(!view.hasPendingSpatialLabels)
    #expect(view.hasPendingLabelAttachments && view.needsDisplayClock)
    #expect(view.labelAttachmentDiagnostics.rayTestsThisLayout <= 512)
    for _ in 0..<16 where view.hasPendingLabelAttachments {
      view.resolvePendingLabelAttachments()
      #expect(view.labelAttachmentDiagnostics.rayTestsThisLayout <= 512)
    }
    #expect(!view.hasPendingLabelAttachments && !view.needsDisplayClock)
    #expect(view.projectedLabelAttachments.count == 126)
    #expect(
      view.projectedLabelAttachments.values.allSatisfy { !$0.isResolved && $0.status == .occluded })
    for id in view.projectedLabelAttachments.keys {
      #expect(view.projectedLeaderPath(id: id) == nil)
    }
    let rays = view.labelAttachmentDiagnostics.totalRayTests
    view.resolvePendingLabelAttachments()
    #expect(view.labelAttachmentDiagnostics.totalRayTests == rays)
  }

  @MainActor private final class Harness {
    let stage = SCNView(frame: CGRect(x: 0, y: 0, width: 620, height: 420))
    let scene = SCNScene()
    let camera = SCNNode()
    let resolver = SpatialLabelAttachmentResolver()
    var nodes: [String: SCNNode] = [:]
    var geometries: [String: Geometry3D] = [:]
    var opacity: [String: Double] = [:]
    init(frontCamera: Bool = false) {
      stage.scene = scene
      camera.camera = SCNCamera()
      camera.camera?.fieldOfView = 50
      camera.camera?.projectionDirection = .vertical
      camera.camera?.zNear = 0.01
      camera.camera?.zFar = 100
      camera.position = frontCamera ? SCNVector3(0, 0, 6) : SCNVector3(3.3, 1.8, 6)
      camera.look(at: SCNVector3Zero)
      scene.rootNode.addChildNode(camera)
      stage.pointOfView = camera
    }
    func add(_ id: String, geometry: Geometry3D, parent: SCNNode? = nil) throws {
      let node = SCNNode(geometry: try Spatial3DGeometryFactory.make(geometry))
      node.name = id
      node.geometry?.firstMaterial = SCNMaterial()
      node.geometry?.firstMaterial?.diffuse.contents = NSColor.white
      (parent ?? scene.rootNode).addChildNode(node)
      nodes[id] = node
      geometries[id] = geometry
      opacity[id] = 1
    }
    func resolve(target: String, point: Vector3D, generation: UInt64 = 1) -> [String:
      SpatialLabelAttachment]
    {
      resolve(
        [.init(labelID: "label", anchor: .init(targetID: target, point: point))],
        generation: generation)
    }
    func resolve(_ requests: [SpatialLabelAttachmentResolver.Request], generation: UInt64 = 1)
      -> [String: SpatialLabelAttachment]
    {
      SCNTransaction.flush()
      return resolver.resolve(
        requests, documentID: "surface-fixture", generation: generation, stage: stage,
        nodes: nodes, geometries: geometries, effectiveOpacities: opacity)
    }
    func assertSurface(_ attachment: SpatialLabelAttachment) throws {
      let world = try #require(attachment.resolvedWorld)
      let projected = stage.projectPoint(SCNVector3(Float(world.x), Float(world.y), Float(world.z)))
      let hit = try #require(
        stage.hitTest(
          CGPoint(x: CGFloat(projected.x), y: CGFloat(projected.y)),
          options: [
            .searchMode: SCNHitTestSearchMode.closest.rawValue, .boundingBoxOnly: false,
            .categoryBitMask: 1,
          ]
        ).first)
      #expect(hit.node === nodes[attachment.surfaceNodeID ?? ""])
      let error = hypot(
        hypot(
          Double(hit.worldCoordinates.x) - world.x,
          Double(hit.worldCoordinates.y) - world.y), Double(hit.worldCoordinates.z) - world.z)
      #expect(error < 0.001)
    }
    func assertClosestNode(_ expectedID: String) throws {
      let projected = stage.projectPoint(SCNVector3Zero)
      let hit = try #require(
        stage.hitTest(
          CGPoint(x: CGFloat(projected.x), y: CGFloat(projected.y)),
          options: [
            .searchMode: SCNHitTestSearchMode.closest.rawValue, .boundingBoxOnly: false,
            .clipToZRange: true, .backFaceCulling: true, .ignoreHiddenNodes: true,
            .categoryBitMask: 1,
          ]
        ).first)
      #expect(hit.node === nodes[expectedID])
    }
  }
}
