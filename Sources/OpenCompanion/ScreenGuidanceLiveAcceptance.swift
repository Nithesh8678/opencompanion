import AppKit

/// Opt-in live perception against the public full-display fixture. Nothing on
/// the user's ordinary desktop is accepted as a test input.
enum ScreenGuidanceLiveAcceptance {
  @MainActor static func run(model: AppModel, cursor: CursorCompanionCoordinator, output: URL)
    async throws
  {
    guard let fixture = NSWorkspace.shared.frontmostApplication,
      fixture.bundleIdentifier == "org.opencompanion.fixture.guidance",
      let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }),
      fixtureCoversDisplay(pid: fixture.processIdentifier, screen: screen)
    else {
      throw ProviderError.message("Open the public Guidance Fixture on the active display first.")
    }
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    defer {
      let diagnostics: [String: Any] = [
        "events": model.diagnosticEvents, "state": model.state, "busy": model.busy,
        "error": model.error ?? "", "generation": model.taskGeneration,
      ]
      if let data = try? JSONSerialization.data(
        withJSONObject: diagnostics, options: [.prettyPrinted, .sortedKeys])
      {
        try? data.write(to: output.appendingPathComponent("guidance-diagnostics.json"))
      }
      model.stop()
      cursor.shutdown()
    }
    model.providerMode = "ChatGPT via Codex"
    model.configuration.speechEnabled = false
    var stages: [Int: [String: Any]] = [:]
    var frames: [Int: UUID] = [:]
    let previous = model.onScreenGuidanceTargetAccepted
    model.onScreenGuidanceTargetAccepted = { target, evidence, generation, request in
      previous?(target, evidence, generation, request)
      guard stages[request.step] == nil else { return }
      let stage: [String: Any] = [
        "step": request.step, "generation": generation, "label": target.label ?? "",
        "advanceOn": target.advanceOn ?? "manual", "x": target.x, "y": target.y,
        "width": target.width, "height": target.height,
        "foregroundIsFixture": evidence.foregroundPID == fixture.processIdentifier,
      ]
      stages[request.step] = stage
      frames[request.step] = evidence.frameID
      if let data = try? JSONSerialization.data(
        withJSONObject: stage, options: [.prettyPrinted, .sortedKeys])
      {
        try? data.write(to: output.appendingPathComponent("step-\(request.step)-ready.json"))
      }
      try? FileHandle.standardOutput.write(
        contentsOf: Data("GUIDANCE_STEP_\(request.step)_READY\n".utf8))
    }
    defer { model.onScreenGuidanceTargetAccepted = previous }
    cursor.pointerMoved(to: CGPoint(x: screen.frame.midX - 160, y: screen.frame.midY))
    model.beginScreenGuidance(
      "Show me how to open table settings, then show me where to enter a table name. Give only the next visible control and wait for my click.",
      speakAloud: false)
    let deadline = ProcessInfo.processInfo.systemUptime + 100
    while stages[1] == nil && ProcessInfo.processInfo.systemUptime < deadline {
      if let error = model.error { throw ProviderError.message(error) }
      try await Task.sleep(for: .milliseconds(100))
    }
    guard let first = stages[0], let second = stages[1], frames[0] != frames[1],
      first["foregroundIsFixture"] as? Bool == true,
      second["foregroundIsFixture"] as? Bool == true,
      first["advanceOn"] as? String == "click",
      contains(first, point: CGPoint(x: 0.4, y: 0.45)),
      contains(second, point: tableFieldCenter(displaySize: screen.frame.size))
    else {
      throw ProviderError.message(
        "The public fixture did not complete a fresh grounded two-step guidance flow.")
    }
    try await Task.sleep(for: .seconds(2))
    try await cursor.exportSnapshot(to: output.appendingPathComponent("guidance-cursor-final.png"))
    try await CursorCompanionAcceptance.exportGuidanceAnnotation(
      label: second["label"] as? String ?? "",
      to: output.appendingPathComponent("guidance-attached-field-label.png"))
    let result: [String: Any] = [
      "result": "passed", "provider": "ChatGPT via Codex app-server", "publicFixtureOnly": true,
      "steps": [first, second], "freshFrameAfterObservedUserClick": true,
      "automaticDesktopActions": false, "microphoneUsed": false,
      "fixtureDisplay": [screen.frame.width, screen.frame.height],
    ]
    try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
      .write(to: output.appendingPathComponent("guidance-live-acceptance.json"))
  }

  private static func contains(_ stage: [String: Any], point: CGPoint) -> Bool {
    guard let x = stage["x"] as? Double, let y = stage["y"] as? Double,
      let width = stage["width"] as? Double, let height = stage["height"] as? Double,
      width > 0, width < 0.7, height > 0, height < 0.3
    else { return false }
    return CGRect(x: x, y: y, width: width, height: height).contains(point)
  }

  /// Known public fixture geometry is an independent target-grounding oracle;
  /// it is never supplied to the provider or the product's perception code.
  private static func tableFieldCenter(displaySize size: CGSize) -> CGPoint {
    let contentWidth = min(620, max(240, size.width - 96))
    let left = max(32, size.width * 0.4 - contentWidth / 2)
    return CGPoint(
      x: (left + min(contentWidth, 420) / 2) / size.width,
      y: (size.height * 0.45 + 37) / size.height)
  }

  @MainActor private static func fixtureCoversDisplay(pid: pid_t, screen: NSScreen) -> Bool {
    guard
      let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID)
        as? [[String: Any]], let primary = NSScreen.screens.first
    else { return false }
    let display = CGRect(
      x: screen.frame.minX, y: primary.frame.maxY - screen.frame.maxY,
      width: screen.frame.width, height: screen.frame.height)
    return windows.contains { window in
      guard (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
        (window[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
        (window[kCGWindowAlpha as String] as? NSNumber)?.doubleValue == 1,
        let bounds = window[kCGWindowBounds as String] as? [String: Any],
        let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary)
      else { return false }
      return rect.contains(display)
    }
  }

}
