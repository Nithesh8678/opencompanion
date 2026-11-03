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
      first["advanceOn"] as? String == "click"
    else {
      throw ProviderError.message(
        "The public fixture did not complete a fresh grounded two-step guidance flow.")
    }
    try await Task.sleep(for: .seconds(2))
    try await cursor.exportSnapshot(to: output.appendingPathComponent("guidance-cursor-final.png"))
    let result: [String: Any] = [
      "result": "passed", "provider": "ChatGPT via Codex app-server", "publicFixtureOnly": true,
      "steps": [first, second], "freshFrameAfterObservedUserClick": true,
      "automaticDesktopActions": false, "microphoneUsed": false,
      "fixtureDisplay": [screen.frame.width, screen.frame.height],
    ]
    try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
      .write(to: output.appendingPathComponent("guidance-live-acceptance.json"))
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
