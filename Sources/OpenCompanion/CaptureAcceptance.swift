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
    try samplerRegression()
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
      var includedData: Data?
      var includedMatch = Match(score: 0, topLeftY: true, reference: nil)
      for _ in 0..<3 {
        try Task.checkCancellation()
        let source = try await SCScreenshotManager.captureImage(
          contentFilter: includedFilter, configuration: configuration)
        // Compare the same JPEG representation in both directions. AppKit's
        // JPEG encoder can attach a different color profile than the SCK image.
        let data = try jpeg(source)
        guard let image = NSBitmapImageRep(data: data)?.cgImage else {
          throw DiagnosticError.message("The included JPEG could not be decoded.")
        }
        let match = bestMatch(image: image, displayFrame: screen.frame, fixtureFrame: fixtureFrame)
        included = image
        includedData = data
        includedMatch = match
        if match.score >= 0.85 { break }
        try await Task.sleep(for: .milliseconds(60))
      }
      guard let included, let includedData else {
        throw DiagnosticError.message("No included control image arrived.")
      }
      try includedData.write(
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
        topLeftY: includedMatch.topLeftY, reference: includedMatch.reference)
      receipt.calibratedPaletteSRGB = includedMatch.reference?.colors.map {
        [$0.red, $0.green, $0.blue]
      }
      receipt.calibrationMinimumSeparation = includedMatch.reference?.minimumSeparation
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

  /// Read-only replay for an already-authorized local receipt. This performs no
  /// screen capture and never rewrites the images or the original receipt.
  @MainActor static func replaySavedArtifacts(output: URL) throws -> (
    control: Double, excluded: Double
  ) {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let receipt = try decoder.decode(
      Receipt.self, from: Data(contentsOf: output.appendingPathComponent("capture-metadata.json")))
    guard let displayFrame = receipt.displayFrame, let fixtureFrame = receipt.fixtureFrame,
      let control = NSBitmapImageRep(
        data: try Data(contentsOf: output.appendingPathComponent("included-control.jpg")))?.cgImage,
      let excluded = NSBitmapImageRep(
        data: try Data(contentsOf: output.appendingPathComponent("excluded-production.jpg")))?
        .cgImage
    else { throw DiagnosticError.message("The saved receipt or JPEGs are incomplete.") }
    let reference = bestMatch(
      image: control, displayFrame: displayFrame, fixtureFrame: fixtureFrame)
    let excludedScore = match(
      image: excluded, displayFrame: displayFrame, fixtureFrame: fixtureFrame,
      topLeftY: reference.topLeftY, reference: reference.reference)
    return (reference.score, excludedScore)
  }

  @MainActor private static func bestMatch(
    image: CGImage, displayFrame: CGRect, fixtureFrame: CGRect
  ) -> Match {
    let top = calibratedMatch(
      image: image, displayFrame: displayFrame, fixtureFrame: fixtureFrame, topLeftY: true)
    let bottom = calibratedMatch(
      image: image, displayFrame: displayFrame, fixtureFrame: fixtureFrame, topLeftY: false)
    return top.score >= bottom.score ? top : bottom
  }

  @MainActor private static func calibratedMatch(
    image: CGImage, displayFrame: CGRect, fixtureFrame: CGRect, topLeftY: Bool
  ) -> Match {
    let values = samples(
      image: image, displayFrame: displayFrame, fixtureFrame: fixtureFrame, topLeftY: topLeftY)
    guard values.count == 40 else { return Match(score: 0, topLeftY: topLeftY, reference: nil) }
    var colors: [RGB] = []
    for label in 0..<4 {
      var sum = RGB(red: 0, green: 0, blue: 0)
      var count = 0.0
      for index in values.indices where CheckerView.pattern[index] == label {
        sum.red += values[index].red
        sum.green += values[index].green
        sum.blue += values[index].blue
        count += 1
      }
      colors.append(RGB(red: sum.red / count, green: sum.green / count, blue: sum.blue / count))
    }
    var separation = Double.infinity
    for first in 0..<4 {
      for second in (first + 1)..<4 {
        separation = min(separation, colors[first].distance(to: colors[second]))
      }
    }
    // A uniform/random desktop patch cannot calibrate itself into a checker:
    // all four groups must be distinct, and each repeated group must be tight.
    guard separation >= 0.30 else { return Match(score: 0, topLeftY: topLeftY, reference: nil) }
    let reference = Reference(
      colors: colors, tolerance: min(0.18, separation * 0.28), minimumSeparation: separation)
    return Match(
      score: score(values, reference: reference), topLeftY: topLeftY, reference: reference)
  }

  @MainActor private static func match(
    image: CGImage, displayFrame: CGRect, fixtureFrame: CGRect, topLeftY: Bool,
    reference: Reference?
  ) -> Double {
    guard let reference else { return 0 }
    return score(
      samples(
        image: image, displayFrame: displayFrame, fixtureFrame: fixtureFrame, topLeftY: topLeftY),
      reference: reference)
  }

  @MainActor private static func score(_ values: [RGB], reference: Reference) -> Double {
    guard values.count == 40 else { return 0 }
    var matches = 0
    for index in values.indices {
      if values[index].distance(to: reference.colors[CheckerView.pattern[index]])
        <= reference.tolerance
      {
        matches += 1
      }
    }
    return Double(matches) / 40
  }

  @MainActor private static func samples(
    image: CGImage, displayFrame: CGRect, fixtureFrame: CGRect, topLeftY: Bool
  ) -> [RGB] {
    guard displayFrame.width > 0, displayFrame.height > 0 else { return [] }
    let bitmap = NSBitmapImageRep(cgImage: image)
    let inner = fixtureFrame.insetBy(dx: 16, dy: 16)
    var values: [RGB] = []
    for row in 0..<5 {
      for column in 0..<8 {
        let x = inner.minX + (CGFloat(column) + 0.5) * inner.width / 8
        let y = inner.minY + (CGFloat(row) + 0.5) * inner.height / 5
        let px = Int((x - displayFrame.minX) / displayFrame.width * CGFloat(image.width))
        let normalizedY = (y - displayFrame.minY) / displayFrame.height
        let py = Int((topLeftY ? 1 - normalizedY : normalizedY) * CGFloat(image.height))
        guard px >= 0, py >= 0, px < image.width, py < image.height,
          let color = bitmap.colorAt(x: px, y: py)?.usingColorSpace(.sRGB)
        else { return [] }
        values.append(
          RGB(red: color.redComponent, green: color.greenComponent, blue: color.blueComponent))
      }
    }
    return values
  }

  /// Synthetic regression uses no screen pixels: JPEG/profile conversion,
  /// negative display origins, retained fixtures and empty controls are checked.
  @MainActor static func samplerRegression() throws {
    let display = CGRect(x: -300, y: 120, width: 800, height: 600)
    let fixture = CGRect(x: -100, y: 220, width: 416, height: 272)
    func synthetic(checker: Bool) throws -> CGImage {
      guard
        let context = CGContext(
          data: nil, width: 800, height: 600, bitsPerComponent: 8,
          bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
      else { throw DiagnosticError.message("Synthetic sampler bitmap could not be created.") }
      context.setFillColor(CGColor(gray: 0.12, alpha: 1))
      context.fill(CGRect(x: 0, y: 0, width: 800, height: 600))
      if checker {
        let inner = fixture.offsetBy(dx: -display.minX, dy: -display.minY).insetBy(dx: 16, dy: 16)
        for row in 0..<5 {
          for column in 0..<8 {
            let rgb = CheckerView.palette[CheckerView.pattern[row * 8 + column]]
            context.setFillColor(CGColor(red: rgb.0, green: rgb.1, blue: rgb.2, alpha: 1))
            context.fill(
              CGRect(
                x: inner.minX + CGFloat(column) * inner.width / 8,
                y: inner.minY + CGFloat(row) * inner.height / 5, width: inner.width / 8,
                height: inner.height / 5))
          }
        }
      }
      guard let image = context.makeImage(),
        let decoded = NSBitmapImageRep(data: try jpeg(image))?.cgImage
      else {
        throw DiagnosticError.message("Synthetic JPEG conversion failed.")
      }
      return decoded
    }
    let checker = try synthetic(checker: true)
    let empty = try synthetic(checker: false)
    let control = bestMatch(image: checker, displayFrame: display, fixtureFrame: fixture)
    let retained = match(
      image: checker, displayFrame: display, fixtureFrame: fixture,
      topLeftY: control.topLeftY, reference: control.reference)
    let excluded = match(
      image: empty, displayFrame: display, fixtureFrame: fixture,
      topLeftY: control.topLeftY, reference: control.reference)
    let invalidControl = bestMatch(image: empty, displayFrame: display, fixtureFrame: fixture)
    guard control.score >= 0.95, retained >= 0.95, excluded <= 0.05,
      invalidControl.score == 0, invalidControl.reference == nil
    else { throw DiagnosticError.message("Synthetic checker sampler regression failed.") }
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

  private struct RGB {
    var red: Double
    var green: Double
    var blue: Double
    func distance(to other: RGB) -> Double {
      sqrt(pow(red - other.red, 2) + pow(green - other.green, 2) + pow(blue - other.blue, 2))
    }
  }
  private struct Reference {
    let colors: [RGB]
    let tolerance: Double
    let minimumSeparation: Double
  }
  private struct Match {
    let score: Double
    let topLeftY: Bool
    let reference: Reference?
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
    var calibratedPaletteSRGB: [[Double]]?
    var calibrationMinimumSeparation: Double?
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
