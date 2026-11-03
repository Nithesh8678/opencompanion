import AppKit
import CoreText
import QuartzCore

/// Explicit opt-in provider grounding and native-rendering check. The image is
/// authored entirely from generic fixture text and shapes, never desktop pixels.
enum GuidanceRoutingAcceptance {
  private static let request = "How do I create a new chat in ChatGPT?"
  private static let size = CGSize(width: 1_200, height: 780)
  // Independent oracle. Its coordinates are not included in provider input.
  private static let newChatButton = CGRect(x: 20, y: 78, width: 204, height: 44)

  @MainActor static func run(output: URL, executable: String, model: String) async throws {
    try Task.checkCancellation()
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    let policy = ResponsePolicy.resolve(text: request, screenGuidanceEnabled: true)
    guard policy.route == .screenGuidance, !policy.allowsNotebook,
      !policy.includesExistingNotebook
    else {
      throw ProviderError.message("The exact new-chat request did not resolve to screen guidance.")
    }
    let fixture = try makeFixture()
    let bitmap = NSBitmapImageRep(cgImage: fixture)
    guard let jpeg = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.92])
    else { throw ProviderError.message("Could not encode the public guidance fixture.") }
    try jpeg.write(to: output.appendingPathComponent("public-chat-fixture.jpg"))
    let collector = GuidanceRoutingUnits()
    let provider = CodexProvider()
    let started = ProcessInfo.processInfo.systemUptime
    do {
      try await provider.stream(
        executable: executable, model: model,
        messages: [.init(role: "user", text: request)],
        context:
          "Public synthetic chat application fixture. All labels and messages are generic; no account, files, desktop, or prior conversation was captured.",
        image: jpeg, scene: nil,
        onUnit: { try await collector.accept($0) }, responsePolicy: policy)
      try Task.checkCancellation()
      let units = await collector.snapshot()
      guard !units.isEmpty, units.allSatisfy({ ["text", "target"].contains($0.type) }),
        !units.contains(where: { $0.type == "scene" })
      else {
        throw ProviderError.message("The guidance provider emitted a scene or unsupported unit.")
      }
      let targetUnits = units.filter { $0.type == "target" }
      let targets = targetUnits.compactMap(\.target)
      let clickTargets = targets.filter { $0.advanceOn == "click" }
      guard targets.count == targetUnits.count, clickTargets.count == 1,
        let selected = clickTargets.first, isGroundedNewChatCircle(selected)
      else {
        throw ProviderError.message(
          "The response must contain exactly one click-advancing target, a bounded ellipse on the visible New chat control; text alone does not pass."
        )
      }
      try render(target: selected, over: fixture).write(
        to: output.appendingPathComponent("grounded-new-chat-circle.png"))
      try writeResult(
        output: output, policy: policy, units: units, selected: selected,
        elapsed: ProcessInfo.processInfo.systemUptime - started, model: model, error: nil)
    } catch {
      try? writeResult(
        output: output, policy: policy, units: await collector.snapshot(), selected: nil,
        elapsed: ProcessInfo.processInfo.systemUptime - started, model: model,
        error: error.localizedDescription)
      throw error
    }
  }

  private static func isGroundedNewChatCircle(_ target: ProviderTarget) -> Bool {
    guard target.shape == "ellipse", target.advanceOn == "click",
      target.instruction.utf8.count <= 32_000,
      (target.label?.prefix(81).count ?? 0) <= 80,
      let rect = ScreenGuidancePolicy.targetRect(
        target, in: CGRect(origin: .zero, size: size)),
      target.width <= 0.35, target.height <= 0.18
    else { return false }
    // Convert the known top-left fixture center to the helper's AppKit axis.
    return rect.contains(CGPoint(x: newChatButton.midX, y: size.height - newChatButton.midY))
  }

  @MainActor private static func writeResult(
    output: URL, policy: ResponsePolicy, units: [ProviderUnit], selected: ProviderTarget?,
    elapsed: TimeInterval, model: String, error: String?
  ) throws {
    var counts: [String: Int] = [:]
    for unit in units { counts[unit.type, default: 0] += 1 }
    var targetDiagnostics: [[String: Any]] = []
    for (index, unit) in units.prefix(32).enumerated() where unit.type == "target" {
      guard let target = unit.target else {
        targetDiagnostics.append(["unitIndex": index, "hasTargetPayload": false])
        continue
      }
      let rect = ScreenGuidancePolicy.targetRect(
        target, in: CGRect(origin: .zero, size: size))
      let oracleCenter = CGPoint(x: newChatButton.midX, y: size.height - newChatButton.midY)
      targetDiagnostics.append([
        "unitIndex": index, "hasTargetPayload": true,
        "x": jsonNumber(target.x), "y": jsonNumber(target.y),
        "width": jsonNumber(target.width), "height": jsonNumber(target.height),
        "shape": String((target.shape ?? "").prefix(64)),
        "label": String((target.label ?? "").prefix(80)),
        "advanceOn": String((target.advanceOn ?? "manual").prefix(64)),
        "validNormalizedRect": rect != nil,
        "containsNewChatCenter": rect?.contains(oracleCenter) ?? false,
        "withinCompactControlBounds": target.width <= 0.35 && target.height <= 0.18,
        "passesGroundingOracle": isGroundedNewChatCircle(target),
      ])
    }
    var result: [String: Any] = [
      "result": error == nil ? "passed" : "failed",
      "request": request, "provider": "ChatGPT via Codex app-server",
      "requestedModel": model.isEmpty ? "Codex default" : model,
      "syntheticFixture": true, "fixturePixels": [1_200, 780],
      "actualScreenCapture": false, "actualClick": false, "audioUsed": false,
      "appModelAcceptPathExercised": false, "notebookMutationExercised": false,
      "responsePolicy": policy.route.rawValue,
      "responsePolicyAllowsNotebook": policy.allowsNotebook,
      "existingNotebookSupplied": false,
      "oracleCoordinatesSuppliedToProvider": false,
      "unitCounts": counts, "emittedTargets": targetDiagnostics,
      "elapsedMS": elapsed * 1_000,
      "oneTrialNotLatencyGuarantee": true,
      "nativeAnnotationFinalModelRendered": selected != nil && error == nil,
      "animationOrPhysicalClickAcceptance": false,
      "scope":
        "Provider policy and synthetic-image grounding plus native final-model annotation rendering. Normal capture/focus and physical click delivery are separate checks.",
    ]
    if let selected {
      result["selectedTarget"] =
        [
          "x": selected.x, "y": selected.y, "width": selected.width, "height": selected.height,
          "shape": selected.shape ?? "", "label": selected.label ?? "",
          "advanceOn": selected.advanceOn ?? "manual",
        ] as [String: Any]
    }
    if let error { result["error"] = error }
    try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
      .write(to: output.appendingPathComponent("guidance-routing-acceptance.json"))
  }

  private static func jsonNumber(_ value: Double) -> Any {
    value.isFinite ? value as Any : NSNull()
  }

  @MainActor private static func makeFixture() throws -> CGImage {
    let context = try bitmapContext()
    func rectangle(_ topLeft: CGRect, fill: NSColor, radius: CGFloat = 0, stroke: NSColor? = nil) {
      let rect = CGRect(
        x: topLeft.minX, y: size.height - topLeft.maxY,
        width: topLeft.width, height: topLeft.height)
      let path = CGPath(
        roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
      context.addPath(path)
      context.setFillColor(fill.cgColor)
      context.fillPath()
      if let stroke {
        context.addPath(path)
        context.setStrokeColor(stroke.cgColor)
        context.setLineWidth(1)
        context.strokePath()
      }
    }
    func text(_ value: String, x: CGFloat, y: CGFloat, fontSize: CGFloat, dim: Bool = false) {
      let color = NSColor(white: dim ? 0.6 : 0.93, alpha: 1)
      let attributed = NSAttributedString(
        string: value,
        attributes: [
          .font: NSFont.systemFont(ofSize: fontSize, weight: .medium),
          .foregroundColor: color,
          NSAttributedString.Key(kCTForegroundColorAttributeName as String): color.cgColor,
        ])
      let line = CTLineCreateWithAttributedString(attributed)
      var ascent: CGFloat = 0
      _ = CTLineGetTypographicBounds(line, &ascent, nil, nil)
      context.textMatrix = .identity
      context.textPosition = CGPoint(x: x, y: size.height - y - ascent)
      CTLineDraw(line, context)
    }
    rectangle(CGRect(origin: .zero, size: size), fill: NSColor(white: 0.1, alpha: 1))
    rectangle(
      CGRect(x: 0, y: 0, width: 244, height: size.height), fill: NSColor(white: 0.075, alpha: 1))
    text("ChatGPT", x: 24, y: 26, fontSize: 21)
    rectangle(
      newChatButton, fill: NSColor(white: 0.18, alpha: 1), radius: 9,
      stroke: NSColor(white: 0.36, alpha: 1))
    text("+", x: 33, y: 91, fontSize: 17)
    text("New chat", x: 58, y: 91, fontSize: 16)
    text("Search chats", x: 28, y: 153, fontSize: 16)
    text("Library", x: 28, y: 198, fontSize: 16)
    text("Projects", x: 28, y: 243, fontSize: 16)
    rectangle(CGRect(x: 20, y: 299, width: 204, height: 1), fill: NSColor(white: 0.2, alpha: 1))
    text("Recent chats", x: 28, y: 330, fontSize: 12, dim: true)
    text("Planning notes", x: 28, y: 371, fontSize: 14)
    text("Learning questions", x: 28, y: 414, fontSize: 14)
    text("ChatGPT", x: 278, y: 33, fontSize: 19)
    text("PUBLIC SYNTHETIC UI FIXTURE", x: 278, y: 76, fontSize: 11, dim: true)
    rectangle(
      CGRect(x: 1_060, y: 28, width: 110, height: 36), fill: NSColor(white: 0.16, alpha: 1),
      radius: 8)
    text("Settings", x: 1_080, y: 37, fontSize: 14)
    text("Sample conversation", x: 360, y: 185, fontSize: 28)
    text("This screen contains only public fixture text.", x: 360, y: 235, fontSize: 17, dim: true)
    rectangle(
      CGRect(x: 390, y: 310, width: 650, height: 70), fill: NSColor(white: 0.16, alpha: 1),
      radius: 15)
    text("Hello. This is a synthetic interface for a guidance check.", x: 410, y: 333, fontSize: 16)
    rectangle(
      CGRect(x: 320, y: 650, width: 790, height: 68), fill: NSColor(white: 0.17, alpha: 1),
      radius: 20,
      stroke: NSColor(white: 0.3, alpha: 1))
    text("Ask anything", x: 344, y: 674, fontSize: 16, dim: true)
    text(
      "OpenCompanion fixture — no real account or desktop content", x: 320, y: 748, fontSize: 11,
      dim: true)
    guard let image = context.makeImage() else {
      throw ProviderError.message("Could not draw the public guidance fixture.")
    }
    return image
  }

  @MainActor private static func render(target: ProviderTarget, over fixture: CGImage) throws
    -> Data
  {
    let context = try bitmapContext()
    context.draw(fixture, in: CGRect(origin: .zero, size: size))
    let view = GuidanceAnnotationView(
      frame: CGRect(origin: .zero, size: size),
      target: CGRect(
        x: target.x * size.width, y: target.y * size.height,
        width: target.width * size.width, height: target.height * size.height),
      shape: .ellipse,
      text: GuidanceAnnotationLayout.labelText(target: target), reduceMotion: true)
    view.layoutSubtreeIfNeeded()
    guard let layer = view.layer else {
      throw ProviderError.message("The native guidance annotation has no backing layer.")
    }
    layer.displayIfNeeded()
    context.saveGState()
    context.translateBy(x: 0, y: size.height)
    context.scaleBy(x: 1, y: -1)
    layer.render(in: context)
    context.restoreGState()
    guard let image = context.makeImage(),
      let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    else { throw ProviderError.message("Could not encode the native guidance fixture render.") }
    return data
  }

  private static func bitmapContext() throws -> CGContext {
    guard let space = CGColorSpace(name: CGColorSpace.sRGB),
      let context = CGContext(
        data: nil, width: 1_200, height: 780, bitsPerComponent: 8, bytesPerRow: 0,
        space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { throw ProviderError.message("Could not allocate the bounded fixture bitmap.") }
    return context
  }
}

private actor GuidanceRoutingUnits {
  private var units: [ProviderUnit] = []
  func accept(_ unit: ProviderUnit) throws {
    guard units.count < 32 else {
      throw ProviderError.message("The public guidance fixture exceeded its bounded unit count.")
    }
    units.append(unit)
  }
  func snapshot() -> [ProviderUnit] { units }
}
