import AppKit
import CompanionCore
import SceneKit
import simd

/// Explicit own-window/native-renderer check. Authored event objects go only
/// to this app's own view; no system input is posted. It never captures the
/// desktop, starts a provider, or records/plays audio.
@MainActor enum ExplanationOverlayAcceptance {
  @MainActor static func run(model: AppModel, output: URL, documentURL: URL? = nil) async throws {
    try Task.checkCancellation()
    guard
      let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) })
        ?? NSScreen.main
    else { throw ProviderError.message("No display is available for explanation acceptance.") }
    let document: SceneDocument
    if let documentURL {
      let handle = try FileHandle(forReadingFrom: documentURL)
      defer { try? handle.close() }
      guard let bytes = try handle.read(upToCount: 2_000_001),
        !bytes.isEmpty, bytes.count <= 2_000_000
      else { throw ProviderError.message("The authored scene JSON exceeds the acceptance limit.") }
      document = try JSONDecoder().decode(SceneDocument.self, from: bytes).validated()
    } else {
      document = try fixture().validated()
    }
    guard document.nodes.contains(where: { $0.spatial3D?.geometry != nil }),
      document.nodes.contains(where: { $0.spatial3D?.labelAnchor?.leader == true })
    else {
      throw ProviderError.message("The scene needs typed geometry and a label with a leader.")
    }
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    let foreground = NSWorkspace.shared.frontmostApplication?.processIdentifier
    let originalMessages = model.messages.map(\.id)
    model.configuration.speechEnabled = false
    model.playing = false
    let overlay = ExplanationOverlay(model: model, observeOrbitInput: false) { model.stop() }
    defer { overlay.shutdown() }

    // An empty streamed assembly arms the document without exposing a stage or
    // Clear control. The first renderable same-document update mounts it.
    let empty = SceneDocument(
      id: document.id, title: document.title, width: document.width, height: document.height,
      nodes: [SceneNode(id: "pending-assembly", kind: .group, spatial3D: .init())])
    model.scene = empty
    overlay.show(document: empty, on: screen)
    guard !overlay.isVisible(documentID: document.id),
      !NSApp.windows.contains(where: {
        $0.isVisible && $0.identifier?.rawValue == "org.opencompanion.explanation.clear"
      })
    else { throw ProviderError.message("An empty assembly exposed explanation controls.") }
    model.scene = document
    let mountDeadline = ProcessInfo.processInfo.systemUptime + 4
    while !overlay.isVisible(documentID: document.id) {
      try Task.checkCancellation()
      guard ProcessInfo.processInfo.systemUptime < mountDeadline else {
        throw ProviderError.message("The first renderable scene did not mount within the bound.")
      }
      try await Task.sleep(for: .milliseconds(20))
    }
    let (visual, clear, canvas) = try ownPresentation(document: document, overlay: overlay)
    guard !visual.ignoresMouseEvents, canvas.overlaySurfaceInteractive, !clear.ignoresMouseEvents,
      !visual.canBecomeKey, !clear.canBecomeKey, visual.sharingType == .none,
      clear.sharingType == .none, !visual.isOpaque,
      canvas.overlayTrayEnabled, canvas.layer?.backgroundColor?.alpha == 1,
      visual.frame.contains(clear.frame),
      canvas.spatialStage?.allowsCameraControl == false,
      NSWorkspace.shared.frontmostApplication?.processIdentifier == foreground
    else {
      throw ProviderError.message("The native presentation changed focus or input ownership.")
    }
    let labelClockStarted = ProcessInfo.processInfo.systemUptime
    func saveClockDiagnostics(_ stage: String) throws {
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      try encoder.encode(canvas.displayClockDiagnostics).write(
        to: output.appendingPathComponent("clock-\(stage).json"), options: .atomic)
    }
    try saveClockDiagnostics("initial")
    let pendingAtObservation = canvas.hasPendingSpatialLabels
    let prefixSnapshotStarted = ProcessInfo.processInfo.systemUptime
    if pendingAtObservation {
      try write(canvas.explanationSnapshot(), to: output.appendingPathComponent("label-prefix.png"))
    }
    let prefixSnapshotMS = (ProcessInfo.processInfo.systemUptime - prefixSnapshotStarted) * 1_000
    try saveClockDiagnostics("after-prefix-snapshot")
    // Exercise the actual native clock with scene playback paused. Never
    // manually fast-forward labels to make a final-pixel check pass.
    // A synchronous diagnostic snapshot cannot deliver MainActor callbacks;
    // measure that cost separately from the bounded asynchronous settle wait.
    let settleWaitStarted = ProcessInfo.processInfo.systemUptime
    while canvas.hasPendingSpatialLabels || canvas.hasPendingLabelAttachments {
      try Task.checkCancellation()
      guard ProcessInfo.processInfo.systemUptime - settleWaitStarted < 12 else {
        try saveClockDiagnostics("timeout")
        throw ProviderError.message(
          "The native label reveal or surface attachment failed to settle within 12 seconds.")
      }
      try await Task.sleep(for: .milliseconds(20))
    }
    let labelSettleWaitMS = (ProcessInfo.processInfo.systemUptime - settleWaitStarted) * 1_000
    try await Task.sleep(for: .milliseconds(400))
    try saveClockDiagnostics("settled")
    guard !canvas.isDisplayClockRunning else {
      throw ProviderError.message("A paused explanation kept its settled label clock running.")
    }
    let labelClockSettledMS = (ProcessInfo.processInfo.systemUptime - labelClockStarted) * 1_000
    let stage = try require(canvas.spatialStage, "No native SceneKit stage was mounted.")
    let originalLeaderStarts = try verifyLeaderAttachments(
      document: document, currentDocument: model.scene, canvas: canvas, stage: stage,
      phase: "initial", output: output)
    let targetOpacity = Dictionary(
      uniqueKeysWithValues: try document.spatialWorldPoses(at: 0).map {
        ($0.node.id, $0.effectiveOpacity)
      })
    let expectedLabels = document.nodes.filter {
      guard let anchor = $0.spatial3D?.labelAnchor else { return false }
      return !$0.text.isEmpty && $0.opacity > 0 && (targetOpacity[anchor.targetID] ?? 0) > 0
    }
    guard expectedLabels.count <= 128 else {
      throw ProviderError.message("The own-view label pixel check exceeds its128-label limit.")
    }
    let visibleFrames = canvas.projectedLabelFrames
    let documentBounds = CGRect(x: 0, y: 0, width: document.width, height: document.height)
    guard canvas.unresolvedLabelOverlapCount == 0,
      expectedLabels.allSatisfy({ label in
        guard let frame = visibleFrames[label.id] else { return false }
        return documentBounds.contains(frame)
          && canvas.projectedLabelText(id: label.id) == label.text
      })
    else {
      throw ProviderError.message(
        "The final native view has hidden, incomplete, overlapping or out-of-bounds labels.")
    }
    let labelFrames = expectedLabels.compactMap { visibleFrames[$0.id] }
    for first in labelFrames.indices {
      for second in labelFrames.indices where second > first {
        let intersection = labelFrames[first].intersection(labelFrames[second])
        guard intersection.isNull || intersection.isEmpty else {
          throw ProviderError.message("The final native label rectangles overlap.")
        }
      }
    }
    let label = try require(
      document.nodes.first(where: { $0.spatial3D?.labelAnchor?.leader == true }),
      "No leader-enabled label was requested in the native viewport.")
    let initial = try requireFrame(canvas.projectedLabelFrame(id: label.id))
    let meshSnapshot = try require(
      stage.snapshot().tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)),
      "Native SceneKit did not produce a snapshot.")
    let meshCoverage = coverage(meshSnapshot)
    guard meshCoverage.visible > 500, meshCoverage.transparent > 500 else {
      throw ProviderError.message(
        "The native 3D snapshot lacks geometry or transparent background.")
    }
    let baseline = try canvas.explanationSnapshot(includeSpatialLabels: false)
    let composite = try canvas.explanationSnapshot()
    try write(composite, to: output.appendingPathComponent("explanation.png"))
    let finalCoverage = coverage(composite)
    let backdropVisible = opaqueTrayBackdrop(composite, canvasSize: canvas.bounds.size)
    let geometryPixels = matchingGeometryPixels(
      meshSnapshot, composite: baseline, stageFrame: stage.frame, canvasSize: canvas.bounds.size)
    let labelFrame = canvas.canvasFrame(forDocumentRect: initial)
    let leaderPath = try require(
      canvas.projectedLeaderPath(id: label.id), "The first projected label has no leader.")
    let leaderFrame = canvas.canvasFrame(forDocumentRect: leaderPath.boundingBoxOfPath)
    let labelPixels = changedPixels(
      composite, baseline: baseline, in: labelFrame, canvasSize: canvas.bounds.size)
    let leaderPixels = changedPixels(
      composite, baseline: baseline, in: leaderFrame.insetBy(dx: -2, dy: -2),
      canvasSize: canvas.bounds.size, excluding: labelFrame.insetBy(dx: -1, dy: -1))
    let geometryMatchFraction =
      geometryPixels.samples > 0
      ? Double(geometryPixels.matches) / Double(geometryPixels.samples) : nil
    var perLabelMetrics: [[String: Any]] = []
    var everyLabelCompleteWithPixels = true
    for label in expectedLabels {
      let layout = canvas.projectedLabelGlyphLayout(id: label.id)
      let frame = visibleFrames[label.id].map(canvas.canvasFrame(forDocumentRect:)) ?? .zero
      // Leader endpoints terminate at the rectangle's edge. Its interior is
      // the glyph check; this remains a difference-pixel test, not OCR.
      let interior = frame.insetBy(dx: 1.5, dy: 1.5)
      let pixels =
        interior.width > 0 && interior.height > 0
        ? changedPixels(composite, baseline: baseline, in: interior, canvasSize: canvas.bounds.size)
        : 0
      let complete = layout?.isComplete == true
      everyLabelCompleteWithPixels = everyLabelCompleteWithPixels && complete && pixels >= 12
      perLabelMetrics.append([
        "id": label.id, "utf16Count": layout?.utf16Count ?? 0,
        "visibleUTF16Location": layout?.visibleUTF16Location ?? -1,
        "visibleUTF16Count": layout?.visibleUTF16Count ?? 0,
        "coreTextLayoutComplete": complete, "interiorDifferencePixels": pixels,
        "canvasFrame": metricFrame(frame),
      ])
    }
    let finalCompositeMetrics: [String: Any] = [
      "schemaVersion": 1, "phase": "before-final-composite-guard",
      "ownViewOnly": true, "desktopCaptured": false,
      "typedMeshCount": document.nodes.filter { $0.spatial3D?.geometry != nil }.count,
      "expectedAnchoredLabelCount": expectedLabels.count,
      "projectedLabelFrameCount": visibleFrames.count,
      "requestedLeaderCount": document.nodes.filter { $0.spatial3D?.labelAnchor?.leader == true }
        .count,
      "meshVisiblePixels": meshCoverage.visible,
      "meshTransparentPixels": meshCoverage.transparent,
      "finalVisiblePixels": finalCoverage.visible,
      "finalTransparentPixels": finalCoverage.transparent,
      "geometrySamples": geometryPixels.samples, "geometryMatches": geometryPixels.matches,
      "geometryMatchFraction": geometryMatchFraction.map { $0 as Any } ?? NSNull(),
      "geometrySamplingMethod": geometryPixels.method.rawValue,
      "geometryViewportGridSamples": geometryPixels.gridSamples,
      "geometryViewportGridMatches": geometryPixels.gridMatches,
      "geometryOpaqueNativePixels": geometryPixels.opaqueNativePixels.map { $0 as Any } ?? NSNull(),
      "geometryRawAlphaPixelsVisited": geometryPixels.alphaPixelsVisited,
      "geometrySelectedNativePixels": geometryPixels.selectedNativePixels,
      "labelPixels": labelPixels, "leaderPixels": leaderPixels,
      "allLabelMetrics": perLabelMetrics,
      "labelMetricScope":
        "Actual retained-font CoreText capacity and own-composite interior difference pixels; not OCR or physical scanout.",
      "predicates": [
        "finalVisibleOver500": finalCoverage.visible > 500,
        "opaqueTrayBackdropVisible": backdropVisible,
        "geometrySamplesAtLeast20": geometryPixels.samples >= 20,
        "geometryMatchFractionAtLeast0_65": geometryMatchFraction.map { $0 >= 0.65 } ?? false,
        "labelPixelsAtLeast12": labelPixels >= 12,
        "everyLabelCompleteWithPixels": everyLabelCompleteWithPixels,
        "leaderPixelsAtLeast6": leaderPixels >= 6,
      ],
      "frames": [
        "visualWindowGlobalAppKit": metricFrame(visual.frame),
        "canvasBounds": metricFrame(canvas.bounds),
        "stageFrameInCanvas": metricFrame(stage.frame),
        "stageBounds": metricFrame(stage.bounds),
        "sampledLabelDocumentFrame": metricFrame(initial),
        "sampledLabelCanvasFrame": metricFrame(labelFrame),
        "sampledLeaderDocumentBounds": metricFrame(leaderPath.boundingBoxOfPath),
        "sampledLeaderCanvasBounds": metricFrame(leaderFrame),
        "leaderSampleCanvasFrame": metricFrame(leaderFrame.insetBy(dx: -2, dy: -2)),
        "leaderExcludedCanvasFrame": metricFrame(labelFrame.insetBy(dx: -1, dy: -1)),
      ],
      "bitmaps": [
        "nativeMesh": bitmapMetrics(meshSnapshot),
        "baselineWithoutSpatialLabels": bitmapMetrics(baseline),
        "finalComposite": bitmapMetrics(composite),
      ],
    ]
    let finalCompositeMetricBytes = try JSONSerialization.data(
      withJSONObject: finalCompositeMetrics, options: [.prettyPrinted, .sortedKeys])
    guard finalCompositeMetricBytes.count <= 16_384 else {
      throw ProviderError.message("The content-free final composite diagnostic exceeded its bound.")
    }
    try finalCompositeMetricBytes.write(
      to: output.appendingPathComponent("final-composite-metrics.json"), options: .atomic)
    guard finalCoverage.visible > 500, backdropVisible,
      geometryPixels.samples >= 20,
      Double(geometryPixels.matches) / Double(geometryPixels.samples) >= 0.65,
      labelPixels >= 12, leaderPixels >= 6, everyLabelCompleteWithPixels
    else {
      throw ProviderError.message(
        "The final native composite lacks correctly placed geometry, label glyphs, leaders or its readable tray backdrop."
      )
    }
    let camera = try require(stage.pointOfView, "The native stage has no camera.")
    let before = camera.position
    camera.position = SCNVector3(before.x + 1.5, before.y + 0.7, before.z)
    camera.look(at: stage.defaultCameraController.target)
    canvas.updateCameraProjection()
    let cameraSurfaceWaitStarted = ProcessInfo.processInfo.systemUptime
    while canvas.hasPendingLabelAttachments {
      try Task.checkCancellation()
      guard ProcessInfo.processInfo.systemUptime - cameraSurfaceWaitStarted < 4 else {
        throw ProviderError.message(
          "Surface attachments did not settle after native camera motion.")
      }
      try await Task.sleep(for: .milliseconds(20))
    }
    let cameraSurfaceSettleWaitMS =
      (ProcessInfo.processInfo.systemUptime - cameraSurfaceWaitStarted) * 1_000
    let movedLeaderStarts = try verifyLeaderAttachments(
      document: document, currentDocument: model.scene, canvas: canvas, stage: stage,
      phase: "after-camera", output: output)
    var movedLeaderCount = 0
    for (id, old) in originalLeaderStarts {
      let point = try require(
        movedLeaderStarts[id], "A requested leader disappeared after native camera motion.")
      if hypot(old.x - point.x, old.y - point.y) > 0.05 { movedLeaderCount += 1 }
    }
    let verifiedLeaderCount = movedLeaderStarts.count
    guard verifiedLeaderCount > 0, movedLeaderCount > 0 else {
      throw ProviderError.message(
        "No visible leader followed the changed native camera projection.")
    }
    let movedLabelFrames = canvas.projectedLabelFrames.filter { id, frame in
      guard let old = visibleFrames[id] else { return false }
      return hypot(old.midX - frame.midX, old.midY - frame.midY) > 0.05
    }.count
    try write(
      canvas.explanationSnapshot(), to: output.appendingPathComponent("camera-projection.png"))
    let localOrbitCPU = try await measureLocalOrbitCPU(canvas)

    let stale = try require(overlay.presentationLease, "Missing presentation authority.")
    overlay.dismiss()
    guard !visual.isVisible, !clear.isVisible,
      visual.contentView == nil, clear.contentView == nil
    else { throw ProviderError.message("Dismiss left an original native window mounted.") }
    overlay.show(document: document, on: screen)
    let (renewedVisual, renewedClear, _) = try ownPresentation(document: document, overlay: overlay)
    let current = try require(overlay.presentationLease, "Missing renewed presentation authority.")
    let generation = model.taskGeneration
    overlay.clearPresentation(lease: stale, documentID: document.id)
    guard current != stale, overlay.isVisible(documentID: document.id),
      model.taskGeneration == generation
    else { throw ProviderError.message("A stale Clear action affected the renewed presentation.") }
    overlay.clearPresentation(lease: current, documentID: document.id)
    guard !overlay.isVisible(documentID: document.id),
      !renewedVisual.isVisible, !renewedClear.isVisible,
      renewedVisual.contentView == nil, renewedClear.contentView == nil,
      model.scene == document,
      model.taskGeneration > generation, model.messages.map(\.id) == originalMessages,
      NSWorkspace.shared.frontmostApplication?.processIdentifier == foreground
    else { throw ProviderError.message("Clear changed the retained scene, transcript or focus.") }
    let syntheticOrbit = try await verifySyntheticOrbit(
      model: model, overlay: overlay, screen: screen, foreground: foreground, output: output)
    guard model.scene == document, model.messages.map(\.id) == originalMessages else {
      throw ProviderError.message("Synthetic orbit acceptance changed the retained original scene.")
    }
    let result: [String: Any] = [
      "result": "passed", "nativeOwnWindowAndViewOnly": true,
      "loadedSceneJSON": documentURL != nil,
      "typedMeshCount": document.nodes.filter {
        $0.spatial3D?.geometry != nil
      }.count,
      "anchoredLabelCount": document.nodes.filter { $0.spatial3D?.labelAnchor != nil }.count,
      "visibleCompleteLabelCount": expectedLabels.count,
      "allLabelMetrics": perLabelMetrics,
      "allFinalLabelCoreTextLayoutsComplete": true,
      "allFinalLabelInteriorsHaveDifferencePixels": true,
      "labelGlyphIdentityOrPhysicalScanoutVerified": false,
      "overlappingLabelPairs": 0,
      "emptyFirstGroupRemainedHidden": true, "visualWindowEntirelyClickThrough": false,
      "opaqueTrayBackdropVisible": backdropVisible,
      "clearControlInsideTray": visual.frame.contains(clear.frame),
      "visualWindowClickThroughScope":
        "The visible bounded tray owns local input; no global scrolling is captured.",
      "clearControlBounded": [clear.frame.width, clear.frame.height],
      "transparentMeshPixels": meshCoverage.transparent,
      "visibleMeshPixels": meshCoverage.visible,
      "finalCompositeVisiblePixels": finalCoverage.visible,
      "finalCompositeTransparentPixels": finalCoverage.transparent,
      "compositeGeometrySamples": geometryPixels.samples,
      "compositeGeometryMatches": geometryPixels.matches,
      "projectedLabelChangedPixels": labelPixels,
      "projectedLeaderChangedPixels": leaderPixels,
      "pendingLabelsObserved": pendingAtObservation,
      "nativeLabelClockSettledMS": labelClockSettledMS,
      "prefixSnapshotMS": prefixSnapshotMS, "labelSettleWaitMS": labelSettleWaitMS,
      "nativeLabelsSettledWithScenePaused": true,
      "manualLabelClockAdvanceUsed": false,
      "cameraProjectionProgrammaticallyChanged": true, "physicalOrbitTested": false,
      "localOrbitCPU": localOrbitCPU,
      "syntheticOwnViewOrbit": syntheticOrbit,
      "windowServerOrbitInputTested": false,
      "cameraSurfaceSettleWaitMS": cameraSurfaceSettleWaitMS,
      "nativeLeaderAnchorsVerifiedAfterCameraMotion": verifiedLeaderCount,
      "nativeLeaderSurfacesVerifiedBeforeCameraMotion": originalLeaderStarts.count,
      "allRequestedLeadersResolved": true,
      "canonicalRequestedAnchorsUnchanged": true,
      "wholeSceneClosestTriangleOwnershipVerified": true,
      "surfaceAttachmentReceipts": ["attachments-initial.json", "attachments-after-camera.json"],
      "movedLeaderAnchorCount": movedLeaderCount, "movedLabelFrameCount": movedLabelFrames,
      "staleClearIgnored": true, "retainedSceneAfterClear": true,
      "renewedWindowsHiddenAndUnmountedAfterClear": true,
      "clearActionInvokedThroughController": true, "physicalClearClickTested": false,
      "foregroundPreserved": true, "desktopCapture": false, "providerCalled": false,
      "microphoneUsed": false, "audioUsed": false, "windowServerCapture": false,
      "fpsMeasured": false,
    ]
    try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
      .write(to: output.appendingPathComponent("explanation-acceptance.json"))
  }

  /// A separate asymmetric authored object avoids turning legitimate occlusion
  /// of a complex lesson into a false failure of the input-ownership check.
  private static func verifySyntheticOrbit(
    model: AppModel, overlay: ExplanationOverlay, screen: NSScreen,
    foreground: pid_t?, output: URL
  ) async throws -> [String: Any] {
    let retained = model.scene
    let messageIDs = model.messages.map(\.id)
    let document = try syntheticOrbitFixture().validated()
    var diagnostics: [String: ExplanationOrbitDiagnostics] = [:]
    defer {
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      if let bytes = try? encoder.encode(diagnostics), bytes.count <= 64_000 {
        try? bytes.write(
          to: output.appendingPathComponent("synthetic-orbit-diagnostics.json"), options: .atomic)
      }
      overlay.dismiss()
      model.scene = retained
    }
    model.scene = document
    overlay.show(document: document, on: screen)
    let (visual, clear, canvas) = try ownPresentation(document: document, overlay: overlay)
    let controller = try require(
      overlay.orbitControllerForAcceptance, "The synthetic orbit controller is unavailable.")
    try await settleOrbitLabels(canvas)
    let stage = try require(canvas.spatialStage, "The authored orbit stage is missing.")
    let camera = try require(stage.pointOfView, "The authored orbit camera is missing.")
    let point = try orbitPoint(canvas: canvas, stage: stage)
    let pointer = orbitScreenPoint(point, canvas: canvas, panel: visual)
    let before = camera.simdWorldTransform
    diagnostics["initial"] = controller.diagnostics
    guard !visual.ignoresMouseEvents, canvas.overlaySurfaceInteractive, !canvas.overlayCameraArmed,
      controller.diagnostics.phase == "passive", !controller.diagnostics.tapEnabled,
      !visual.canBecomeKey, !clear.canBecomeKey, !canvas.acceptsFirstResponder,
      stage.acceptsFirstResponder == false, stage.allowsCameraControl == false,
      visual.frame.width <= ExplanationOverlayLayout.maximumStageSize.width,
      visual.frame.height <= ExplanationOverlayLayout.maximumStageSize.height
    else { throw ProviderError.message("The authored orbit stage was not passive and bounded.") }

    controller.reconcileForAcceptance(pointer: pointer, modifiers: [], buttons: [])
    canvas.mouseDown(with: try orbitMouse(.leftMouseDown, at: point, canvas: canvas))
    guard !canvas.isOverlayCameraDragging, controller.diagnostics.starts == 0,
      camera.simdWorldTransform == before
    else { throw ProviderError.message("A passive view acquired a synthetic drag.") }
    controller.reconcileForAcceptance(
      pointer: CGPoint(x: visual.frame.minX - 20, y: visual.frame.minY - 20),
      modifiers: .option, buttons: [])
    guard !visual.ignoresMouseEvents, controller.diagnostics.phase == "passive" else {
      throw ProviderError.message("Option away from visible geometry acquired the panel.")
    }
    controller.reconcileForAcceptance(
      pointer: pointer, modifiers: [.control, .option], buttons: [])
    guard visual.ignoresMouseEvents, controller.diagnostics.phase == "passive" else {
      throw ProviderError.message("The voice modifier chord armed orbit.")
    }
    controller.reconcileForAcceptance(pointer: pointer, modifiers: .option, buttons: [])
    diagnostics["armed"] = controller.diagnostics
    guard !visual.ignoresMouseEvents, canvas.overlayCameraArmed,
      controller.diagnostics.phase == "armed", controller.diagnostics.tapEnabled == false
    else { throw ProviderError.message("Explicit synthetic Option did not arm the bounded panel.") }
    // Actual own-event modifiers must veto even when the previous observation
    // was Option only. Nothing is sent through WindowServer or another app.
    canvas.mouseDown(
      with: try orbitMouse(
        .leftMouseDown, at: point, canvas: canvas, flags: [.control, .option]))
    guard !canvas.isOverlayCameraDragging, controller.diagnostics.starts == 0,
      !canvas.overlayCameraArmed
    else { throw ProviderError.message("A Control+Option mouse-down escaped the host veto.") }
    controller.reconcileForAcceptance(pointer: pointer, modifiers: .option, buttons: [])
    let beforeLeaders = try verifyLeaderAttachments(
      document: document, currentDocument: model.scene, canvas: canvas, stage: stage,
      phase: "synthetic-orbit-before", output: output)
    try write(
      canvas.explanationSnapshot(), to: output.appendingPathComponent("synthetic-orbit-before.png"))
    canvas.mouseDown(with: try orbitMouse(.leftMouseDown, at: point, canvas: canvas))
    guard canvas.isOverlayCameraDragging, controller.diagnostics.phase == "dragging",
      controller.diagnostics.starts == 1
    else { throw ProviderError.message("The own-view Option mouse-down did not begin orbit.") }
    let moved = CGPoint(x: point.x + 55, y: point.y + 18)
    controller.reconcileForAcceptance(
      pointer: orbitScreenPoint(moved, canvas: canvas, panel: visual), modifiers: .option,
      buttons: .left)
    canvas.mouseDragged(with: try orbitMouse(.leftMouseDragged, at: moved, canvas: canvas))
    canvas.mouseUp(with: try orbitMouse(.leftMouseUp, at: moved, canvas: canvas))
    controller.reconcileForAcceptance(pointer: pointer, modifiers: [], buttons: [])
    diagnostics["after-drag"] = controller.diagnostics
    guard camera.simdWorldTransform != before, !canvas.isOverlayCameraDragging,
      canvas.overlayCameraDragEventCount == 1, controller.diagnostics.starts == 1,
      controller.diagnostics.ends == 1, !visual.ignoresMouseEvents, !canvas.overlayCameraArmed,
      stage.defaultCameraController.isInertiaRunning == false,
      model.scene == document, model.messages.map(\.id) == messageIDs,
      NSWorkspace.shared.frontmostApplication?.processIdentifier == foreground
    else {
      throw ProviderError.message(
        "Synthetic orbit changed ownership, document or focus incorrectly.")
    }
    try await settleOrbitLabels(canvas)
    let afterLeaders = try verifyLeaderAttachments(
      document: document, currentDocument: model.scene, canvas: canvas, stage: stage,
      phase: "synthetic-orbit-after", output: output)
    let label = try requireFrame(canvas.projectedLabelFrame(id: "orbit-label"))
    let composite = try canvas.explanationSnapshot()
    let baseline = try canvas.explanationSnapshot(includeSpatialLabels: false)
    let pixels = changedPixels(
      composite, baseline: baseline, in: canvas.canvasFrame(forDocumentRect: label),
      canvasSize: canvas.bounds.size)
    let orbitCoverage = coverage(composite)
    guard beforeLeaders.count == 1, afterLeaders.count == 1,
      canvas.projectedLabelText(id: "orbit-label") == "Orbit block",
      CGRect(x: 0, y: 0, width: document.width, height: document.height).contains(label),
      canvas.unresolvedLabelOverlapCount == 0, pixels >= 12,
      orbitCoverage.visible > 500, opaqueTrayBackdrop(composite, canvasSize: canvas.bounds.size)
    else {
      throw ProviderError.message("Synthetic orbit lost the native label, surface or alpha pixels.")
    }
    try write(composite, to: output.appendingPathComponent("synthetic-orbit-after.png"))

    func beginAgain() throws -> CGPoint {
      let current = try orbitPoint(canvas: canvas, stage: stage)
      controller.reconcileForAcceptance(
        pointer: orbitScreenPoint(current, canvas: canvas, panel: visual),
        modifiers: .option, buttons: [])
      canvas.mouseDown(with: try orbitMouse(.leftMouseDown, at: current, canvas: canvas))
      guard canvas.isOverlayCameraDragging else {
        throw ProviderError.message("The authored cancellation gesture did not begin.")
      }
      return current
    }
    let priorityPoint = try beginAgain()
    controller.reconcileForAcceptance(
      pointer: orbitScreenPoint(priorityPoint, canvas: canvas, panel: visual),
      modifiers: [.control, .option], buttons: .left)
    let cancelledCamera = camera.simdWorldTransform
    let dragEvents = canvas.overlayCameraDragEventCount
    canvas.mouseDragged(with: try orbitMouse(.leftMouseDragged, at: moved, canvas: canvas))
    guard !canvas.isOverlayCameraDragging, visual.ignoresMouseEvents,
      !canvas.overlayCameraArmed, camera.simdWorldTransform == cancelledCamera,
      canvas.overlayCameraDragEventCount == dragEvents
    else { throw ProviderError.message("Voice-chord cancellation admitted a queued orbit event.") }
    diagnostics["voice-priority"] = controller.diagnostics

    _ = try beginAgain()
    let generation = model.taskGeneration
    model.stop()
    controller.refresh()
    diagnostics["generation-cancelled"] = controller.diagnostics
    guard model.taskGeneration > generation, !canvas.isOverlayCameraDragging,
      !canvas.overlayCameraArmed,
      controller.diagnostics.phase == "passive"
    else { throw ProviderError.message("A changed task generation retained orbit ownership.") }

    try await Task.sleep(for: .milliseconds(20))
    try await settleOrbitLabels(canvas)
    _ = try beginAgain()
    NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.willSleepNotification, object: nil)
    diagnostics["simulated-sleep"] = controller.diagnostics
    guard !visual.isVisible, !clear.isVisible, visual.contentView == nil,
      !canvas.isOverlayCameraDragging, !canvas.overlayCameraArmed,
      controller.diagnostics.phase == "passive"
    else { throw ProviderError.message("Simulated sleep retained an orbit presentation.") }
    NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
    overlay.show(document: document, on: screen)
    let (renewed, renewedClear, renewedCanvas) = try ownPresentation(
      document: document, overlay: overlay)
    let renewedController = try require(
      overlay.orbitControllerForAcceptance, "No renewed orbit controller.")
    controller.reconcileForAcceptance(pointer: pointer, modifiers: .option, buttons: [])
    guard controller.diagnostics.phase == "passive", !renewedCanvas.overlayCameraArmed else {
      throw ProviderError.message("A closed orbit controller acquired a renewed presentation.")
    }
    try await settleOrbitLabels(renewedCanvas)
    let renewedStage = try require(renewedCanvas.spatialStage, "No renewed authored orbit stage.")
    let renewedPoint = try orbitPoint(canvas: renewedCanvas, stage: renewedStage)
    renewedController.reconcileForAcceptance(
      pointer: orbitScreenPoint(renewedPoint, canvas: renewedCanvas, panel: renewed),
      modifiers: .option, buttons: [])
    renewedCanvas.mouseDown(
      with: try orbitMouse(.leftMouseDown, at: renewedPoint, canvas: renewedCanvas))
    guard renewedCanvas.isOverlayCameraDragging else {
      throw ProviderError.message("The authored display-change gesture did not begin.")
    }
    NotificationCenter.default.post(
      name: NSApplication.didChangeScreenParametersNotification, object: nil)
    diagnostics["simulated-display-change"] = renewedController.diagnostics
    guard !renewed.isVisible, !renewedClear.isVisible, renewed.contentView == nil,
      !renewedCanvas.overlayCameraArmed, !renewedCanvas.isOverlayCameraDragging,
      renewedController.diagnostics.phase == "passive"
    else { throw ProviderError.message("A simulated display change retained orbit ownership.") }

    overlay.show(document: document, on: screen)
    let (finalVisual, finalClear, finalCanvas) = try ownPresentation(
      document: document, overlay: overlay)
    let finalController = try require(
      overlay.orbitControllerForAcceptance, "No final orbit controller.")
    let lease = try require(overlay.presentationLease, "No final orbit presentation lease.")
    try await settleOrbitLabels(finalCanvas)
    let finalStage = try require(finalCanvas.spatialStage, "No final authored orbit stage.")
    let finalPoint = try orbitPoint(canvas: finalCanvas, stage: finalStage)
    finalController.reconcileForAcceptance(
      pointer: orbitScreenPoint(finalPoint, canvas: finalCanvas, panel: finalVisual),
      modifiers: .option, buttons: [])
    finalCanvas.mouseDown(with: try orbitMouse(.leftMouseDown, at: finalPoint, canvas: finalCanvas))
    guard finalCanvas.isOverlayCameraDragging else {
      throw ProviderError.message("The authored Clear gesture did not begin.")
    }
    let beforeClear = model.taskGeneration
    overlay.clearPresentation(lease: lease, documentID: document.id)
    diagnostics["cleared"] = finalController.diagnostics
    guard !finalVisual.isVisible, !finalClear.isVisible, finalVisual.contentView == nil,
      !finalCanvas.overlayCameraArmed, !finalCanvas.isOverlayCameraDragging,
      finalController.diagnostics.phase == "passive",
      model.scene == document, model.taskGeneration > beforeClear,
      model.messages.map(\.id) == messageIDs,
      NSWorkspace.shared.frontmostApplication?.processIdentifier == foreground
    else {
      throw ProviderError.message("Clear retained orbit ownership or changed the document/focus.")
    }
    return [
      "result": "passed", "authoredFixtureOnly": true,
      "syntheticOwnViewEvents": true, "globalInputPosted": false,
      "externalModifierDeliveryTested": false, "windowServerInputTested": false,
      "humanPhysicalOrbitTested": false, "ambientObservationEnabled": false,
      "passiveWindowIgnoresMouseEvents": false, "armedOwnershipIsBoundedPanel": true,
      "visibleTrayOwnsLocalInput": true,
      "transparentPixelClickThroughWhileArmedClaimed": false,
      "cameraChangedThroughOwnViewDragHandler": true, "canonicalDocumentUnchanged": true,
      "requestedLeadersVerifiedBeforeAndAfterDrag": afterLeaders.count,
      "labelGlyphChangedPixelsAfterDrag": pixels, "actualOwnViewDragEvents": dragEvents,
      "voiceChordPriorityVerifiedSynthetically": true, "generationCancellationVerified": true,
      "simulatedSleepTeardownVerified": true, "simulatedDisplayChangeTeardownVerified": true,
      "actualSleepOrDisplayRemovalTested": false, "closedControllerCannotRearm": true,
      "clearTeardownVerified": true, "foregroundPreserved": true,
      "diagnostics": "synthetic-orbit-diagnostics.json",
    ]
  }

  private static func settleOrbitLabels(_ canvas: RetainedCanvasView) async throws {
    let deadline = ProcessInfo.processInfo.systemUptime + 6
    while canvas.hasPendingSpatialLabels || canvas.hasPendingLabelAttachments {
      try Task.checkCancellation()
      guard ProcessInfo.processInfo.systemUptime < deadline else {
        throw ProviderError.message("Authored orbit labels or surfaces did not settle.")
      }
      try await Task.sleep(for: .milliseconds(20))
    }
  }

  /// Authored native camera submissions, without system event creation/posting.
  /// These costs exclude GPU completion, display refresh, input dispatch and AI.
  private static func measureLocalOrbitCPU(_ canvas: RetainedCanvasView) async throws -> [String:
    Any]
  {
    let identity = (canvas.renderedDocumentID, canvas.renderedDocumentRevision)
    var milliseconds: [Double] = []
    for index in 0..<120 {
      try Task.checkCancellation()
      let start = ProcessInfo.processInfo.systemUptime
      guard canvas.orbitOverlayCamera(delta: CGPoint(x: index < 60 ? 0.005 : -0.005, y: 0)) else {
        throw ProviderError.message("A mounted tray refused the authored local orbit sample.")
      }
      milliseconds.append((ProcessInfo.processInfo.systemUptime - start) * 1_000)
      if index % 8 == 0 { await Task.yield() }
    }
    guard canvas.renderedDocumentID == identity.0, canvas.renderedDocumentRevision == identity.1
    else {
      throw ProviderError.message("Local orbit changed the explanation document.")
    }
    milliseconds.sort()
    return [
      "samples": milliseconds.count, "p50MS": milliseconds[60],
      "p95MS": milliseconds[114], "maxMS": milliseconds[119],
      "scope":
        "Authored local camera/label CPU submission only; not displayed FPS or trackpad latency.",
      "providerCalled": false, "systemInputPosted": false,
      "documentUnchanged": true, "displayedFPSMeasured": false,
    ]
  }

  private static func orbitPoint(canvas: RetainedCanvasView, stage: SCNView) throws -> CGPoint {
    let node = try require(canvas.spatialNode(id: "orbit-body"), "No authored orbit body.")
    let projected = stage.projectPoint(node.worldPosition)
    let point = canvas.convert(
      CGPoint(x: CGFloat(projected.x), y: CGFloat(projected.y)), from: stage)
    guard canvas.visibleSpatialMesh(atCanvasPoint: point) == "orbit-body" else {
      throw ProviderError.message("The authored orbit start misses a visible native triangle.")
    }
    return point
  }

  private static func orbitScreenPoint(_ point: CGPoint, canvas: NSView, panel: NSWindow) -> CGPoint
  {
    panel.convertPoint(toScreen: canvas.convert(point, to: nil))
  }

  private static func orbitMouse(
    _ type: NSEvent.EventType, at point: CGPoint, canvas: NSView,
    flags: NSEvent.ModifierFlags = .option
  ) throws -> NSEvent {
    try require(
      NSEvent.mouseEvent(
        with: type, location: canvas.convert(point, to: nil), modifierFlags: flags,
        timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: canvas.window?.windowNumber ?? 0,
        context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 0.5),
      "Could not author an own-view orbit event.")
  }

  private static func syntheticOrbitFixture() -> SceneDocument {
    .init(
      id: "authored-synthetic-orbit", title: "Authored orbit fixture", width: 900, height: 560,
      nodes: [
        .init(
          id: "orbit-body", kind: .mesh, fill: "#4488CC",
          spatial3D: .init(
            geometry: .box(width: 2.4, height: 1.2, depth: 0.65, chamferRadius: 0.04))),
        .init(
          id: "orbit-label", kind: .text, width: 140, height: 36,
          text: "Orbit block", color: "#FFFFFF",
          spatial3D: .init(
            labelAnchor: .init(targetID: "orbit-body", point: .init(x: 0.9, y: 0.2, z: 0.325)))),
      ])
  }

  private struct AttachmentCheck: Encodable {
    let labelID: String
    let targetID: String
    let attachment: SpatialLabelAttachment?
    var errors: [String] = []
    var isResolved = false
    var canonicalRequestedPointPreserved = false
    var leaderStartDocument: Point2D?
    var leaderStartCanvas: Point2D?
    var resolvedProjectionCanvas: Point2D?
    var endpointCanvasError: Double?
    var closestHitSurfaceNodeID: String?
    var closestHitWorld: Vector3D?
    var closestHitFaceIndex: Int?
    var surfaceWorldError: Double?
    var wholeSceneClosestTriangleVerified = false
  }

  private struct AttachmentPhaseReceipt: Encodable {
    let phase: String
    let canonicalSceneUnchanged: Bool
    let requestedLeaderCount: Int
    let verifiedLeaderCount: Int
    let diagnostics: SpatialLabelAttachmentDiagnostics
    let attachments: [AttachmentCheck]
  }

  /// This acceptance oracle does its own whole-scene triangle query. Merely
  /// projecting either the requested point or a target-only intersection would
  /// allow a leader to point through a cavity or through an occluding part.
  private static func verifyLeaderAttachments(
    document: SceneDocument, currentDocument: SceneDocument?, canvas: RetainedCanvasView,
    stage: SCNView, phase: String, output: URL
  ) throws -> [String: CGPoint] {
    let requested = document.nodes.filter { $0.spatial3D?.labelAnchor?.leader == true }
    guard !requested.isEmpty, requested.count <= 128 else {
      throw ProviderError.message("The requested leader count exceeds the native acceptance bound.")
    }
    var checks: [AttachmentCheck] = []
    var starts: [String: CGPoint] = [:]
    for node in requested {
      try Task.checkCancellation()
      let check = checkLeaderAttachment(
        node: node, document: document, canvas: canvas, stage: stage)
      checks.append(check)
      if check.errors.isEmpty, let start = check.leaderStartDocument {
        starts[node.id] = CGPoint(x: start.x, y: start.y)
      }
    }
    let canonicalSceneUnchanged = currentDocument == document
    let receipt = AttachmentPhaseReceipt(
      phase: phase, canonicalSceneUnchanged: canonicalSceneUnchanged,
      requestedLeaderCount: requested.count, verifiedLeaderCount: starts.count,
      diagnostics: canvas.labelAttachmentDiagnostics, attachments: checks)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let bytes = try encoder.encode(receipt)
    guard bytes.count <= 1_000_000 else {
      throw ProviderError.message("The native attachment receipt exceeds its diagnostic bound.")
    }
    try bytes.write(
      to: output.appendingPathComponent("attachments-\(phase).json"), options: .atomic)
    guard canonicalSceneUnchanged, starts.count == requested.count else {
      throw ProviderError.message(
        "A requested leader lacks a preserved canonical anchor or a visible target surface; see attachments-\(phase).json."
      )
    }
    return starts
  }

  private static func checkLeaderAttachment(
    node: SceneNode, document: SceneDocument, canvas: RetainedCanvasView, stage: SCNView
  ) -> AttachmentCheck {
    guard let anchor = node.spatial3D?.labelAnchor else {
      return AttachmentCheck(
        labelID: node.id, targetID: "", attachment: nil, errors: ["missingAnchor"])
    }
    let attachment = canvas.projectedLabelAttachments[node.id]
    var check = AttachmentCheck(labelID: node.id, targetID: anchor.targetID, attachment: attachment)
    guard let attachment else {
      check.errors.append("missingAttachment")
      return check
    }
    check.isResolved = attachment.isResolved
    check.canonicalRequestedPointPreserved = attachment.requestedLocal == anchor.point
    if !check.canonicalRequestedPointPreserved {
      check.errors.append("canonicalRequestedPointChanged")
    }
    if attachment.labelID != node.id || attachment.targetID != anchor.targetID {
      check.errors.append("attachmentIdentityMismatch")
    }
    guard attachment.isResolved,
      attachment.status == .requestedProjection || attachment.status == .surfaceSearch,
      let world = attachment.resolvedWorld, world.isFinite,
      let requestedWorld = attachment.requestedWorld, requestedWorld.isFinite,
      let targetLocal = attachment.resolvedTargetLocal, targetLocal.isFinite,
      let geometryLocal = attachment.resolvedGeometryLocal, geometryLocal.isFinite,
      let surfaceID = attachment.surfaceNodeID,
      let target = canvas.spatialNode(id: anchor.targetID),
      let surface = canvas.spatialNode(id: surfaceID), surface.geometry != nil
    else {
      check.errors.append("unresolvedOrMissingSurface")
      return check
    }
    if !belongs(surface, to: target) { check.errors.append("surfaceOutsideRequestedTarget") }
    let tolerance = worldTolerance(world)
    let expectedRequested = vector(target.convertPosition(native(anchor.point), to: nil))
    if !expectedRequested.isFinite
      || distance(expectedRequested, requestedWorld) > worldTolerance(expectedRequested)
    {
      check.errors.append("requestedWorldDoesNotMatchCanonicalPoint")
    }
    let targetWorld = vector(target.convertPosition(native(targetLocal), to: nil))
    let geometryWorld = vector(surface.convertPosition(native(geometryLocal), to: nil))
    if !targetWorld.isFinite || !geometryWorld.isFinite
      || distance(targetWorld, world) > tolerance || distance(geometryWorld, world) > tolerance
    {
      check.errors.append("resolvedLocalAndWorldCoordinatesDisagree")
    }
    guard let path = canvas.projectedLeaderPath(id: node.id), let start = pathStart(path),
      start.x.isFinite, start.y.isFinite,
      canvas.projectedLabelFrame(id: node.id) != nil
    else {
      check.errors.append("missingVisibleLeaderOrLabel")
      return check
    }
    check.leaderStartDocument = .init(x: start.x, y: start.y)
    let actual = canvas.canvasFrame(forDocumentRect: CGRect(origin: start, size: .zero)).origin
    guard actual.x.isFinite, actual.y.isFinite else {
      check.errors.append("nonfiniteLeaderEndpoint")
      return check
    }
    check.leaderStartCanvas = .init(x: actual.x, y: actual.y)
    let projected = stage.projectPoint(native(world))
    let projectedPoint = CGPoint(x: CGFloat(projected.x), y: CGFloat(projected.y))
    guard projected.x.isFinite, projected.y.isFinite, projected.z.isFinite,
      projected.z >= 0, projected.z <= 1, stage.bounds.contains(projectedPoint)
    else {
      check.errors.append("resolvedSurfaceOutsideViewport")
      return check
    }
    let expected = stage.convert(projectedPoint, to: canvas)
    let endpointError = hypot(expected.x - actual.x, expected.y - actual.y)
    check.resolvedProjectionCanvas = .init(x: expected.x, y: expected.y)
    check.endpointCanvasError = endpointError
    if endpointError > 0.5 { check.errors.append("leaderDoesNotProjectResolvedSurface") }

    let actualStagePoint = stage.convert(actual, from: canvas)
    // Do not supply a target/rootNode filter: the closest visible triangle of
    // every renderer-owned part participates in occlusion.
    guard
      let hit = stage.hitTest(
        actualStagePoint,
        options: [
          .searchMode: SCNHitTestSearchMode.closest.rawValue, .boundingBoxOnly: false,
          .clipToZRange: true, .backFaceCulling: true, .ignoreHiddenNodes: true,
          .categoryBitMask: 1,
        ]
      ).first,
      let hitID = document.nodes.first(where: { canvas.spatialNode(id: $0.id) === hit.node })?.id,
      hit.node.geometry != nil, hit.faceIndex >= 0
    else {
      check.errors.append("noWholeSceneClosestTriangle")
      return check
    }
    let hitWorld = vector(hit.worldCoordinates)
    guard hitWorld.isFinite else {
      check.errors.append("nonfiniteClosestTriangle")
      return check
    }
    check.closestHitSurfaceNodeID = hitID
    check.closestHitWorld = hitWorld
    check.closestHitFaceIndex = hit.faceIndex
    check.surfaceWorldError = distance(hitWorld, world)
    if hit.node !== surface || hitID != surfaceID || !belongs(hit.node, to: target) {
      check.errors.append("closestTriangleOutsideResolvedTargetSurface")
    }
    if distance(hitWorld, world) > tolerance {
      check.errors.append("endpointIsNotClosestTrianglePoint")
    }
    check.wholeSceneClosestTriangleVerified = check.errors.isEmpty
    return check
  }

  private static func belongs(_ node: SCNNode, to ancestor: SCNNode) -> Bool {
    var current: SCNNode? = node
    for _ in 0..<128 {
      guard let value = current else { return false }
      if value === ancestor { return true }
      current = value.parent
    }
    return false
  }

  private static func native(_ point: Vector3D) -> SCNVector3 {
    .init(Float(point.x), Float(point.y), Float(point.z))
  }

  private static func vector(_ point: SCNVector3) -> Vector3D {
    .init(x: Double(point.x), y: Double(point.y), z: Double(point.z))
  }

  private static func distance(_ first: Vector3D, _ second: Vector3D) -> Double {
    hypot(hypot(first.x - second.x, first.y - second.y), first.z - second.z)
  }

  private static func worldTolerance(_ point: Vector3D) -> Double {
    // SceneKit hit positions are single-precision; retain a small absolute
    // floor plus a scale-aware float round-trip allowance.
    max(0.0001, max(abs(point.x), abs(point.y), abs(point.z)) * Double(Float.ulpOfOne) * 16)
  }

  @MainActor private static func ownPresentation(
    document: SceneDocument, overlay: ExplanationOverlay
  ) throws -> (NSWindow, NSWindow, RetainedCanvasView) {
    guard overlay.isVisible(documentID: document.id),
      let visual = NSApp.windows.first(where: {
        $0.isVisible && $0.identifier?.rawValue == "org.opencompanion.explanation.visual"
      }),
      let clear = NSApp.windows.first(where: {
        $0.isVisible && $0.identifier?.rawValue == "org.opencompanion.explanation.clear"
      }), let canvas = visual.contentView as? RetainedCanvasView
    else { throw ProviderError.message("The own explanation windows did not appear.") }
    return (visual, clear, canvas)
  }

  private static func require<Value>(_ value: Value?, _ message: String) throws -> Value {
    guard let value else { throw ProviderError.message(message) }
    return value
  }

  private static func pathStart(_ path: CGPath) -> CGPoint? {
    var first: CGPoint?
    path.applyWithBlock { element in
      if first == nil, element.pointee.type == .moveToPoint {
        first = element.pointee.points[0]
      }
    }
    return first
  }

  private static func opaqueTrayBackdrop(_ bitmap: NSBitmapImageRep, canvasSize: CGSize) -> Bool {
    guard bitmap.pixelsWide > 0, bitmap.pixelsHigh > 0,
      canvasSize.width > 80, canvasSize.height > 40
    else { return false }
    let expected = NSColor(sceneHex: "#101114").usingColorSpace(.deviceRGB)!
    var matches = 0
    for x in [CGFloat(30), canvasSize.width / 2, canvasSize.width - 30] {
      let px = min(bitmap.pixelsWide - 1, Int(x / canvasSize.width * CGFloat(bitmap.pixelsWide)))
      let py = min(
        bitmap.pixelsHigh - 1,
        Int((canvasSize.height - 5) / canvasSize.height * CGFloat(bitmap.pixelsHigh)))
      guard let color = bitmap.colorAt(x: px, y: py)?.usingColorSpace(.deviceRGB) else { continue }
      if color.alphaComponent >= 0.98,
        abs(color.redComponent - expected.redComponent) < 0.04,
        abs(color.greenComponent - expected.greenComponent) < 0.04,
        abs(color.blueComponent - expected.blueComponent) < 0.04
      {
        matches += 1
      }
    }
    return matches >= 2
  }

  private static func coverage(_ bitmap: NSBitmapImageRep) -> (visible: Int, transparent: Int) {
    guard bitmap.bitsPerSample == 8, bitmap.samplesPerPixel == 4,
      !bitmap.isPlanar, bitmap.hasAlpha, let bytes = bitmap.bitmapData
    else { return (0, 0) }
    let alpha = bitmap.bitmapFormat.contains(.alphaFirst) ? 0 : 3
    var visible = 0
    var transparent = 0
    for y in 0..<bitmap.pixelsHigh {
      for x in 0..<bitmap.pixelsWide {
        let value = bytes[y * bitmap.bytesPerRow + x * 4 + alpha]
        if value > 16 { visible += 1 }
        if value == 0 { transparent += 1 }
      }
    }
    return (visible, transparent)
  }

  /// Scalar own-view diagnostics only: no label text, node IDs or pixel data.
  private static func metricFrame(_ frame: CGRect) -> [String: Any] {
    func finite(_ value: CGFloat) -> Any { value.isFinite ? Double(value) as Any : NSNull() }
    return [
      "x": finite(frame.origin.x), "y": finite(frame.origin.y),
      "width": finite(frame.size.width), "height": finite(frame.size.height),
    ]
  }

  private static func bitmapMetrics(_ bitmap: NSBitmapImageRep) -> [String: Any] {
    [
      "pixelsWide": bitmap.pixelsWide, "pixelsHigh": bitmap.pixelsHigh,
      "bitsPerSample": bitmap.bitsPerSample, "samplesPerPixel": bitmap.samplesPerPixel,
      "bitsPerPixel": bitmap.bitsPerPixel, "bytesPerRow": bitmap.bytesPerRow,
      "hasAlpha": bitmap.hasAlpha, "isPlanar": bitmap.isPlanar,
      "alphaFirst": bitmap.bitmapFormat.contains(.alphaFirst),
      "bitmapFormatRawValue": bitmap.bitmapFormat.rawValue,
      "bitmapDataAvailable": bitmap.bitmapData != nil,
      "logicalSize": metricFrame(CGRect(origin: .zero, size: bitmap.size)),
    ]
  }

  private static func write(_ bitmap: NSBitmapImageRep, to url: URL) throws {
    guard let bytes = bitmap.representation(using: .png, properties: [:]) else {
      throw ProviderError.message("Could not encode the own-view explanation snapshot.")
    }
    try bytes.write(to: url)
  }

  private static func changedPixels(
    _ bitmap: NSBitmapImageRep, baseline: NSBitmapImageRep, in region: CGRect,
    canvasSize: CGSize, excluding: CGRect? = nil
  ) -> Int {
    guard let pixels = bitmap.bitmapData, let old = baseline.bitmapData,
      bitmap.pixelsWide == baseline.pixelsWide, bitmap.pixelsHigh == baseline.pixelsHigh,
      bitmap.samplesPerPixel == 4, baseline.samplesPerPixel == 4,
      bitmap.bitsPerSample == 8, baseline.bitsPerSample == 8,
      !bitmap.isPlanar, !baseline.isPlanar, canvasSize.width > 0, canvasSize.height > 0
    else { return 0 }
    let scaleX = Double(bitmap.pixelsWide) / canvasSize.width
    let scaleY = Double(bitmap.pixelsHigh) / canvasSize.height
    let left = max(0, min(bitmap.pixelsWide, Int(floor(region.minX * scaleX))))
    let right = max(left, min(bitmap.pixelsWide, Int(ceil(region.maxX * scaleX))))
    let top = max(0, min(bitmap.pixelsHigh, Int(floor(region.minY * scaleY))))
    let bottom = max(top, min(bitmap.pixelsHigh, Int(ceil(region.maxY * scaleY))))
    let alpha = bitmap.bitmapFormat.contains(.alphaFirst) ? 0 : 3
    var changed = 0
    for y in top..<bottom {
      for x in left..<right {
        if let excluding,
          excluding.contains(CGPoint(x: (Double(x) + 0.5) / scaleX, y: (Double(y) + 0.5) / scaleY))
        {
          continue
        }
        let index = y * bitmap.bytesPerRow + x * 4
        let previous = y * baseline.bytesPerRow + x * 4
        let delta = (0..<4).reduce(0) {
          $0 + abs(Int(pixels[index + $1]) - Int(old[previous + $1]))
        }
        if pixels[index + alpha] > 24, delta > 50 { changed += 1 }
      }
    }
    return changed
  }

  private static func matchingGeometryPixels(
    _ native: NSBitmapImageRep, composite: NSBitmapImageRep, stageFrame: CGRect,
    canvasSize: CGSize
  ) -> NativeCompositeGeometryComparison.Result {
    guard native.pixelsWide > 0, native.pixelsHigh > 0,
      composite.pixelsWide > 0, composite.pixelsHigh > 0,
      canvasSize.width > 0, canvasSize.height > 0
    else { return NativeCompositeGeometryComparison.preservingGrid(.init(samples: 0, matches: 0)) }
    let strideSize = max(1, Int(sqrt(Double(native.pixelsWide * native.pixelsHigh) / 512)))
    var samples = 0
    var matches = 0
    for y in stride(from: 0, to: native.pixelsHigh, by: strideSize) {
      for x in stride(from: 0, to: native.pixelsWide, by: strideSize) {
        guard samples < 128,
          let expected = native.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
          expected.alphaComponent > 0.9
        else { continue }
        let localX =
          stageFrame.minX + (Double(x) + 0.5) / Double(native.pixelsWide) * stageFrame.width
        let localY =
          stageFrame.minY + (Double(y) + 0.5) / Double(native.pixelsHigh) * stageFrame.height
        let pixelX = Int(localX / canvasSize.width * Double(composite.pixelsWide))
        let pixelY = Int(localY / canvasSize.height * Double(composite.pixelsHigh))
        guard (0..<composite.pixelsWide).contains(pixelX),
          (0..<composite.pixelsHigh).contains(pixelY),
          let actual = composite.colorAt(x: pixelX, y: pixelY)?.usingColorSpace(.deviceRGB)
        else { continue }
        samples += 1
        if actual.alphaComponent > 0.5,
          abs(actual.redComponent - expected.redComponent) < 0.18,
          abs(actual.greenComponent - expected.greenComponent) < 0.18,
          abs(actual.blueComponent - expected.blueComponent) < 0.18
        {
          matches += 1
        }
      }
    }
    let grid = NativeCompositeGeometryComparison.Counts(samples: samples, matches: matches)
    guard samples < 20 else { return NativeCompositeGeometryComparison.preservingGrid(grid) }
    let permittedFormat: NSBitmapImageRep.Format = [.alphaFirst, .alphaNonpremultiplied]
    guard native.bitsPerSample == 8, native.samplesPerPixel == 4, native.bitsPerPixel == 32,
      native.hasAlpha, !native.isPlanar,
      native.bitmapFormat.subtracting(permittedFormat).isEmpty,
      native.pixelsWide <= NativeCompositeGeometryComparison.maximumDimension,
      native.bytesPerRow >= native.pixelsWide * 4, let bytes = native.bitmapData
    else { return NativeCompositeGeometryComparison.preservingGrid(grid) }
    let alpha = native.bitmapFormat.contains(.alphaFirst) ? 0 : 3
    return NativeCompositeGeometryComparison.compare(
      grid: grid, nativeWidth: native.pixelsWide, nativeHeight: native.pixelsHigh,
      compositeWidth: composite.pixelsWide, compositeHeight: composite.pixelsHigh,
      stageFrame: stageFrame, canvasSize: canvasSize,
      nativeAlpha: { x, y in bytes[y * native.bytesPerRow + x * 4 + alpha] },
      colors: { sample in
        guard
          let expected = native.colorAt(x: sample.nativeX, y: sample.nativeY)?
            .usingColorSpace(.deviceRGB),
          let actual = composite.colorAt(x: sample.compositeX, y: sample.compositeY)?
            .usingColorSpace(.deviceRGB)
        else { return nil }
        return (
          .init(
            red: Double(expected.redComponent), green: Double(expected.greenComponent),
            blue: Double(expected.blueComponent), alpha: Double(expected.alphaComponent)),
          .init(
            red: Double(actual.redComponent), green: Double(actual.greenComponent),
            blue: Double(actual.blueComponent), alpha: Double(actual.alphaComponent))
        )
      })
  }

  private static func requireFrame(_ value: CGRect?) throws -> CGRect {
    try require(value, "An anchored label was not projected into the native viewport.")
  }

  static func fixture() -> SceneDocument {
    SceneDocument(
      id: "authored-spatial-overlay", title: "Simplified native motor", width: 900, height: 560,
      nodes: [
        SceneNode(id: "assembly", kind: .group, spatial3D: .init()),
        SceneNode(
          id: "housing", kind: .mesh, color: "#687B8E", parentID: "assembly",
          spatial3D: .init(
            transform: .init(rotationDegrees: .init(x: 90, y: 0, z: 0)),
            geometry: .tube(
              innerRadius: 1.15, outerRadius: 1.35, height: 1.5, segments: 40,
              startAngleDegrees: 25, sweepAngleDegrees: 270))),
        SceneNode(
          id: "rotor", kind: .mesh, color: "#DD9E47", parentID: "assembly",
          spatial3D: .init(
            transform: .init(rotationDegrees: .init(x: 90, y: 0, z: 0)),
            geometry: .cylinder(radius: 0.6, height: 2.1))),
        SceneNode(
          id: "rotor-label", kind: .text, text: "Rotor", color: "#FFFFFF", fontSize: 20,
          spatial3D: .init(
            labelAnchor: .init(
              targetID: "rotor", point: .init(x: 0.5, y: 0.7, z: 0),
              screenOffset: .init(x: 44, y: -30)))),
        SceneNode(
          id: "housing-label", kind: .text, text: "Cutaway housing", color: "#FFFFFF", fontSize: 20,
          spatial3D: .init(
            labelAnchor: .init(
              targetID: "housing", point: .init(x: -1.1, y: 0.5, z: 0.6),
              screenOffset: .init(x: -150, y: -35)))),
      ])
  }
}
