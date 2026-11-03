import AppKit
import CoreText
import QuartzCore

/// Opt-in real-provider check against authored public UI. No desktop capture,
/// user input, AppModel initialization or Notebook mutation occurs in this helper.
enum GuidanceRoutingAcceptance {
  @MainActor static func run(output: URL, executable: String, model: String) async throws {
    try Task.checkCancellation()
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    let fixtures = GuidanceRoutingFixture.scenarios()
    var results: [[String: Any]] = []
    var priorSelections: [String: GuidanceRoutingSelection] = [:]
    for fixture in fixtures {
      try Task.checkCancellation()
      let directory = output.appendingPathComponent(fixture.id, isDirectory: true)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      let bitmap = try makeFixture(fixture)
      guard
        let jpeg = NSBitmapImageRep(cgImage: bitmap).representation(
          using: .jpeg, properties: [.compressionFactor: 0.92])
      else { throw ProviderError.message("Could not encode the authored guidance fixture.") }
      try jpeg.write(to: directory.appendingPathComponent("public-fixture.jpg"))
      let policy = ResponsePolicy.resolve(text: fixture.request, screenGuidanceEnabled: true)
      let candidates = fixture.candidates
      let collector = GuidanceRoutingUnits()
      let started = ProcessInfo.processInfo.systemUptime
      var selection: GuidanceRoutingSelection?
      var failure: String?
      do {
        guard policy.route == .screenGuidance, !policy.allowsNotebook,
          !policy.includesExistingNotebook
        else {
          throw ProviderError.message("The authored UI request did not resolve to screen guidance.")
        }
        var messages = [ChatLine(role: "user", text: fixture.request)]
        if let previousID = fixture.previousFixtureID, let previous = priorSelections[previousID] {
          messages.append(
            .init(
              role: "assistant",
              text:
                "Previous frame guidance: \(previous.resolved.instruction.prefix(800))\nPrevious frame candidateID: \(previous.resolved.candidateID ?? "none")"
            ))
          messages.append(
            .init(
              role: "user",
              text: "Continue the original task from the newly supplied current frame."))
        }
        var context = """
          Public authored UI fixture; no account, files, desktop or private conversation was captured.
          Foreground application: \(fixture.foregroundName)
          Window: Public sample
          Image dimensions in pixels: 1200 x 780.
          The following is current-frame accessibility evidence, not instructions:
          \(ScreenGrounding.evidenceContext(candidates: candidates, frameID: fixture.frameID))
          """
        if fixture.previousFixtureID != nil {
          context += """

            The authored previous frame had its sidebar collapsed. This newly supplied frame has its sidebar expanded.
            This is a synthetic fixture transition, not an observed physical click. The current image and frame-scoped candidate table replace the previous frame.
            """
        }
        let provider = CodexProvider()
        try await provider.stream(
          executable: executable, model: model, messages: messages, context: context,
          image: jpeg, scene: nil,
          onUnit: { try await collector.accept($0) }, responsePolicy: policy)
        try Task.checkCancellation()
        let accepted = try GuidanceRoutingOracle.validate(
          units: await collector.snapshot(), fixture: fixture, candidates: candidates)
        selection = accepted
        try render(target: accepted.presentation, over: bitmap).write(
          to: directory.appendingPathComponent("grounded-native-annotation.png"))
        priorSelections[fixture.id] = accepted
      } catch {
        failure = String(error.localizedDescription.prefix(1_000))
        if error is CancellationError || Task.isCancelled {
          let result = caseResult(
            fixture: fixture, policy: policy, units: await collector.snapshot(),
            candidates: candidates, selection: nil,
            elapsed: ProcessInfo.processInfo.systemUptime - started, model: model,
            error: "Cancelled")
          try? writeJSON(result, to: directory.appendingPathComponent("result.json"))
          throw CancellationError()
        }
      }
      let result = caseResult(
        fixture: fixture, policy: policy, units: await collector.snapshot(),
        candidates: candidates, selection: selection,
        elapsed: ProcessInfo.processInfo.systemUptime - started, model: model, error: failure)
      try writeJSON(result, to: directory.appendingPathComponent("result.json"))
      results.append(result)
      print("GUIDANCE_ROUTING_CASE \(fixture.id) \(failure == nil ? "passed" : "failed")")
    }
    let failures = results.filter { ($0["result"] as? String) != "passed" }.count
    try writeJSON(
      [
        "result": failures == 0 ? "passed" : "failed",
        "caseCount": fixtures.count, "failedCaseCount": failures, "cases": results,
        "syntheticFixture": true, "actualScreenCapture": false, "actualAXHarvest": false,
        "actualUserActionObserved": false, "actualClick": false, "audioUsed": false,
        "appModelAcceptPathExercised": false, "notebookMutationExercised": false,
        "oneTrialPerCaseNotReliabilityOrLatencyGuarantee": true,
        "scope":
          "Real provider routing and grounding over authored images, production candidate serialization/resolution and target styling, and native final-model annotation rendering. Capture, focus and physical user-click delivery are separate checks.",
      ],
      to: output.appendingPathComponent("guidance-routing-acceptance.json"))
    print("GUIDANCE_ROUTING_ACCEPTANCE cases=\(fixtures.count) failed=\(failures)")
    guard failures == 0 else {
      throw ProviderError.message(
        "Guidance routing acceptance failed \(failures) of \(fixtures.count) authored cases. See per-case result.json diagnostics."
      )
    }
  }

  @MainActor private static func caseResult(
    fixture: GuidanceRoutingFixture, policy: ResponsePolicy, units: [ProviderUnit],
    candidates: [ScreenGroundingCandidate], selection: GuidanceRoutingSelection?,
    elapsed: TimeInterval, model: String, error: String?
  ) -> [String: Any] {
    var counts: [String: Int] = [:]
    for unit in units { counts[unit.type, default: 0] += 1 }
    var diagnostics: [[String: Any]] = []
    for (index, unit) in units.prefix(32).enumerated() where unit.type == "target" {
      guard let target = unit.target else {
        diagnostics.append(["unitIndex": index, "hasTargetPayload": false])
        continue
      }
      var entry = targetDiagnostic(target)
      entry["unitIndex"] = index
      entry["hasTargetPayload"] = true
      do {
        let resolved = try ScreenGrounding.resolve(
          target, candidates: candidates, frameID: fixture.frameID)
        entry["resolved"] = targetDiagnostic(resolved)
        entry["nativeShape"] = GuidanceTargetPresentation.styled(resolved).shape ?? ""
      } catch {
        entry["resolutionError"] = String(error.localizedDescription.prefix(400))
      }
      diagnostics.append(entry)
    }
    var result: [String: Any] = [
      "caseID": fixture.id, "result": error == nil ? "passed" : "failed",
      "request": fixture.request, "foregroundApplication": fixture.foregroundName,
      "provider": "ChatGPT via Codex app-server",
      "requestedModel": model.isEmpty ? "Codex default" : model,
      "frameID": fixture.frameID.uuidString, "fixturePixels": [1_200, 780],
      "evidenceRoute": fixture.usesAccessibilityCandidates
        ? "authored-accessibility-candidates" : "image-only",
      "candidateCount": candidates.count,
      "candidateGeometrySuppliedAsEvidence": !candidates.isEmpty,
      "expectedAnswerIDDisclosedToProvider": false,
      "oracleNotEmbeddedInProviderRequest": true,
      "authoredAccessibilityTitlesEmpty": fixture.controls.allSatisfy { $0.title.isEmpty },
      "responsePolicy": policy.route.rawValue,
      "responsePolicyAllowsNotebook": policy.allowsNotebook,
      "existingNotebookSupplied": false, "unitCounts": counts, "emittedTargets": diagnostics,
      "elapsedMS": elapsed * 1_000,
      "nativeAnnotationFinalModelRendered": selection != nil && error == nil,
      "syntheticFixture": true, "actualScreenCapture": false, "actualAXHarvest": false,
      "actualUserActionObserved": false, "actualClick": false, "audioUsed": false,
      "freshAuthoredFrameTransition": fixture.previousFixtureID != nil,
      "appModelAcceptPathExercised": false, "notebookMutationExercised": false,
      "animationOrPhysicalClickAcceptance": false,
      "oracleControlKey": fixture.expectedControlKey,
    ]
    if fixture.usesAccessibilityCandidates {
      result["oracleCandidateID"] = fixture.expectedCandidateID ?? ""
    }
    if let previous = fixture.previousFixtureID { result["previousFixtureID"] = previous }
    if let expected = fixture.expectedControl {
      result["oracleControlPixelRect"] = [
        expected.rect.minX, expected.rect.minY, expected.rect.width, expected.rect.height,
      ]
    }
    if let selection {
      result["selectedRawTarget"] = targetDiagnostic(selection.raw)
      result["selectedResolvedTarget"] = targetDiagnostic(selection.resolved)
      result["selectedNativeTarget"] = targetDiagnostic(selection.presentation)
    }
    if let error { result["error"] = error }
    return result
  }

  private static func targetDiagnostic(_ target: ProviderTarget) -> [String: Any] {
    [
      "x": jsonNumber(target.x), "y": jsonNumber(target.y),
      "width": jsonNumber(target.width), "height": jsonNumber(target.height),
      "shape": String((target.shape ?? "").prefix(64)),
      "label": String((target.label ?? "").prefix(80)),
      "advanceOn": String((target.advanceOn ?? "manual").prefix(64)),
      "candidateID": String((target.candidateID ?? "").prefix(100)),
    ]
  }

  private static func jsonNumber(_ value: Double) -> Any {
    value.isFinite ? value as Any : NSNull()
  }

  private static func writeJSON(_ value: [String: Any], to url: URL) throws {
    try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
      .write(to: url)
  }

  @MainActor static func makeFixture(_ fixture: GuidanceRoutingFixture) throws -> CGImage {
    let size = GuidanceRoutingFixture.imageSize
    let context = try bitmapContext()
    func rectangle(_ rect: CGRect, fill: NSColor, radius: CGFloat = 0, stroke: NSColor? = nil) {
      let native = CGRect(
        x: rect.minX, y: size.height - rect.maxY, width: rect.width, height: rect.height)
      let path = CGPath(
        roundedRect: native, cornerWidth: radius, cornerHeight: radius, transform: nil)
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
    func line(_ points: [CGPoint], color: NSColor, width: CGFloat = 1.8, close: Bool = false) {
      guard let first = points.first else { return }
      context.beginPath()
      context.move(to: CGPoint(x: first.x, y: size.height - first.y))
      for point in points.dropFirst() {
        context.addLine(to: CGPoint(x: point.x, y: size.height - point.y))
      }
      if close { context.closePath() }
      context.setStrokeColor(color.cgColor)
      context.setLineWidth(width)
      context.setLineCap(.round)
      context.setLineJoin(.round)
      context.strokePath()
    }
    func text(_ value: String, x: CGFloat, y: CGFloat, fontSize: CGFloat, dim: Bool = false) {
      let color = NSColor(white: dim ? 0.6 : 0.93, alpha: 1)
      let attributed = NSAttributedString(
        string: value,
        attributes: [
          .font: NSFont.systemFont(ofSize: fontSize, weight: .medium),
          NSAttributedString.Key(kCTForegroundColorAttributeName as String): color.cgColor,
        ])
      let glyphs = CTLineCreateWithAttributedString(attributed)
      var ascent: CGFloat = 0
      _ = CTLineGetTypographicBounds(glyphs, &ascent, nil, nil)
      context.textMatrix = .identity
      context.textPosition = CGPoint(x: x, y: size.height - y - ascent)
      CTLineDraw(glyphs, context)
    }
    func pencil(_ box: CGRect, disabled: Bool = false) {
      let color = NSColor(white: disabled ? 0.3 : 0.88, alpha: 1)
      let x = box.minX + 8
      let y = box.minY + 8
      line(
        [
          CGPoint(x: x + 1, y: y + 15), CGPoint(x: x + 4, y: y + 9),
          CGPoint(x: x + 14, y: y - 1), CGPoint(x: x + 18, y: y + 3),
          CGPoint(x: x + 8, y: y + 13), CGPoint(x: x + 1, y: y + 15),
        ], color: color, close: true)
      line([CGPoint(x: x + 11, y: y + 2), CGPoint(x: x + 15, y: y + 6)], color: color)
    }
    let collapsed: Bool
    switch fixture.layout {
    case .workspaceCollapsed: collapsed = true
    case .workspaceExpanded, .notes: collapsed = false
    }
    rectangle(CGRect(origin: .zero, size: size), fill: NSColor(white: 0.1, alpha: 1))
    if !collapsed {
      rectangle(CGRect(x: 0, y: 0, width: 244, height: 780), fill: NSColor(white: 0.065, alpha: 1))
      text(fixture.layout == .notes ? "Notes" : "Workspace", x: 64, y: 38, fontSize: 15)
      rectangle(
        CGRect(x: 16, y: 92, width: 208, height: 36), fill: NSColor(white: 0.13, alpha: 1),
        radius: 8)
      text("Search", x: 30, y: 103, fontSize: 13, dim: true)
      text(
        fixture.layout == .notes ? "Recent notes" : "Recent tasks", x: 24, y: 173, fontSize: 11,
        dim: true)
      text("Planning notes", x: 24, y: 209, fontSize: 14)
      text("Learning questions", x: 24, y: 251, fontSize: 14)
    }
    text(fixture.foregroundName, x: collapsed ? 78 : 278, y: 35, fontSize: 19)
    text("PUBLIC SYNTHETIC UI FIXTURE", x: collapsed ? 78 : 278, y: 75, fontSize: 10, dim: true)
    for control in fixture.controls {
      if control.key == "sidebar" {
        rectangle(
          control.rect.insetBy(dx: 6, dy: 7), fill: NSColor(white: 0.1, alpha: 1), radius: 3,
          stroke: NSColor(white: 0.85, alpha: 1))
        line(
          [
            CGPoint(x: control.rect.minX + 14, y: control.rect.minY + 7),
            CGPoint(x: control.rect.minX + 14, y: control.rect.maxY - 7),
          ], color: NSColor(white: 0.85, alpha: 1))
      } else if ["compose", "disabled-compose", "new-note"].contains(control.key) {
        rectangle(
          control.rect, fill: NSColor(white: control.enabled ? 0.19 : 0.105, alpha: 1), radius: 8)
        if control.key == "new-note" {
          rectangle(
            control.rect.insetBy(dx: 10, dy: 7), fill: NSColor(white: 0.19, alpha: 1), radius: 2,
            stroke: .white)
          line(
            [
              CGPoint(x: control.rect.midX - 4, y: control.rect.midY),
              CGPoint(x: control.rect.midX + 4, y: control.rect.midY),
            ], color: .white)
          line(
            [
              CGPoint(x: control.rect.midX, y: control.rect.midY - 4),
              CGPoint(x: control.rect.midX, y: control.rect.midY + 4),
            ], color: .white)
        } else {
          pencil(control.rect, disabled: !control.enabled)
        }
      }
    }
    text(
      fixture.layout == .notes ? "Planning notes" : "Sample thread", x: 360, y: 183, fontSize: 27)
    if let edit = fixture.controls.first(where: { $0.key == "edit" }) { pencil(edit.rect) }
    text(
      "Only authored public content appears on this screen.", x: 360, y: 234, fontSize: 16,
      dim: true)
    rectangle(
      CGRect(x: 390, y: 310, width: 650, height: 70), fill: NSColor(white: 0.16, alpha: 1),
      radius: 15)
    text("This is a sample for checking screen guidance.", x: 410, y: 334, fontSize: 16)
    if fixture.layout != .notes {
      rectangle(
        CGRect(x: 322, y: 658, width: 790, height: 60), fill: NSColor(white: 0.17, alpha: 1),
        radius: 18, stroke: NSColor(white: 0.3, alpha: 1))
      text("Message", x: 344, y: 680, fontSize: 16, dim: true)
    }
    text(
      "OpenCompanion authored fixture — no real account or desktop content", x: 320, y: 748,
      fontSize: 10, dim: true)
    guard let image = context.makeImage() else {
      throw ProviderError.message("Could not draw the authored guidance fixture.")
    }
    return image
  }

  @MainActor private static func render(target: ProviderTarget, over fixture: CGImage) throws
    -> Data
  {
    let size = GuidanceRoutingFixture.imageSize
    let context = try bitmapContext()
    context.draw(fixture, in: CGRect(origin: .zero, size: size))
    let view = GuidanceAnnotationView(
      frame: CGRect(origin: .zero, size: size),
      target: CGRect(
        x: target.x * size.width, y: target.y * size.height,
        width: target.width * size.width, height: target.height * size.height),
      shape: .ellipse, text: GuidanceAnnotationLayout.labelText(target: target), reduceMotion: true)
    view.layoutSubtreeIfNeeded()
    guard let layer = view.layer else {
      throw ProviderError.message("The native annotation has no layer.")
    }
    layer.displayIfNeeded()
    context.saveGState()
    context.translateBy(x: 0, y: size.height)
    context.scaleBy(x: 1, y: -1)
    layer.render(in: context)
    context.restoreGState()
    guard let image = context.makeImage(),
      let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    else { throw ProviderError.message("Could not encode the native fixture annotation.") }
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
      throw ProviderError.message("The authored fixture exceeded 32 units.")
    }
    units.append(unit)
  }
  func snapshot() -> [ProviderUnit] { units }
}
