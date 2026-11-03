import AppKit
import ApplicationServices
@preconcurrency import ScreenCaptureKit
import Vision

struct ScreenEvidence: Sendable {
  var frameID: UUID
  var revision: UInt64
  var capturedAt: TimeInterval
  var displayID: CGDirectDisplayID
  var foregroundPID: pid_t
  var foregroundName: String
  var screenRect: CGRect
  var windowID: CGWindowID? = nil
  var image: Data
  var semanticText: String
}
/// Immutable source identity carried by a reasoning turn. A newer frame cannot
/// inherit coordinates inferred from an older image, even in the same app.
struct ScreenEvidenceIdentity: Sendable, Equatable {
  let frameID: UUID
  let revision: UInt64
  let displayID: CGDirectDisplayID
  let foregroundPID: pid_t
  let windowID: CGWindowID?
  let screenRect: CGRect

  init(_ evidence: ScreenEvidence) {
    frameID = evidence.frameID
    revision = evidence.revision
    displayID = evidence.displayID
    foregroundPID = evidence.foregroundPID
    windowID = evidence.windowID
    screenRect = evidence.screenRect
  }

  func matches(_ evidence: ScreenEvidence?) -> Bool {
    guard let evidence else { return false }
    return self == ScreenEvidenceIdentity(evidence)
  }
}

struct CapturePublicationGate: Sendable {
  private(set) var generation: UInt64 = 0
  mutating func invalidate() { generation &+= 1 }
  func permits(_ token: UInt64, cancelled: Bool) -> Bool {
    !cancelled && token == generation
  }
}

enum CaptureEvidenceScope: Sendable {
  case display, window, region
  var permitsApplicationAccessibility: Bool {
    if case .display = self { return true }
    return false
  }
}

struct CaptureWindow: Identifiable, Sendable {
  let id: CGWindowID
  let title: String
  let appName: String
  let pid: pid_t
}
actor CaptureService {
  func windows() async throws -> [CaptureWindow] {
    let content = try await SCShareableContent.excludingDesktopWindows(
      false, onScreenWindowsOnly: true)
    return content.windows.filter {
      $0.owningApplication?.processID != ProcessInfo.processInfo.processIdentifier
        && $0.frame.width > 80 && $0.frame.height > 60 && $0.isOnScreen
    }.prefix(150).map {
      CaptureWindow(
        id: $0.windowID, title: $0.title ?? "Untitled window",
        appName: $0.owningApplication?.applicationName ?? "Application",
        pid: $0.owningApplication?.processID ?? 0)
    }
  }
  private var revision: UInt64 = 0
  func capture(
    displayID: CGDirectDisplayID?, foregroundPID: pid_t, foregroundName: String,
    region: CGRect? = nil, windowID: CGWindowID? = nil, screens: [CGDirectDisplayID: CGRect]
  ) async throws -> ScreenEvidence {
    guard CGPreflightScreenCaptureAccess() else {
      throw ProviderError.message(
        "Allow Screen Recording in System Settings, then relaunch OpenCompanion.")
    }
    let content = try await SCShareableContent.excludingDesktopWindows(
      false, onScreenWindowsOnly: true)
    guard
      let display = content.displays.first(where: { $0.displayID == displayID })
        ?? content.displays.first,
      let rect = screens[display.displayID]
    else { throw ProviderError.message("The selected display is unavailable.") }
    try Task.checkCancellation()
    let scope: CaptureEvidenceScope =
      windowID != nil ? .window : (region != nil ? .region : .display)
    let own = content.applications.filter {
      $0.processID == ProcessInfo.processInfo.processIdentifier
    }
    var sourceRect = rect
    let filter: SCContentFilter
    if let windowID {
      guard let window = content.windows.first(where: { $0.windowID == windowID }),
        window.owningApplication?.processID != ProcessInfo.processInfo.processIdentifier
      else { throw ProviderError.message("Selected window is unavailable.") }
      filter = SCContentFilter(desktopIndependentWindow: window)
      let primaryTop = screens[CGMainDisplayID()]?.maxY ?? rect.maxY
      sourceRect = CGRect(
        x: window.frame.minX, y: primaryTop - window.frame.maxY, width: window.frame.width,
        height: window.frame.height)
    } else {
      filter = SCContentFilter(display: display, excludingApplications: own, exceptingWindows: [])
    }
    let config = SCStreamConfiguration()
    let scale = min(1, 1440 / max(sourceRect.width, sourceRect.height))
    config.width = Int(sourceRect.width * scale)
    config.height = Int(sourceRect.height * scale)
    config.showsCursor = false
    config.scalesToFit = true
    var image = try await SCScreenshotManager.captureImage(
      contentFilter: filter, configuration: config)
    let capturedAt = ProcessInfo.processInfo.systemUptime
    try Task.checkCancellation()
    if let region {
      let clipped = region.intersection(sourceRect)
      guard clipped.width >= 8, clipped.height >= 8 else {
        throw ProviderError.message("Selected region is outside this capture.")
      }
      let pixelRect = CGRect(
        x: (clipped.minX - sourceRect.minX) / sourceRect.width * Double(image.width),
        y: (sourceRect.maxY - clipped.maxY) / sourceRect.height * Double(image.height),
        width: clipped.width / sourceRect.width * Double(image.width),
        height: clipped.height / sourceRect.height * Double(image.height))
      guard let crop = image.cropping(to: pixelRect.integral) else {
        throw ProviderError.message("Could not crop the selected region.")
      }
      image = crop
      sourceRect = clipped
    }
    let bitmap = NSBitmapImageRep(cgImage: image)
    guard let data = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.8])
    else { throw ProviderError.message("Screen image could not be encoded.") }
    let ocr = try await Task.detached(priority: .userInitiated) { @Sendable in
      let request = VNRecognizeTextRequest()
      request.recognitionLevel = .accurate
      try VNImageRequestHandler(data: data).perform([request])
      return (request.results ?? []).prefix(250).compactMap { $0.topCandidates(1).first?.string }
        .joined(separator: "\n")
    }.value
    try Task.checkCancellation()
    let semantics: String
    if scope.permitsApplicationAccessibility {
      semantics = await AccessibilityService.describe(pid: foregroundPID)
    } else {
      semantics =
        "Application-wide accessibility text omitted to preserve the selected capture scope."
    }
    try Task.checkCancellation()
    revision += 1
    return ScreenEvidence(
      frameID: UUID(), revision: revision, capturedAt: capturedAt,
      displayID: display.displayID, foregroundPID: foregroundPID, foregroundName: foregroundName,
      screenRect: sourceRect, windowID: windowID, image: data,
      semanticText:
        "Foreground: \(foregroundName)\nAX:\n\(semantics)\nOCR (text bounds are not button bounds):\n\(ocr)"
    )
  }
}
enum AccessibilityService {
  static func describe(pid: pid_t) async -> String {
    await Task.detached(priority: .userInitiated) {
      guard AXIsProcessTrusted() else {
        return "Accessibility permission is unavailable; pixel/OCR evidence only."
      }
      let app = AXUIElementCreateApplication(pid)
      AXUIElementSetMessagingTimeout(app, 0.25)
      var output: [String] = []
      var visited = 0
      let deadline = ProcessInfo.processInfo.systemUptime + 1.2
      func read(_ element: AXUIElement, _ key: CFString) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, key, &value) == .success else { return nil }
        return value
      }
      func walk(_ element: AXUIElement, depth: Int) {
        guard visited < 150, depth < 8, ProcessInfo.processInfo.systemUptime < deadline else {
          return
        }
        visited += 1
        let role = read(element, kAXRoleAttribute as CFString) as? String ?? "element"
        let title =
          read(element, kAXTitleAttribute as CFString) as? String ?? read(
            element, kAXDescriptionAttribute as CFString) as? String ?? ""
        if role != "AXSecureTextField" && !title.isEmpty {
          output.append("\(role): \(title.prefix(180))")
        }
        if let children = read(element, kAXChildrenAttribute as CFString) as? [AXUIElement] {
          for child in children.prefix(40) { walk(child, depth: depth + 1) }
        }
      }
      walk(app, depth: 0)
      return output.joined(separator: "\n")
    }.value
  }
  @MainActor static func requestPermission() {
    let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
    _ = AXIsProcessTrustedWithOptions(options)
  }
}
