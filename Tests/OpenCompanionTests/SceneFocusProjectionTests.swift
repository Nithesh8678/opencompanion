import AppKit
import CompanionCore
import SceneKit
import Testing

@testable import OpenCompanion

// These clock-driven native fixtures share one visible floating WindowServer
// region. Overlapping stages can occlude each other's display-link delivery.
@Suite(.serialized) @MainActor struct SceneFocusProjectionTests {
  @Test func logicalMappingKeepsNegativeOriginsFlipsAndViewScaleWithoutBackingPixels() throws {
    let transform = CGAffineTransform(a: 0.5, b: 0, c: 0, d: -0.5, tx: 50, ty: 600)
    let bounds = CGRect(x: 0, y: 0, width: 620, height: 420)
    let screen = CGRect(x: -1920, y: -1080, width: 1920, height: 1080)
    let point = try #require(
      SceneFocusCoordinates.globalPoint(
        canvasPoint: CGPoint(x: 100, y: 100), canvasBounds: bounds, canvasToWindow: transform,
        windowScreenOrigin: screen.origin, screenFrames: [screen]))
    #expect(point == CGPoint(x: -1820, y: -530))
    let restored = CGPoint(x: point.x + 1920, y: point.y + 1080).applying(transform.inverted())
    #expect(restored == CGPoint(x: 100, y: 100))
    for invalid in [CGPoint(x: CGFloat.infinity, y: 0), CGPoint(x: 900, y: 900)] {
      #expect(
        SceneFocusCoordinates.globalPoint(
          canvasPoint: invalid, canvasBounds: bounds, canvasToWindow: transform,
          windowScreenOrigin: screen.origin, screenFrames: [screen]) == nil)
    }
    #expect(
      SceneFocusCoordinates.globalPoint(
        canvasPoint: .zero, canvasBounds: bounds,
        canvasToWindow: CGAffineTransform(scaleX: 0, y: 0),
        windowScreenOrigin: screen.origin, screenFrames: [screen]) == nil)
    #expect(
      SceneFocusCoordinates.globalPoint(
        canvasPoint: .zero, canvasBounds: bounds, canvasToWindow: .identity,
        windowScreenOrigin: CGPoint(x: 10000, y: 10000), screenFrames: [screen]) == nil)
  }

  @Test func mountedVerifiedLabelSurfaceUsesNativeGlobalCoordinatesAndZeroNewRays() throws {
    let document = try bodyDocument(withLabel: true).validated()
    let foreground = NSWorkspace.shared.frontmostApplication?.processIdentifier
    let fixture = try Mounted(document)
    defer { fixture.close() }
    let projection = try #require(fixture.view.focusPoint(for: "body"))
    #expect(projection.documentID == document.id && projection.documentRevision == 3)
    #expect(
      projection.generation == 7 && projection.renderSerial == fixture.view.renderSubmissionSerial)
    #expect(projection.targetID == "body" && projection.surfaceNodeID == "body")
    #expect(fixture.view.sceneFocusRayTests == 0)
    let world = try #require(fixture.view.projectedLabelAttachments["label"]?.resolvedWorld)
    let stage = try #require(fixture.view.spatialStage)
    let p = stage.projectPoint(SCNVector3(Float(world.x), Float(world.y), Float(world.z)))
    let canvas = stage.convert(CGPoint(x: CGFloat(p.x), y: CGFloat(p.y)), to: fixture.view)
    let expected = fixture.panel.convertPoint(toScreen: fixture.view.convert(canvas, to: nil))
    #expect(
      hypot(projection.globalPoint.x - expected.x, projection.globalPoint.y - expected.y) < 0.001)
    try assertSurface(projection, in: fixture)
    for _ in 0..<100 { #expect(fixture.view.focusPoint(for: "body") == projection) }
    #expect(fixture.view.sceneFocusRayTests == 0)
    #expect(!fixture.panel.isKeyWindow && !fixture.panel.canBecomeKey)
    #expect(NSWorkspace.shared.frontmostApplication?.processIdentifier == foreground)
  }

  @Test func unlabelledSearchIsBoundedCachedAndRevalidatedForCameraAndLifecycle() throws {
    let document = try bodyDocument().validated()
    let fixture = try Mounted(document)
    defer { fixture.close() }
    var changes: [SceneFocusProjection?] = []
    fixture.view.onSceneFocusProjectionChanged = { changes.append($0) }
    let first = try #require(fixture.view.focusPoint(for: "body"))
    try assertSurface(first, in: fixture)
    let rays = fixture.view.sceneFocusRayTests
    #expect(rays > 0 && rays <= 33)
    for _ in 0..<100 { _ = fixture.view.currentSceneFocusProjection }
    #expect(fixture.view.sceneFocusRayTests == rays)
    let camera = try #require(fixture.view.spatialStage?.pointOfView)
    camera.position = SCNVector3(-4, 2, 7)
    camera.look(at: SCNVector3Zero)
    #expect(fixture.view.currentSceneFocusProjection == nil)
    fixture.view.updateCameraProjection()
    let moved = try #require(fixture.view.currentSceneFocusProjection)
    #expect(fixture.view.sceneFocusRayTests > rays && changes.last! == moved)
    try assertSurface(moved, in: fixture)
    fixture.view.render(document, time: 0, selectedID: nil, presentationGeneration: 8)
    #expect(fixture.view.currentSceneFocusProjection == nil)
    #expect(fixture.view.focusPoint(for: "body")?.generation == 8)
    #expect(fixture.view.focusPoint(for: "future-not-rendered") == nil)
    #expect(fixture.view.currentSceneFocusProjection == nil)
    #expect(fixture.view.focusPoint(for: "body") != nil)
    fixture.view.stopDisplayLink()
    #expect(fixture.view.currentSceneFocusProjection == nil && changes.last! == nil)
    fixture.view.render(document, time: 0, selectedID: nil, presentationGeneration: 8)
    #expect(fixture.view.focusPoint(for: "body") != nil)
    fixture.panel.contentView = nil
    #expect(fixture.view.currentSceneFocusProjection == nil)
    let detached = RetainedCanvasView(frame: fixture.view.frame)
    detached.render(document, time: 0, selectedID: nil, presentationGeneration: 8)
    #expect(detached.focusPoint(for: "body") == nil)
  }

  @Test func fullSceneOcclusionHiddenZeroAlphaAndOffscreenCannotProduceAPoint() throws {
    var document = bodyDocument()
    document.nodes.append(
      .init(
        id: "front", kind: .mesh,
        spatial3D: .init(
          transform: .init(position: .init(x: 0, y: 0, z: 2)),
          geometry: .box(width: 4, height: 4, depth: 0.4))))
    let fixture = try Mounted(try document.validated())
    defer { fixture.close() }
    let camera = try #require(fixture.view.spatialStage?.pointOfView)
    camera.position = SCNVector3(0, 0, 8)
    camera.look(at: SCNVector3Zero)
    fixture.view.updateCameraProjection()
    #expect(fixture.view.focusPoint(for: "body") == nil)
    let blocker = try #require(fixture.view.spatialNode(id: "front"))
    blocker.isHidden = true
    fixture.view.updateCameraProjection()
    try assertSurface(try #require(fixture.view.currentSceneFocusProjection), in: fixture)
    let body = try #require(fixture.view.spatialNode(id: "body"))
    body.isHidden = true
    #expect(fixture.view.currentSceneFocusProjection == nil)
    body.isHidden = false
    body.geometry?.firstMaterial?.diffuse.contents = NSColor.clear
    fixture.view.updateCameraProjection()
    #expect(fixture.view.currentSceneFocusProjection == nil)
    body.geometry?.firstMaterial?.diffuse.contents = NSColor.white
    body.opacity = 0
    fixture.view.updateCameraProjection()
    #expect(fixture.view.currentSceneFocusProjection == nil)
    body.opacity = 1
    camera.position = SCNVector3(0, 0, -8)
    camera.eulerAngles = SCNVector3Zero
    fixture.view.updateCameraProjection()
    #expect(fixture.view.currentSceneFocusProjection == nil)
    fixture.view.isHidden = true
    #expect(fixture.view.currentSceneFocusProjection == nil)
  }

  @Test func nativeFilledRectanglesAndEllipsesRejectOverlappingOrHollowInk() throws {
    for kind in [SceneNode.Kind.rectangle, .ellipse] {
      var document = SceneDocument(
        id: "public-2d-focus", revision: 4,
        nodes: [
          .init(id: "shape", kind: kind, x: 100, y: 80, width: 200, height: 120, fill: "#4488CC")
        ])
      let fixture = try Mounted(try document.validated())
      defer { fixture.close() }
      let point = try #require(fixture.view.focusPoint(for: "shape"))
      #expect(point.surfaceNodeID == "shape" && point.documentRevision == 4)
      let frame = fixture.view.canvasFrame(
        forDocumentRect: CGRect(x: 100, y: 80, width: 200, height: 120))
      let center = CGPoint(x: frame.midX, y: frame.midY)
      let expected = fixture.panel.convertPoint(toScreen: fixture.view.convert(center, to: nil))
      #expect(hypot(point.globalPoint.x - expected.x, point.globalPoint.y - expected.y) < 0.001)
      document.nodes.append(
        .init(
          id: "front", kind: .rectangle, x: 100, y: 80, width: 200, height: 120, fill: "#FF9933"))
      document.revision += 1
      fixture.view.render(document, time: 0, selectedID: nil, presentationGeneration: 7)
      #expect(fixture.view.currentSceneFocusProjection == nil)
      document.nodes.removeLast()
      document.nodes[0].fill = "transparent"
      document.revision += 1
      fixture.view.render(document, time: 0, selectedID: nil, presentationGeneration: 7)
      #expect(fixture.view.focusPoint(for: "shape") == nil)
      #expect(fixture.view.renderedDocumentRevision == document.revision)
    }
  }

  @Test func focusAndPendingLabelsShare512RaysAndReadingNilCannotRetry() throws {
    var document = bodyDocument()
    document.nodes.append(
      .init(
        id: "front", kind: .mesh,
        spatial3D: .init(
          transform: .init(position: .init(x: 0, y: 0, z: 2)),
          geometry: .box(width: 4, height: 4, depth: 0.4))))
    document.nodes += (0..<126).map { index in
      .init(
        id: "label-\(index)", kind: .text, text: "Part",
        spatial3D: .init(labelAnchor: .init(targetID: "body")))
    }
    let fixture = try Mounted(try document.validated())
    defer { fixture.close() }
    let camera = try #require(fixture.view.spatialStage?.pointOfView)
    camera.position = SCNVector3(0, 0, 8)
    camera.look(at: SCNVector3Zero)
    fixture.view.updateCameraProjection()
    #expect(fixture.view.focusPoint(for: "body") == nil)
    let rays = fixture.view.sceneFocusRayTests
    #expect(rays <= 33 && rays + fixture.view.labelAttachmentDiagnostics.rayTestsThisLayout <= 512)
    fixture.view.updateCameraProjection()
    #expect(fixture.view.sceneFocusRayTests == rays)
    for _ in 0..<100 { #expect(fixture.view.focusPoint(for: "body") == nil) }
    #expect(fixture.view.sceneFocusRayTests == rays)
  }

  @Test func reconciliationReoffersIdenticalRestoredNativePointWithoutNewRays() async throws {
    let fixture = try Mounted(try bodyDocument(withLabel: true).validated())
    defer { fixture.close() }
    var changes: [SceneFocusProjection?] = []
    fixture.view.onSceneFocusProjectionChanged = { changes.append($0) }
    let original = try #require(fixture.view.focusPoint(for: "body"))
    let rays = fixture.view.sceneFocusRayTests
    let body = try #require(fixture.view.spatialNode(id: "body"))
    body.isHidden = true
    SCNTransaction.flush()
    #expect(fixture.view.currentSceneFocusProjection == nil)
    body.isHidden = false
    SCNTransaction.flush()
    #expect(fixture.view.currentSceneFocusProjection == original)
    #expect(changes == [original])

    fixture.view.requestSceneFocusReconciliation()
    try await waitForNativeWork { changes.count == 2 && !fixture.view.needsDisplayClock }
    #expect(changes == [original, original])
    #expect(fixture.view.currentSceneFocusProjection == original)
    #expect(fixture.view.sceneFocusRayTests == rays)
    #expect(fixture.view.renderSubmissionSerial == original.renderSerial)
    try assertSurface(original, in: fixture)
    fixture.view.clearSceneFocus()
    let count = changes.count
    fixture.view.requestSceneFocusReconciliation()
    #expect(changes.count == count && fixture.view.currentSceneFocusProjection == nil)
  }

  @Test func hostCancellationCoalescesAndRecoversTheSameOwnedNativeProjection() async throws {
    let fixture = try FocusHost()
    defer { fixture.close() }
    try await waitForNativeWork(diagnostics: { fixture.diagnostics }) {
      fixture.cursor.sceneNodeVisitAuthority == fixture.authority
        && !fixture.canvas.needsDisplayClock
    }
    let original = try #require(fixture.canvas.currentSceneFocusProjection)
    let rays = fixture.canvas.sceneFocusRayTests
    fixture.driver.points.removeAll()
    let body = try #require(fixture.canvas.spatialNode(id: "body"))
    body.isHidden = true
    SCNTransaction.flush()
    let accepted = fixture.cursor.updateSceneNodeVisit(
      authority: fixture.authority, point: original.globalPoint)
    #expect(!accepted && fixture.cursor.sceneNodeVisitAuthority == nil)
    #expect(fixture.cursor.lastSceneNodeVisitEndReason == .hostBoundsUnavailable)
    #expect(fixture.model.explanationFocusIsCurrent(fixture.authority))
    body.isHidden = false
    SCNTransaction.flush()
    #expect(fixture.canvas.currentSceneFocusProjection == original)
    for _ in 0..<100 { fixture.overlay.reconcileSceneFocus(authority: fixture.authority) }
    try await waitForNativeWork(diagnostics: { fixture.diagnostics }) {
      fixture.cursor.sceneNodeVisitAuthority == fixture.authority
        && !fixture.canvas.needsDisplayClock
    }
    #expect(fixture.driver.points.count == 1)
    #expect(fixture.driver.points.first?.0 == fixture.authority)
    #expect(fixture.driver.points.first?.1 == original.globalPoint)
    #expect(fixture.cursor.sceneNodeVisitAuthority == fixture.authority)
    #expect(fixture.canvas.sceneFocusRayTests == rays)
    #expect(fixture.model.scene == fixture.presentation.document)
  }

  @Test func queuedRecoveryCannotReviveStoppedOrStillUnavailableFocus() async throws {
    for stop in [false, true] {
      let fixture = try FocusHost()
      defer { fixture.close() }
      try await waitForNativeWork(diagnostics: { fixture.diagnostics }) {
        fixture.cursor.sceneNodeVisitAuthority == fixture.authority
          && !fixture.canvas.needsDisplayClock
      }
      let original = try #require(fixture.canvas.currentSceneFocusProjection)
      let body = try #require(fixture.canvas.spatialNode(id: "body"))
      fixture.driver.points.removeAll()
      body.isHidden = true
      SCNTransaction.flush()
      let accepted = fixture.cursor.updateSceneNodeVisit(
        authority: fixture.authority, point: original.globalPoint)
      #expect(!accepted && fixture.cursor.sceneNodeVisitAuthority == nil)
      if stop {
        body.isHidden = false
        SCNTransaction.flush()
        fixture.model.stop()
      }
      await drainQueuedHostWork()
      try await waitForNativeWork(diagnostics: { fixture.diagnostics }) {
        !fixture.canvas.needsDisplayClock
      }
      #expect(fixture.driver.points.isEmpty)
      #expect(fixture.cursor.sceneNodeVisitAuthority == nil)
      if stop {
        #expect(!fixture.model.explanationFocusIsCurrent(fixture.authority))
      } else {
        #expect(fixture.model.explanationFocusIsCurrent(fixture.authority))
        #expect(fixture.canvas.currentSceneFocusProjection == nil)
      }
    }
  }

  @Test func staleGenerationBeatAndQueuedOldLeaseCannotReofferOrCancelNewFocus() async throws {
    let fixture = try FocusHost()
    defer { fixture.close() }
    try await waitForNativeWork(diagnostics: { fixture.diagnostics }) {
      fixture.cursor.sceneNodeVisitAuthority == fixture.authority
        && !fixture.canvas.needsDisplayClock
    }
    fixture.driver.points.removeAll()
    let old = fixture.authority
    for (generation, beat) in [
      (old.generation + 1, old.beatID), (old.generation, UUID()),
    ] {
      let stale = try SceneFocusAuthority.make(
        presentationLease: old.presentationLease, generation: generation, beatID: beat,
        document: fixture.presentation.document, focusID: "body")
      fixture.overlay.reconcileSceneFocus(authority: stale)
    }
    await drainQueuedHostWork()
    #expect(fixture.driver.points.isEmpty && fixture.cursor.sceneNodeVisitAuthority == old)

    fixture.overlay.reconcileSceneFocus(authority: old)
    let screen = try #require(NSScreen.main)
    fixture.overlay.show(document: fixture.presentation.document, on: screen)
    fixture.overlay.beginSceneFocus(
      context: .init(generation: old.generation, narrationID: old.beatID),
      presentation: fixture.presentation)
    let replacement = try SceneFocusAuthority.make(
      presentationLease: try #require(fixture.overlay.presentationLease),
      generation: old.generation, beatID: old.beatID,
      document: fixture.presentation.document, focusID: "body")
    let currentCanvas = try #require(
      NSApp.windows.lazy.compactMap { $0.contentView as? RetainedCanvasView }.first {
        $0.window?.isVisible == true && $0.renderedDocumentID == replacement.documentID
      })
    currentCanvas.spatialNode(id: "body")?.removeAllAnimations()
    SCNTransaction.flush()
    currentCanvas.requestSceneFocusReconciliation()
    try await waitForNativeWork(diagnostics: { fixture.diagnostics }) {
      fixture.cursor.sceneNodeVisitAuthority == replacement && !currentCanvas.needsDisplayClock
    }
    #expect(replacement != old)
    fixture.driver.points.removeAll()
    fixture.overlay.reconcileSceneFocus(authority: old)
    await drainQueuedHostWork()
    #expect(fixture.driver.points.isEmpty)
    #expect(fixture.cursor.sceneNodeVisitAuthority == replacement)
  }

  @Test func reentrantHostReadMissReoffersOnAnotherNativeFrameWithoutRecursion() async throws {
    let fixture = try FocusHost()
    defer { fixture.close() }
    try await waitForNativeWork(diagnostics: { fixture.diagnostics }) {
      fixture.cursor.sceneNodeVisitAuthority == fixture.authority
        && !fixture.canvas.needsDisplayClock
    }
    let original = try #require(fixture.canvas.currentSceneFocusProjection)
    let rays = fixture.canvas.sceneFocusRayTests
    let body = try #require(fixture.canvas.spatialNode(id: "body"))
    fixture.driver.points.removeAll()
    body.isHidden = true
    SCNTransaction.flush()
    let accepted = fixture.cursor.updateSceneNodeVisit(
      authority: fixture.authority, point: original.globalPoint)
    #expect(!accepted && fixture.cursor.sceneNodeVisitAuthority == nil)
    body.isHidden = false
    SCNTransaction.flush()
    var reads = 0
    var injectedReadMiss = false
    fixture.cursor.sceneNodeVisitBounds = { [weak overlay = fixture.overlay] authority in
      reads += 1
      // The first read admits the reoffered visit. Its render then observes one
      // unavailable native point and must fail closed before requesting again.
      if reads == 2 {
        injectedReadMiss = true
        return nil
      }
      return overlay?.sceneNodeVisitBounds(authority: authority)
    }
    try await waitForNativeWork(diagnostics: { fixture.diagnostics }) {
      fixture.driver.points.count >= 2
        && fixture.cursor.sceneNodeVisitAuthority == fixture.authority
        && !fixture.canvas.needsDisplayClock
    }
    #expect(injectedReadMiss && fixture.driver.points.count == 2)
    #expect(fixture.driver.points.allSatisfy { $0.0 == fixture.authority })
    #expect(fixture.canvas.sceneFocusRayTests == rays)
    #expect(fixture.canvas.currentSceneFocusProjection == original)
  }

  private func waitForNativeWork(
    diagnostics: () -> String = { "" }, _ condition: () -> Bool
  ) async throws {
    let deadline = ProcessInfo.processInfo.systemUptime + 2
    while !condition(), ProcessInfo.processInfo.systemUptime < deadline {
      try await Task.sleep(for: .milliseconds(2))
    }
    #expect(
      condition(),
      Comment(rawValue: "The bounded native focus work did not settle. " + diagnostics()))
  }

  private func drainQueuedHostWork() async {
    // Reconciliation is one queued native-host task, not a wall-clock retry.
    for _ in 0..<20 { await Task.yield() }
  }

  private func bodyDocument(withLabel: Bool = false) -> SceneDocument {
    var document = SceneDocument(
      id: "public-focus", revision: 3,
      nodes: [
        .init(
          id: "body", kind: .mesh, fill: "#4488CC", spatial3D: .init(geometry: .sphere(radius: 0.8))
        )
      ])
    if withLabel {
      document.nodes.append(
        .init(
          id: "label", kind: .text, text: "Body",
          spatial3D: .init(labelAnchor: .init(targetID: "body"))))
    }
    return document
  }

  private func assertSurface(_ projection: SceneFocusProjection, in fixture: Mounted) throws {
    let stage = try #require(fixture.view.spatialStage)
    let base = fixture.panel.convertPoint(fromScreen: projection.globalPoint)
    let canvas = fixture.view.convert(base, from: nil)
    let point = stage.convert(canvas, from: fixture.view)
    let hit = try #require(
      stage.hitTest(
        point,
        options: [
          .searchMode: SCNHitTestSearchMode.closest.rawValue, .boundingBoxOnly: false,
          .clipToZRange: true, .backFaceCulling: true, .ignoreHiddenNodes: true,
          .categoryBitMask: 1,
        ]
      ).first)
    #expect(hit.node === fixture.view.spatialNode(id: projection.surfaceNodeID))
  }

  private final class Panel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
  }

  @MainActor private final class FocusHost {
    final class Driver {
      var points: [(SceneFocusAuthority, CGPoint)] = []
    }
    let driver: Driver
    let model: AppModel
    let overlay: ExplanationOverlay
    let cursor: CursorCompanionCoordinator
    let canvas: RetainedCanvasView
    let presentation: ExplanationPresentation
    let authority: SceneFocusAuthority

    var diagnostics: String {
      let clock =
        (try? JSONEncoder().encode(canvas.displayClockDiagnostics))
        .flatMap { String(data: $0, encoding: .utf8) } ?? "unavailable"
      return "clock=" + clock + "; visit=" + (cursor.sceneNodeVisitAuthority?.focusID ?? "nil")
        + "; end=" + (cursor.lastSceneNodeVisitEndReason?.rawValue ?? "nil")
        + "; modelCurrent=\(model.explanationFocusIsCurrent(authority))"
        + "; bounds=\(overlay.sceneNodeVisitBounds(authority: authority) != nil)"
        + "; projection=\(canvas.currentSceneFocusProjection?.targetID ?? "nil")"
        + "; needsClock=\(canvas.needsDisplayClock)"
        + "; offers=\(driver.points.count)"
    }

    init() throws {
      _ = NSApplication.shared
      let screen = try #require(NSScreen.main)
      let driver = Driver()
      self.driver = driver
      let model = AppModel(
        acceptanceMode: true, voice: VoiceService(nativeSpeak: { _ in }, nativeStop: {}))
      self.model = model
      model.configuration.speechEnabled = false
      model.playing = false
      model.configureResponseOutput(.init(route: .notebook, includesExistingNotebook: false))
      let overlay = ExplanationOverlay(model: model, observeOrbitInput: false) { model.stop() }
      self.overlay = overlay
      let cursor = CursorCompanionCoordinator(
        model: model, observePointer: false, preferences: .init())
      self.cursor = cursor
      cursor.beginResponse(generation: model.taskGeneration)
      cursor.pointerMoved(to: CGPoint(x: screen.visibleFrame.midX, y: screen.visibleFrame.midY))
      model.onNarrationCaptionStarted = { _, _, _ in true }
      model.onCursorCancelled = { [weak cursor] in cursor?.cancel(generation: $0) }
      model.onExplanationFocusStarted = { [weak overlay] context, presentation in
        overlay?.beginSceneFocus(context: context, presentation: presentation)
      }
      model.onExplanationFocusEnded = { [weak overlay] in overlay?.endSceneFocus(context: $0) }
      cursor.sceneNodeVisitBounds = { [weak overlay] in overlay?.sceneNodeVisitBounds(authority: $0)
      }
      cursor.onSceneNodeVisitEnded = { [weak overlay] authority, reason in
        if reason == .hostBoundsUnavailable { overlay?.reconcileSceneFocus(authority: authority) }
      }
      overlay.onSceneFocusPoint = { [weak cursor] authority, point in
        driver.points.append((authority, point))
        _ = cursor?.visitSceneNode(authority: authority, point: point)
      }
      overlay.onSceneFocusEnded = { [weak cursor] in cursor?.cancelSceneNodeVisit(authority: $0) }
      try model.accept(
        .init(
          type: "scene",
          nodes: [
            .init(
              id: "body", kind: .mesh, fill: "#4488CC",
              spatial3D: .init(geometry: .sphere(radius: 0.8))),
            .init(
              id: "label", kind: .text, text: "Body",
              spatial3D: .init(labelAnchor: .init(targetID: "body"))),
          ], narration: "A public test part remains in view.", focusID: "body"),
        generation: model.taskGeneration, expectedEvidence: nil)
      let presentation = try #require(model.explanationPresentation)
      self.presentation = presentation
      overlay.show(document: presentation.document, on: screen)
      let canvas = try #require(
        NSApp.windows.lazy.compactMap { $0.contentView as? RetainedCanvasView }.first {
          $0.window?.isVisible == true && $0.renderedDocumentID == presentation.document.id
        })
      self.canvas = canvas
      for node in presentation.document.nodes {
        canvas.spatialNode(id: node.id)?.removeAllAnimations()
      }
      SCNTransaction.flush()
      canvas.requestSceneFocusReconciliation()
      authority = try SceneFocusAuthority.make(
        presentationLease: try #require(overlay.presentationLease),
        generation: presentation.generation, beatID: presentation.beatID,
        document: presentation.document, focusID: "body")
    }

    func close() {
      model.stop()
      overlay.shutdown()
      cursor.shutdown()
      model.onExplanationFocusStarted = nil
      model.onExplanationFocusEnded = nil
      model.onNarrationCaptionStarted = nil
      model.onCursorCancelled = nil
    }
  }
  @MainActor private final class Mounted {
    let panel: Panel
    let view: RetainedCanvasView
    init(_ document: SceneDocument) throws {
      _ = NSApplication.shared
      let screen = try #require(NSScreen.main)
      panel = Panel(
        contentRect: CGRect(
          x: screen.visibleFrame.minX + 20, y: screen.visibleFrame.minY + 20, width: 620,
          height: 420),
        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
      panel.isReleasedWhenClosed = false
      panel.sharingType = .none
      panel.ignoresMouseEvents = true
      view = RetainedCanvasView(
        frame: CGRect(x: 0, y: 0, width: 620, height: 420), motionPolicy: .reducedMotion)
      view.presentation = .passiveOverlay
      panel.contentView = view
      panel.orderFrontRegardless()
      let rendered = view.render(document, time: 0, selectedID: nil, presentationGeneration: 7)
      #expect(rendered)
      view.layoutSubtreeIfNeeded()
      SCNTransaction.flush()
    }
    func close() {
      view.stopDisplayLink()
      panel.orderOut(nil)
      panel.contentView = nil
      panel.close()
    }
  }
}
