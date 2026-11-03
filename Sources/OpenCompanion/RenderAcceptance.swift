import AppKit
import CompanionCore

enum RenderAcceptance {
  @MainActor static func run() throws {
    let output = URL(
      fileURLWithPath: CommandLine.arguments.drop(while: { $0 != "--render-acceptance" })
        .dropFirst().first ?? "/tmp/OpenCompanion-Acceptance")
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    let scenes = [
      ("motor", try BuiltInLessons.motor()), ("lever", BuiltInLessons.lever()),
      ("circuit", BuiltInLessons.circuit()),
    ]
    for (name, document) in scenes {
      let view = RetainedCanvasView(
        frame: NSRect(x: 0, y: 0, width: document.width, height: document.height))
      view.render(document, time: 0.7, selectedID: nil)
      view.layoutSubtreeIfNeeded()
      let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(document.width), pixelsHigh: Int(document.height),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
      let context = NSGraphicsContext(bitmapImageRep: rep)!
      NSGraphicsContext.saveGraphicsState()
      NSGraphicsContext.current = context
      context.cgContext.translateBy(x: 0, y: document.height)
      context.cgContext.scaleBy(x: 1, y: -1)
      view.layer?.render(in: context.cgContext)
      NSGraphicsContext.restoreGraphicsState()
      try rep.representation(using: .png, properties: [:])!.write(
        to: output.appendingPathComponent(name + ".png"))
      try view.pdfData().write(to: output.appendingPathComponent(name + ".pdf"))
    }
    if let window = NSApp.windows.first(where: { $0.title == "OpenCompanion" }),
      let view = window.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)
    {
      view.cacheDisplay(in: view.bounds, to: rep)
      if let data = rep.representation(using: .png, properties: [:]) {
        try data.write(to: output.appendingPathComponent("workspace.png"))
      }
    }
  }
}
