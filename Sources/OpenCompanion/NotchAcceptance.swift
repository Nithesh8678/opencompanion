import AVFoundation
import AppKit
import ApplicationServices
import Speech

/// Exercises real panel placement/focus with an isolated model and synthetic
/// pointer locations. It does not inject OS input, record audio, or call a model.
enum NotchAcceptance {
  @MainActor static func run(shell: CompanionShell, model: AppModel, output: URL) async throws {
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    let initial = shell.geometry
    let originalForeground = NSWorkspace.shared.frontmostApplication?.processIdentifier
    guard initial.surface == "tucked" else {
      throw Failure.message("The acceptance pointer must start outside the notch.")
    }
    if let cutout = initial.cutoutFrame {
      guard initial.frame == cutout, cutout.maxY == initial.displayFrame.maxY else {
        throw Failure.message("Idle panel does not coincide with the camera cutout.")
      }
    }
    model.input = "An unsent draft stays here."
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
    let outside = CGPoint(x: initial.displayFrame.minX + 30, y: initial.displayFrame.minY + 30)
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
    let receipt = Receipt(
      initial: initial, peek: peek, hoverFocusPreserved: true,
      repeatedHoverAndDraftPreserved: true, inputMonitoringAllowed: CGPreflightListenEventAccess(),
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
    print(
      "NOTCH_ACCEPTANCE_PASSED · cutout placement, repeated synthetic hover, draft and foreground focus"
    )
    print(
      "VOICE_PREFLIGHT tapInstalled=\(availability.isInstalled) inputMonitoring=\(receipt.inputMonitoringAllowed) accessibility=\(receipt.accessibilityAllowed) microphone=\(receipt.microphoneAuthorization) speech=\(receipt.speechAuthorization)"
    )
  }
  private struct Receipt: Codable {
    let initial: CompanionShellGeometry
    let peek: CompanionShellGeometry
    let hoverFocusPreserved: Bool
    let repeatedHoverAndDraftPreserved: Bool
    let inputMonitoringAllowed: Bool
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
