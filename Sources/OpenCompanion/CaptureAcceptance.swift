import AppKit
import ApplicationServices
@preconcurrency import ScreenCaptureKit

/// Explicit, local-only installed diagnostic. JPEGs can contain the selected
/// display's private pixels: the caller must supply an ignored dist directory.
/// No model, network, AppModel or persistent-library access occurs here.
enum CaptureAcceptance {
  @MainActor static func run(output: URL) async throws {
    guard output.isFileURL, output.standardizedFileURL.pathComponents.contains("dist") else {
      throw DiagnosticError.message(
        "Capture acceptance output must be inside an ignored dist directory.")
    }
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    let screenAllowed = CGPreflightScreenCaptureAccess()
    let axAllowed = AXIsProcessTrusted()
    var receipt = Receipt(
      screenRecordingAllowed: screenAllowed, accessibilityAllowed: axAllowed,
      ownPID: ProcessInfo.processInfo.processIdentifier,
      ownBundleIdentifier: Bundle.main.bundleIdentifier)
    print("CAPTURE_PERMISSIONS screenRecording=\(screenAllowed) accessibility=\(axAllowed)")
    guard screenAllowed else {
      receipt.status = "blocked"
      receipt.note = "Screen Recording is not allowed. No screen capture was attempted."
      try save(receipt, to: output)
      throw DiagnosticError.message(receipt.note)
    }
    guard let screen = NSScreen.main ?? NSScreen.screens.first,
      let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
    else { throw DiagnosticError.message("No display is available for capture acceptance.") }
    let displayID = number.uint32Value
    receipt.displayID = displayID
    receipt.displayFrame = screen.frame
    let visible = screen.visibleFrame
    let fixtureSize = CGSize(
      width: min(416, visible.width - 60), height: min(272, visible.height - 60))
    guard fixtureSize.width >= 180, fixtureSize.height >= 140 else {
      throw DiagnosticError.message("The display is too small for a meaningful exclusion fixture.")
    }
    let fixtureFrame = CGRect(
      x: visible.midX - fixtureSize.width / 2, y: visible.midY - fixtureSize.height / 2,
      width: fixtureSize.width, height: fixtureSize.height)
    receipt.fixtureFrame = fixtureFrame
    let panel = FixturePanel(
      contentRect: fixtureFrame, styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered, defer: false)
    panel.isReleasedWhenClosed = false
    panel.isOpaque = true
    panel.backgroundColor = .black
    panel.hasShadow = false
    panel.hidesOnDeactivate = false
    panel.ignoresMouseEvents = true
    panel.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
    panel.contentView = CheckerView(frame: CGRect(origin: .zero, size: fixtureSize))
    panel.orderFrontRegardless()
    panel.displayIfNeeded()
    defer {
      panel.orderOut(nil)
      panel.contentView = nil
      panel.close()
    }

    do {
      let content = try await registeredContent(windowID: CGWindowID(panel.windowNumber))
      receipt.ownWindowObserved = content.windows.contains {
        $0.windowID == CGWindowID(panel.windowNumber)
          && $0.owningApplication?.processID == ProcessInfo.processInfo.processIdentifier
      }
      guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
        throw DiagnosticError.message("The fixture display is not available to ScreenCaptureKit.")
      }
      // Control deliberately includes our own fixture. Production capture below
      // uses CaptureService's excludingApplications filter, without changing it.
      let includedFilter = SCContentFilter(display: display, excludingWindows: [])
      let configuration = SCStreamConfiguration()
      let scale = min(1, 1440 / max(screen.frame.width, screen.frame.height))
      configuration.width = Int(screen.frame.width * scale)
      configuration.height = Int(screen.frame.height * scale)
      configuration.showsCursor = false
      configuration.scalesToFit = true
      var included: CGImage?
      var includedMatch = Match(score: 0, topLeftY: true)
      for _ in 0..<3 {
        try Task.checkCancellation()
        let image = try await SCScreenshotManager.captureImage(
          contentFilter: includedFilter, configuration: configuration)
        let match = bestMatch(image: image, displayFrame: screen.frame, fixtureFrame: fixtureFrame)
        included = image
        includedMatch = match
        if match.score >= 0.85 { break }
        try await Task.sleep(for: .milliseconds(60))
      }
      guard let included else {
        throw DiagnosticError.message("No included control image arrived.")
      }
      try jpeg(included).write(
        to: output.appendingPathComponent("included-control.jpg"), options: .atomic)
      receipt.controlMatch = includedMatch.score
      receipt.controlPixels = [included.width, included.height]
      receipt.sampleYMapping = includedMatch.topLeftY ? "top-left" : "bottom-left"

      let screens = Dictionary(
        uniqueKeysWithValues: NSScreen.screens.compactMap { item -> (CGDirectDisplayID, CGRect)? in
          guard
            let id = item.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
          else { return nil }
          return (id.uint32Value, item.frame)
        })
      let evidence = try await CaptureService().capture(
        displayID: displayID,
        foregroundPID: ProcessInfo.processInfo.processIdentifier,
        foregroundName: "Local capture acceptance fixture", screens: screens)
      // Deliberately discard semanticText. Neither OCR nor AX strings are saved,
      // printed, submitted to a model, or sent over a network by this diagnostic.
      try evidence.image.write(
        to: output.appendingPathComponent("excluded-production.jpg"), options: .atomic)
      guard let bitmap = NSBitmapImageRep(data: evidence.image), let excluded = bitmap.cgImage
      else {
        throw DiagnosticError.message("The production JPEG could not be decoded for comparison.")
      }
      let excludedScore = match(
        image: excluded, displayFrame: evidence.screenRect, fixtureFrame: fixtureFrame,
        topLeftY: includedMatch.topLeftY)
      receipt.excludedMatch = excludedScore
      receipt.excludedPixels = [excluded.width, excluded.height]
      receipt.fixturePattern = CheckerView.pattern
      let proven =
        receipt.ownWindowObserved && includedMatch.score >= 0.85
        && excludedScore <= 0.15 && includedMatch.score - excludedScore >= 0.65
      if proven {
        receipt.status = "passed"
        receipt.note =
          "Own fixture is visible in the included control and absent from the production excluded capture. This proves this fixture on this display, not every Space/window configuration."
      } else {
        receipt.status = "visual-inspection-required"
        receipt.note =
          "The control/exclusion pixel thresholds did not establish proof. Inspect both JPEGs using fixtureFrame and displayFrame; no automatic exclusion pass is claimed."
      }
      try save(receipt, to: output)
      print(
        "CAPTURE_EXCLUSION controlMatch=\(includedMatch.score) excludedMatch=\(excludedScore) samples=40"
      )
      guard proven else { throw DiagnosticError.message(receipt.note) }
      print("CAPTURE_ACCEPTANCE_PASSED · real display capture and own-app fixture exclusion")
    } catch {
      if receipt.status == "not-run" {
        receipt.status = "failed"
        receipt.note = error.localizedDescription
        try? save(receipt, to: output)
      }
      print("CAPTURE_ACCEPTANCE_FAILED · \(error.localizedDescription)")
      throw error
    }
  }

  @MainActor private static func registeredContent(windowID: CGWindowID) async throws
    -> SCShareableContent
  {
    let deadline = ProcessInfo.processInfo.systemUptime + 1
    var last: SCShareableContent?
    repeat {
      try Task.checkCancellation()
      let content = try await SCShareableContent.excludingDesktopWindows(
        false, onScreenWindowsOnly: true)
      last = content
      if content.windows.contains(where: { $0.windowID == windowID }) { return content }
      try await Task.sleep(for: .milliseconds(50))
    } while ProcessInfo.processInfo.systemUptime < deadline
    guard let last else {
      throw DiagnosticError.message("ScreenCaptureKit returned no display inventory.")
    }
    return last
  }

  @MainActor private static func bestMatch(
    image: CGImage, displayFrame: CGRect, fixtureFrame: CGRect
  ) -> Match {
    let top = match(
      image: image, displayFrame: displayFrame, fixtureFrame: fixtureFrame, topLeftY: true)
    let bottom = match(
      image: image, displayFrame: displayFrame, fixtureFrame: fixtureFrame, topLeftY: false)
    return top >= bottom ? Match(score: top, topLeftY: true) : Match(score: bottom, topLeftY: false)
  }

  @MainActor private static func match(
    image: CGImage, displayFrame: CGRect, fixtureFrame: CGRect, topLeftY: Bool
  ) -> Double {
    guard displayFrame.width > 0, displayFrame.height > 0 else { return 0 }
    let bitmap = NSBitmapImageRep(cgImage: image)
    let inner = fixtureFrame.insetBy(dx: 16, dy: 16)
    var matches = 0
    for row in 0..<5 {
      for column in 0..<8 {
        let x = inner.minX + (CGFloat(column) + 0.5) * inner.width / 8
        let y = inner.minY + (CGFloat(row) + 0.5) * inner.height / 5
        let px = Int((x - displayFrame.minX) / displayFrame.width * CGFloat(image.width))
        let normalizedY = (y - displayFrame.minY) / displayFrame.height
        let py = Int((topLeftY ? 1 - normalizedY : normalizedY) * CGFloat(image.height))
        guard px >= 0, py >= 0, px < image.width, py < image.height,
          let color = bitmap.colorAt(x: px, y: py)?.usingColorSpace(.deviceRGB)
        else { continue }
        let expected = CheckerView.palette[CheckerView.pattern[row * 8 + column]]
        // Allow JPEG/chroma/color conversion, but keep four colors distinct.
        if abs(color.redComponent - expected.0) < 0.16,
          abs(color.greenComponent - expected.1) < 0.16,
          abs(color.blueComponent - expected.2) < 0.16
        {
          matches += 1
        }
      }
    }
    return Double(matches) / 40
  }

  @MainActor private static func jpeg(_ image: CGImage) throws -> Data {
    guard
      let data = NSBitmapImageRep(cgImage: image).representation(
        using: .jpeg, properties: [.compressionFactor: 0.8])
    else {
      throw DiagnosticError.message("The control image could not be encoded.")
    }
    return data
  }

  private static func save(_ receipt: Receipt, to output: URL) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    try encoder.encode(receipt).write(
      to: output.appendingPathComponent("capture-metadata.json"), options: .atomic)
  }

  private struct Match {
    let score: Double
    let topLeftY: Bool
  }
  private struct Receipt: Codable {
    var status = "not-run"
    var date = Date()
    let screenRecordingAllowed: Bool
    let accessibilityAllowed: Bool
    let ownPID: pid_t
    let ownBundleIdentifier: String?
    var displayID: CGDirectDisplayID?
    var displayFrame: CGRect?
    var fixtureFrame: CGRect?
    var ownWindowObserved = false
    var controlMatch: Double?
    var excludedMatch: Double?
    var controlPixels: [Int]?
    var excludedPixels: [Int]?
    var sampleYMapping: String?
    var fixturePattern: [Int]?
    var note = "No capture has been verified."
  }
  private enum DiagnosticError: LocalizedError {
    case message(String)
    var errorDescription: String? {
      if case .message(let text) = self { text } else { "Capture diagnostic failed." }
    }
  }
}

@MainActor private final class FixturePanel: NSPanel {
  override var canBecomeKey: Bool { false }
  override var canBecomeMain: Bool { false }
}

@MainActor private final class CheckerView: NSView {
  static let palette: [(CGFloat, CGFloat, CGFloat)] = [
    (0.96, 0.07, 0.66), (0.03, 0.91, 0.96), (0.67, 0.95, 0.035), (1, 0.40, 0.03),
  ]
  static let pattern = [
    0, 1, 3, 2, 1, 0, 2, 3, 2, 0, 1, 3, 0, 3, 1, 2, 1, 3, 2, 0, 2, 1, 3, 0, 3, 2, 0, 1, 3, 2, 0, 1,
    0, 2, 3, 1, 2, 0, 1, 3,
  ]
  override func draw(_ dirtyRect: NSRect) {
    NSColor.black.setFill()
    bounds.fill()
    let inner = bounds.insetBy(dx: 16, dy: 16)
    for row in 0..<5 {
      for column in 0..<8 {
        let rgb = Self.palette[Self.pattern[row * 8 + column]]
        NSColor(deviceRed: rgb.0, green: rgb.1, blue: rgb.2, alpha: 1).setFill()
        CGRect(
          x: inner.minX + CGFloat(column) * inner.width / 8,
          y: inner.minY + CGFloat(row) * inner.height / 5,
          width: inner.width / 8 + 0.5, height: inner.height / 5 + 0.5
        ).fill()
      }
    }
  }
}
