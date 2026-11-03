import AppKit
import CompanionCore
import UniformTypeIdentifiers

@MainActor enum SceneExport {
  static func render(_ document: SceneDocument, time: Double, pdf: Bool) throws -> Data {
    guard document.width <= 4096, document.height <= 4096,
      document.width * document.height <= 4_000_000
    else {
      throw ProviderError.message(
        "The export exceeds the bounded image/page size. Resize the document first.")
    }
    guard !document.nodes.contains(where: { $0.kind == .mesh }) else {
      throw ProviderError.message(
        "3D stage export is not implemented yet. Export the editable scene JSON instead.")
    }
    let view = RetainedCanvasView(
      frame: NSRect(x: 0, y: 0, width: document.width, height: document.height))
    view.render(document, time: time, selectedID: nil)
    view.layoutSubtreeIfNeeded()
    if pdf {
      let data = NSMutableData()
      guard let consumer = CGDataConsumer(data: data as CFMutableData) else {
        throw ProviderError.message("Could not create PDF output.")
      }
      var box = CGRect(x: 0, y: 0, width: document.width, height: document.height)
      guard let context = CGContext(consumer: consumer, mediaBox: &box, nil) else {
        throw ProviderError.message("Could not initialize PDF output.")
      }
      context.beginPDFPage(nil)
      context.translateBy(x: 0, y: document.height)
      context.scaleBy(x: 1, y: -1)
      view.layer?.render(in: context)
      context.endPDFPage()
      context.closePDF()
      return data as Data
    }
    guard
      let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(document.width * 2),
        pixelsHigh: Int(document.height * 2), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
        isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
      let context = NSGraphicsContext(bitmapImageRep: rep)
    else { throw ProviderError.message("Could not allocate image export.") }
    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    NSGraphicsContext.current = context
    context.cgContext.translateBy(x: 0, y: document.height * 2)
    context.cgContext.scaleBy(x: 2, y: -2)
    view.layer?.render(in: context.cgContext)
    guard let data = rep.representation(using: .png, properties: [:]) else {
      throw ProviderError.message("Could not encode image export.")
    }
    return data
  }
  static func chooseExport(document: SceneDocument, time: Double, pdf: Bool) throws {
    let panel = NSSavePanel()
    panel.allowedContentTypes = [pdf ? .pdf : .png]
    panel.nameFieldStringValue = document.title + (pdf ? ".pdf" : ".png")
    guard panel.runModal() == .OK, let url = panel.url else { return }
    try render(document, time: time, pdf: pdf).write(to: url, options: .atomic)
  }
}
