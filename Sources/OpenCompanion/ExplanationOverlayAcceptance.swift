import AppKit
import CompanionCore
import SceneKit

/// Explicit own-window/native-renderer check. It never captures the desktop,
/// injects mouse/keyboard events, starts a provider, or records/plays audio.
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
    let overlay = ExplanationOverlay(model: model) { model.stop() }
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
    guard visual.ignoresMouseEvents, !clear.ignoresMouseEvents,
      !visual.canBecomeKey, !clear.canBecomeKey, visual.sharingType == .none,
      clear.sharingType == .none, !visual.isOpaque,
      canvas.layer?.backgroundColor?.alpha == 0,
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
    while canvas.hasPendingSpatialLabels {
      try Task.checkCancellation()
      guard ProcessInfo.processInfo.systemUptime - settleWaitStarted < 12 else {
        try saveClockDiagnostics("timeout")
        throw ProviderError.message("The native label reveal failed to settle within 12 seconds.")
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
    let targetOpacity = Dictionary(
      uniqueKeysWithValues: try document.spatialWorldPoses(at: 0).map {
        ($0.node.id, $0.effectiveOpacity)
      })
    let expectedLabels = document.nodes.filter {
      guard let anchor = $0.spatial3D?.labelAnchor else { return false }
      return !$0.text.isEmpty && $0.opacity > 0 && (targetOpacity[anchor.targetID] ?? 0) > 0
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
      document.nodes.first(where: {
        $0.spatial3D?.labelAnchor?.leader == true
          && canvas.projectedLeaderPath(id: $0.id) != nil
          && canvas.projectedLabelFrame(id: $0.id) != nil
      }), "No leader-enabled label was visible in the native viewport.")
    let initial = try requireFrame(canvas.projectedLabelFrame(id: label.id))
    let stage = try require(canvas.spatialStage, "No native SceneKit stage was mounted.")
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
    guard finalCoverage.visible > 500, finalCoverage.transparent > 500,
      geometryPixels.samples >= 20,
      Double(geometryPixels.matches) / Double(geometryPixels.samples) >= 0.65,
      labelPixels >= 12, leaderPixels >= 6
    else {
      throw ProviderError.message(
        "The final native composite lacks correctly placed geometry, label glyphs, leaders or transparency."
      )
    }
    let camera = try require(stage.pointOfView, "The native stage has no camera.")
    let originalLeaderStarts = Dictionary(
      uniqueKeysWithValues: document.nodes.compactMap { node -> (String, CGPoint)? in
        guard node.spatial3D?.labelAnchor?.leader == true,
          let path = canvas.projectedLeaderPath(id: node.id), let point = pathStart(path)
        else { return nil }
        return (node.id, point)
      })
    let before = camera.position
    camera.position = SCNVector3(before.x + 1.5, before.y + 0.7, before.z)
    camera.look(at: stage.defaultCameraController.target)
    canvas.updateCameraProjection()
    var movedLeaderCount = 0
    var verifiedLeaderCount = 0
    for node in document.nodes {
      guard let anchor = node.spatial3D?.labelAnchor, anchor.leader,
        let old = originalLeaderStarts[node.id],
        let path = canvas.projectedLeaderPath(id: node.id), let point = pathStart(path),
        let target = canvas.spatialNode(id: anchor.targetID)
      else { continue }
      // Packed text may remain in a stable slot. Its leader must still start at
      // the actual target-local point projected by the native scene/camera.
      let world = target.convertPosition(
        SCNVector3(Float(anchor.point.x), Float(anchor.point.y), Float(anchor.point.z)), to: nil)
      let projected = stage.projectPoint(world)
      let expected = stage.convert(
        CGPoint(x: CGFloat(projected.x), y: CGFloat(projected.y)), to: canvas)
      let actual = canvas.canvasFrame(
        forDocumentRect: CGRect(origin: point, size: .zero)
      ).origin
      guard hypot(expected.x - actual.x, expected.y - actual.y) <= 0.5 else {
        throw ProviderError.message(
          "A leader lost its actual native part anchor after camera motion.")
      }
      verifiedLeaderCount += 1
      if hypot(old.x - point.x, old.y - point.y) > 0.05 { movedLeaderCount += 1 }
    }
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
    let result: [String: Any] = [
      "result": "passed", "nativeOwnWindowAndViewOnly": true,
      "loadedSceneJSON": documentURL != nil,
      "typedMeshCount": document.nodes.filter {
        $0.spatial3D?.geometry != nil
      }.count,
      "anchoredLabelCount": document.nodes.filter { $0.spatial3D?.labelAnchor != nil }.count,
      "visibleCompleteLabelCount": expectedLabels.count,
      "overlappingLabelPairs": 0,
      "emptyFirstGroupRemainedHidden": true, "visualWindowEntirelyClickThrough": true,
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
      "nativeLeaderAnchorsVerifiedAfterCameraMotion": verifiedLeaderCount,
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
  ) -> (samples: Int, matches: Int) {
    guard native.pixelsWide > 0, native.pixelsHigh > 0,
      composite.pixelsWide > 0, composite.pixelsHigh > 0,
      canvasSize.width > 0, canvasSize.height > 0
    else { return (0, 0) }
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
    return (samples, matches)
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
