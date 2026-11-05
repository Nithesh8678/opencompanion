import AppKit
import CompanionCore
import SceneKit
import simd

/// An explicitly requested public fixture for real native event delivery. It
/// never posts input, captures another app, calls a provider or starts audio.
@MainActor enum ExplanationOrbitLiveAcceptance {
  static func run(model: AppModel, output: URL) async throws {
    guard let screen = NSScreen.main else {
      throw ProviderError.message("No display is available.")
    }
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    let document = try SceneDocument(
      id: "public-floating-orbit", title: "Floating orbit acceptance",
      nodes: [
        .init(
          id: "body", kind: .mesh, fill: "#557DA6",
          spatial3D: .init(geometry: .box(width: 2.5, height: 1.1, depth: 0.8, chamferRadius: 0.06))
        ),
        .init(
          id: "body-label", kind: .text, width: 140, height: 36,
          text: "Rotate this part", color: "#FFFFFF", fontSize: 18,
          spatial3D: .init(
            labelAnchor: .init(
              targetID: "body", point: .init(x: 0.8, y: 0.5, z: 0.4),
              screenOffset: .init(x: 30, y: -36), leader: true))),
      ]
    ).validated()
    let originalScene = model.scene
    let originalForeground = NSWorkspace.shared.frontmostApplication?.processIdentifier
    guard let originalForeground, originalForeground != ProcessInfo.processInfo.processIdentifier
    else {
      throw ProviderError.message(
        "Leave another app in front before starting the live orbit fixture.")
    }
    model.scene = document
    model.playing = false
    let overlay = ExplanationOverlay(model: model) {}
    defer {
      overlay.shutdown()
      model.scene = originalScene
    }
    overlay.show(document: document, on: screen)
    guard
      let panel = NSApp.windows.first(where: {
        $0.identifier?.rawValue == "org.opencompanion.explanation.visual" && $0.isVisible
      }), let canvas = panel.contentView as? RetainedCanvasView,
      let stage = canvas.spatialStage, let camera = stage.pointOfView
    else { throw ProviderError.message("The public orbit window did not mount.") }
    let deadline = ProcessInfo.processInfo.systemUptime + 3
    var point = CGPoint.zero
    while ProcessInfo.processInfo.systemUptime < deadline {
      let projected = stage.projectPoint(SCNVector3Zero)
      point = canvas.convert(CGPoint(x: CGFloat(projected.x), y: CGFloat(projected.y)), from: stage)
      if canvas.visibleSpatialMesh(atCanvasPoint: point) == "body" { break }
      try await Task.sleep(for: .milliseconds(16))
    }
    guard canvas.visibleSpatialMesh(atCanvasPoint: point) == "body",
      overlay.orbitDiagnostics?.observationAvailable == true
    else {
      throw ProviderError.message(
        "Native mesh or the existing input listener permission is unavailable.")
    }
    let initialCamera = camera.simdWorldTransform
    let pointer = panel.convertPoint(toScreen: canvas.convert(point, to: nil))
    let initial = overlay.orbitDiagnostics
    let initialPresses = initial?.optionPresses ?? 0
    let initialReleases = initial?.optionReleases ?? 0
    try write(
      [
        "result": "ready", "publicAuthoredFixture": true,
        "visualWindowFrameAppKit": [
          panel.frame.minX, panel.frame.minY, panel.frame.width, panel.frame.height,
        ],
        "meshPointAppKit": [pointer.x, pointer.y],
        "meshPointInCanvas": [point.x, point.y],
        "visualWindowTitle": panel.title,
        "instruction":
          "Hold Option over the model, drag a short distance, release the mouse, then release Option.",
        "inputPostedByHelper": false,
      ], to: output.appendingPathComponent("ready.json"))
    try FileHandle.standardOutput.write(contentsOf: Data("EXPLANATION_ORBIT_READY\n".utf8))
    let end = ProcessInfo.processInfo.systemUptime + 90
    while ProcessInfo.processInfo.systemUptime < end {
      try Task.checkCancellation()
      if let value = overlay.orbitDiagnostics,
        value.starts > 0, value.ends > 0, value.dragEvents > 0, value.phase == "passive",
        value.optionPresses > initialPresses, value.optionReleases > initialReleases,
        !NSEvent.modifierFlags.contains(.option), NSEvent.pressedMouseButtons == 0,
        value.observationAvailable, value.tapEnabled
      {
        break
      }
      try await Task.sleep(for: .milliseconds(25))
    }
    let final = try require(overlay.orbitDiagnostics)
    let cameraMoved = (0..<4).contains {
      simd_length(camera.simdWorldTransform[$0] - initialCamera[$0]) > 0.000_1
    }
    let passed =
      final.starts > 0 && final.ends > 0 && final.dragEvents > 0
      && final.optionPresses > initialPresses && final.optionReleases > initialReleases
      && final.phase == "passive" && final.observationAvailable && final.tapEnabled
      && !NSEvent.modifierFlags.contains(.option) && NSEvent.pressedMouseButtons == 0
      && final.panelIgnoresMouseEvents && !final.canvasArmed && cameraMoved
      && !canvas.isOverlayCameraDragging && !stage.defaultCameraController.isInertiaRunning
      && model.scene == document
      && NSWorkspace.shared.frontmostApplication?.processIdentifier == originalForeground
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(final).write(to: output.appendingPathComponent("final-input.json"))
    if let initial {
      try encoder.encode(initial).write(to: output.appendingPathComponent("initial-input.json"))
    }
    try write(
      [
        "result": passed ? "passed" : "failed", "cameraChanged": cameraMoved,
        "publicAuthoredFixture": true,
        "externalModifierTapObserved": final.optionPresses > initialPresses
          && final.optionReleases > initialReleases,
        "optionReleased": !NSEvent.modifierFlags.contains(.option),
        "mouseButtonsReleased": NSEvent.pressedMouseButtons == 0,
        "inputObservationStillAvailable": final.observationAvailable && final.tapEnabled,
        "nativeDragEventCount": final.dragEvents,
        "foregroundPreserved": NSWorkspace.shared.frontmostApplication?.processIdentifier
          == originalForeground,
        "documentUnchanged": model.scene == document,
        "passiveAfterRelease": final.panelIgnoresMouseEvents,
        "humanPhysicalInputVerified": false, "inputSource": "unverified",
        "inputPostedByHelper": false, "desktopCaptured": false, "providerCalled": false,
        "audioUsed": false,
      ], to: output.appendingPathComponent("result.json"))
    guard passed else {
      throw ProviderError.message(
        "The live orbit event/focus/release check did not pass within 90 seconds.")
    }
  }

  private static func write(_ value: [String: Any], to url: URL) throws {
    try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]).write(
      to: url)
  }
  private static func require<T>(_ value: T?) throws -> T {
    guard let value else {
      throw ProviderError.message("The orbit controller was removed during acceptance.")
    }
    return value
  }
}
