import AVFoundation
import AppKit
import ApplicationServices
import Speech

/// Exercises real panel placement/focus with an isolated model and synthetic
/// pointer locations. It does not inject OS input, record audio, or call a model.
enum NotchAcceptance {
  @MainActor static func run(shell: CompanionShell, model: AppModel, output: URL) async throws {
    guard !shell.observesPointer else {
      throw Failure.message("Synthetic interaction acceptance requires observePointer: false.")
    }
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    let initial = shell.geometry
    let originalForeground = NSWorkspace.shared.frontmostApplication?.processIdentifier
    guard initial.surface == "tucked" else {
      throw Failure.message("The synthetic acceptance panel must start tucked.")
    }
    if let cutout = initial.cutoutFrame {
      guard initial.frame == cutout, cutout.maxY == initial.displayFrame.maxY else {
        throw Failure.message("Idle panel does not coincide with the camera cutout.")
      }
    }
    model.input = "An unsent draft stays here."
    let outside = CGPoint(x: initial.displayFrame.minX + 30, y: initial.displayFrame.minY + 30)
    model.listening = true
    model.pushToTalkActive = true
    model.voiceInputState = "Listening"
    model.state = "Listening"
    shell.showVoiceActivity()
    try await Task.sleep(for: .milliseconds(650))
    let activity = shell.geometry
    guard activity.surface == "activity", !activity.expanded, NSApp.keyWindow == nil,
      NSWorkspace.shared.frontmostApplication?.processIdentifier == originalForeground,
      activity.frame.height == initial.frame.height
    else {
      throw Failure.message("Hotkey status expanded the dashboard or changed foreground focus.")
    }
    try await shell.exportLiveSnapshot(to: output.appendingPathComponent("notch-listening.png"))
    // Hover works from the compact wing as well as from the hardware cutout;
    // leaving returns to activity rather than pinning the dashboard open.
    shell.pointerMoved(to: CGPoint(x: activity.frame.minX + 18, y: activity.frame.midY))
    try await Task.sleep(for: .milliseconds(650))
    guard shell.geometry.surface == "peek", NSApp.keyWindow == nil else {
      throw Failure.message("The compact activity wing did not reveal Home without activation.")
    }
    shell.pointerMoved(to: outside)
    try await Task.sleep(for: .milliseconds(800))
    guard shell.geometry.surface == "activity", !shell.geometry.expanded else {
      throw Failure.message("Leaving Home did not return to compact hotkey feedback.")
    }
    let source = model.taskGeneration
    model.stop()
    model.busy = true
    model.state = "Thinking"
    shell.handoffVoiceActivity(from: source, to: model.taskGeneration)
    try await Task.sleep(for: .milliseconds(300))
    guard shell.geometry.surface == "activity", !shell.geometry.expanded else {
      throw Failure.message("Voice-response handoff lost compact activity ownership.")
    }
    try await shell.exportLiveSnapshot(to: output.appendingPathComponent("notch-thinking.png"))
    model.busy = false
    model.listening = false
    model.state = "Ready"
    try await Task.sleep(for: .milliseconds(650))
    guard shell.geometry.surface == "tucked", shell.geometry.frame == initial.frame else {
      throw Failure.message("Completed voice status did not retract to the camera cutout.")
    }
    // An unrelated text turn cannot borrow the finished hotkey's presentation.
    model.busy = true
    model.state = "Thinking"
    try await Task.sleep(for: .milliseconds(100))
    guard shell.geometry.surface == "tucked" else {
      throw Failure.message("An unrelated background response reopened hotkey activity.")
    }
    model.busy = false
    model.state = "Ready"
    let monitor = VoiceShortcutMonitor()
    let availability = monitor.start(onPressed: {}, onReleased: {}, onCancelled: { _ in })
    model.voiceShortcutAvailable = availability.isInstalled
    model.voiceShortcutStatus = availability.statusText
    defer { monitor.stop() }
    let target = initial.cutoutFrame ?? initial.frame
    shell.pointerMoved(to: CGPoint(x: target.midX, y: target.midY))
    try await Task.sleep(for: .milliseconds(420))
    let peek = shell.geometry
    guard peek.surface == "peek", NSApp.keyWindow == nil,
      NSWorkspace.shared.frontmostApplication?.processIdentifier == originalForeground
    else {
      throw Failure.message("Hover did not reveal a nonactivating peek.")
    }
    try await shell.exportLiveSnapshot(to: output.appendingPathComponent("notch-peek.png"))
    shell.pointerMoved(to: outside)
    try await Task.sleep(for: .milliseconds(500))
    guard shell.geometry.surface == "tucked", model.input == "An unsent draft stays here." else {
      throw Failure.message("Pointer exit did not tuck or preserve the draft.")
    }
    // A second pass catches a stale delayed hover action that can stick after
    // a retargeted opening animation.
    shell.pointerMoved(to: CGPoint(x: target.midX, y: target.midY))
    try await Task.sleep(for: .milliseconds(120))
    shell.pointerMoved(to: CGPoint(x: peek.frame.midX, y: peek.frame.minY + 18))
    try await Task.sleep(for: .milliseconds(300))
    shell.pointerMoved(to: outside)
    try await Task.sleep(for: .milliseconds(500))
    guard shell.geometry.surface == "tucked" else {
      throw Failure.message("Repeated hover failed to tuck.")
    }
    for _ in 0..<20 {
      shell.pointerMoved(to: CGPoint(x: target.midX, y: target.midY))
      try await Task.sleep(for: .milliseconds(420))
      guard shell.geometry.surface == "peek", NSApp.keyWindow == nil else {
        throw Failure.message("Repeated hover changed exposure or keyboard focus.")
      }
      shell.pointerMoved(to: outside)
      try await Task.sleep(for: .milliseconds(560))
      guard shell.geometry.surface == "tucked", model.input == "An unsent draft stays here." else {
        throw Failure.message("Repeated reveal/tuck lost the draft or failed to tuck.")
      }
    }
    let receipt = Receipt(
      initial: initial, activity: activity, peek: peek, compactVoiceFocusPreserved: true,
      voiceCompletionRetracted: true, hoverFocusPreserved: true,
      repeatedHoverAndDraftPreserved: true, inputMonitoringAllowed: CGPreflightListenEventAccess(),
      physicalPointerObservationEnabled: shell.observesPointer,
      accessibilityAllowed: AXIsProcessTrusted(), eventTapInstalled: availability.isInstalled,
      eventTapStatus: availability.statusText,
      microphoneAuthorization: AVCaptureDevice.authorizationStatus(for: .audio).rawValue,
      speechAuthorization: SFSpeechRecognizer.authorizationStatus().rawValue)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(receipt).write(
      to: output.appendingPathComponent("interaction-metadata.json"))
    shell.open()
    try await Task.sleep(for: .milliseconds(380))
    try await shell.exportLiveSnapshot(to: output.appendingPathComponent("notch-conversation.png"))
    shell.openSettings()
    try await Task.sleep(for: .milliseconds(650))
    guard shell.geometry.surface == "settings", model.input == "An unsent draft stays here." else {
      throw Failure.message("Settings did not share the shell or preserve the chat draft.")
    }
    try await shell.exportLiveSnapshot(to: output.appendingPathComponent("notch-settings.png"))
    shell.pointerMoved(to: outside)
    try await Task.sleep(for: .milliseconds(650))
    guard shell.geometry.surface == "tucked" else {
      throw Failure.message("Interactive Settings stayed visible after the pointer left.")
    }
    try encoder.encode(shell.motionStatistics).write(
      to: output.appendingPathComponent("display-link-callbacks.json"))
    print(
      "NOTCH_ACCEPTANCE_PASSED · compact voice lifecycle, cutout placement, repeated synthetic hover, draft and foreground focus"
    )
    print(
      "VOICE_PREFLIGHT tapInstalled=\(availability.isInstalled) inputMonitoring=\(receipt.inputMonitoringAllowed) accessibility=\(receipt.accessibilityAllowed) microphone=\(receipt.microphoneAuthorization) speech=\(receipt.speechAuthorization)"
    )
  }
  private struct Receipt: Codable {
    let initial: CompanionShellGeometry
    let activity: CompanionShellGeometry
    let peek: CompanionShellGeometry
    let compactVoiceFocusPreserved: Bool
    let voiceCompletionRetracted: Bool
    let hoverFocusPreserved: Bool
    let repeatedHoverAndDraftPreserved: Bool
    let inputMonitoringAllowed: Bool
    let physicalPointerObservationEnabled: Bool
    let accessibilityAllowed: Bool
    let eventTapInstalled: Bool
    let eventTapStatus: String
    let microphoneAuthorization: Int
    let speechAuthorization: Int
  }
  private enum Failure: LocalizedError {
    case message(String)
    var errorDescription: String? {
      switch self {
      case .message(let text): text
      }
    }
  }
}
