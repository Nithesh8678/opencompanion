import AppKit
import CompanionCore
import QuartzCore
import Testing

@testable import OpenCompanion

@Suite @MainActor struct SpatialLabelGlyphCoverageTests {
  @Test func completeUtf16LayoutRejectsClippedHeightAndNarrowSingleLineBounds() throws {
    let text = "2 Caterpillar 👩🏽‍🚀"
    let font = NSFont.systemFont(ofSize: 18, weight: .medium)
    let full = try #require(
      SpatialLabelGlyphLayout.measure(
        text: text, font: font, bounds: CGRect(x: 0, y: 0, width: 300, height: 32)))
    #expect(full.isComplete && full.visibleUTF16Count == text.utf16.count)
    let clipped = try #require(
      SpatialLabelGlyphLayout.measure(
        text: text, font: font, bounds: CGRect(x: 0, y: 0, width: 300, height: 1)))
    #expect(!clipped.isComplete && clipped.visibleUTF16Count < text.utf16.count)
    let narrow = try #require(
      SpatialLabelGlyphLayout.measure(
        text: text, font: font, bounds: CGRect(x: 0, y: 0, width: 12, height: 24)))
    #expect(!narrow.isComplete && narrow.visibleUTF16Count < text.utf16.count)
  }

  @Test func actualRetainedLabelsUseTheirCurrentFontBoundsAndVisiblePrefix() throws {
    let view = RetainedCanvasView(
      frame: CGRect(x: 0, y: 0, width: 620, height: 386), motionPolicy: .fullMotion)
    view.presentation = .passiveOverlay
    view.overlayHeaderInset = 44
    let document = try SceneDocument(
      width: 900, height: 560,
      nodes: [
        .init(id: "body", kind: .mesh, spatial3D: .init(geometry: .sphere(radius: 0.5))),
        .init(
          id: "label", kind: .text, width: 140, height: 30, text: "2 Caterpillar",
          color: "#FFFFFF", spatial3D: .init(labelAnchor: .init(targetID: "body"))),
      ]
    ).validated()
    #expect(view.render(document, time: 0, selectedID: nil))
    #expect(view.projectedLabelGlyphLayout(id: "label") == nil)
    view.advanceSpatialLabels(by: 0, reduceMotion: true)
    let layout = try #require(view.projectedLabelGlyphLayout(id: "label"))
    #expect(layout.isComplete && layout.utf16Count == "2 Caterpillar".utf16.count)
    let label = try #require(
      (view.layer?.sublayers ?? []).flatMap { $0.sublayers ?? [] }
        .compactMap { $0 as? CATextLayer }.first { $0.string as? String == "2 Caterpillar" })
    let originalBounds = label.bounds
    label.bounds.size.height = 1
    #expect(view.projectedLabelGlyphLayout(id: "label")?.isComplete == false)
    label.bounds = originalBounds
    #expect(view.projectedLabelGlyphLayout(id: "label")?.isComplete == true)
    label.isHidden = true
    #expect(view.projectedLabelGlyphLayout(id: "label") == nil)
    #expect(view.projectedLabelGlyphLayout(id: "missing") == nil)
  }
}
