import AppKit
import CompanionCore
import CoreText
import SceneKit
import Testing

@testable import OpenCompanion

struct SpatialLabelLayoutTests {
  private let bounds = CGRect(x: 0, y: 0, width: 620, height: 385)

  @Test func twelveCrowdedCalloutsRemainContainedAndDoNotOverlap() {
    let items = crowdedLabels()
    let result = SpatialLabelLayout.place(
      items, in: bounds, objectBounds: CGRect(x: 210, y: 85, width: 200, height: 210))
    #expect(result.frames.count == 12)
    #expect(result.overlappingPairs == 0)
    for frame in result.frames.values { #expect(bounds.contains(frame)) }
    assertDisjoint(result.frames)
    let reordered = SpatialLabelLayout.place(
      Array(items.reversed()), in: bounds,
      objectBounds: CGRect(x: 210, y: 85, width: 200, height: 210))
    #expect(result.frames == reordered.frames)
    let repeated = SpatialLabelLayout.place(
      items, in: bounds, objectBounds: CGRect(x: 210, y: 85, width: 200, height: 210),
      previous: result.frames)
    #expect(result.frames == repeated.frames)
  }

  @Test func freePreferenceIsPreservedAndObjectCoverageIsAvoidedWhenSpaceAllows() throws {
    let item = SpatialLabelLayout.Item(
      id: "label", anchor: CGPoint(x: 310, y: 180),
      preferredOrigin: CGPoint(x: 340, y: 160), size: CGSize(width: 100, height: 24))
    let preferred = SpatialLabelLayout.place([item], in: bounds)
    #expect(preferred.frames["label"]?.origin == item.preferredOrigin)
    let object = CGRect(x: 290, y: 130, width: 180, height: 120)
    let avoided = SpatialLabelLayout.place([item], in: bounds, objectBounds: object)
    let frame = try #require(avoided.frames["label"])
    #expect(!frame.intersects(object))
    #expect(bounds.contains(frame))
    #expect(SpatialLabelLayout.closestPoint(item.anchor, on: frame) != item.anchor)
  }

  @Test func documentScaleAndNegativeOriginsDoNotHideValidLabels() {
    let scale = CGFloat(200)
    let offset = CGPoint(x: -30_000, y: -60_000)
    let input = crowdedLabels().map {
      SpatialLabelLayout.Item(
        id: $0.id,
        anchor: CGPoint(x: $0.anchor.x * scale + offset.x, y: $0.anchor.y * scale + offset.y),
        preferredOrigin: CGPoint(
          x: $0.preferredOrigin.x * scale + offset.x,
          y: $0.preferredOrigin.y * scale + offset.y),
        size: CGSize(width: $0.size.width * scale, height: $0.size.height * scale))
    }
    let large = CGRect(origin: offset, size: CGSize(width: 620 * scale, height: 385 * scale))
    let result = SpatialLabelLayout.place(input, in: large, gap: 6 * scale)
    #expect(result.frames.count == 12 && result.overlappingPairs == 0)
    for frame in result.frames.values { #expect(large.contains(frame)) }
    assertDisjoint(result.frames)
  }

  @Test func impossibleDensityIsReportedAndMalformedInputsAreBounded() {
    let small = CGRect(x: 0, y: 0, width: 120, height: 100)
    let dense = (0..<3).map {
      SpatialLabelLayout.Item(
        id: "dense-\($0)", anchor: CGPoint(x: 60, y: 50), preferredOrigin: .zero,
        size: CGSize(width: 100, height: 80))
    }
    let result = SpatialLabelLayout.place(dense, in: small)
    #expect(result.frames.count == 3 && result.overlappingPairs > 0)
    for frame in result.frames.values { #expect(small.contains(frame)) }
    let good = SpatialLabelLayout.Item(
      id: "safe", anchor: .zero, preferredOrigin: .zero, size: CGSize(width: 40, height: 20))
    let malformedPrevious = CGRect(x: CGFloat.nan, y: 0, width: 40, height: 20)
    let safe = SpatialLabelLayout.place([good], in: bounds, previous: ["safe": malformedPrevious])
    #expect(safe.frames["safe"] == CGRect(x: 0, y: 0, width: 40, height: 20))
    let invalid = SpatialLabelLayout.Item(
      id: "invalid", anchor: .zero, preferredOrigin: .zero,
      size: CGSize(width: CGFloat.infinity, height: 20))
    #expect(SpatialLabelLayout.place([invalid], in: bounds).frames.isEmpty)
    #expect(SpatialLabelLayout.place([good], in: bounds, gap: .infinity).frames.isEmpty)
    let capped = Array(repeating: invalid, count: 128) + [good]
    #expect(SpatialLabelLayout.place(capped, in: bounds).frames.isEmpty)
  }

  private func crowdedLabels() -> [SpatialLabelLayout.Item] {
    (0..<12).map {
      .init(
        id: String(format: "label-%02d", $0),
        anchor: CGPoint(x: 300 + $0, y: 175 + $0),
        preferredOrigin: CGPoint(x: 340, y: 170), size: CGSize(width: 110, height: 24))
    }
  }

  private func assertDisjoint(_ frames: [String: CGRect]) {
    let ids = frames.keys.sorted()
    for index in ids.indices {
      for other in ids.indices where other > index {
        if let first = frames[ids[index]], let second = frames[ids[other]] {
          #expect(!first.intersects(second))
        }
      }
    }
  }
}

@Suite @MainActor struct SpatialLabelLayoutNativeTests {
  @Test func intrinsicWordsDoNotOrphanTheirFinalLetterAtModelPreferredWidths() throws {
    for presentation in [CanvasPresentation.editor, .passiveOverlay] {
      let view = RetainedCanvasView(
        frame: CGRect(x: 0, y: 0, width: 620, height: 420), motionPolicy: .fullMotion)
      view.presentation = presentation
      let body = SceneNode(
        id: "body", kind: .mesh, spatial3D: .init(geometry: .cylinder(radius: 0.5, height: 1.2)))
      let words = ["Commutator", "Electromagnetic", "👩🏽‍🚀Assembly"]
      let labels = words.enumerated().map { index, word in
        SceneNode(
          id: "word-\(index)", kind: .text, width: 120, text: word, color: "#FFFFFF", fontSize: 17,
          spatial3D: .init(labelAnchor: .init(targetID: "body")))
      }
      view.render(
        try SceneDocument(id: "intrinsic-words", width: 900, height: 560, nodes: [body] + labels)
          .validated(), time: 0, selectedID: nil)
      if presentation == .passiveOverlay { view.advanceSpatialLabels(by: 0, reduceMotion: true) }
      let layers = (view.layer?.sublayers ?? []).flatMap { $0.sublayers ?? [] }
        .compactMap { $0 as? CATextLayer }
      for word in words {
        let layer = try #require(layers.first { $0.string as? String == word })
        let font = try #require(layer.font as? NSFont)
        let attributed = NSAttributedString(string: word, attributes: [.font: font])
        let line = CTLineCreateWithAttributedString(attributed)
        var ascent = CGFloat.zero
        var descent = CGFloat.zero
        var leading = CGFloat.zero
        let intrinsic = CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
        let typesetter = CTTypesetterCreateWithAttributedString(attributed)
        #expect(layer.bounds.width >= intrinsic)
        #expect(CTTypesetterSuggestLineBreak(typesetter, 0, layer.bounds.width) == word.utf16.count)
        #expect(layer.bounds.height < 2 * (ascent + descent + leading))
        #expect(
          font.fontName == NSFont.systemFont(ofSize: font.pointSize, weight: .medium).fontName)
      }
      #expect(view.projectedLabelFrames.count == 3 && view.unresolvedLabelOverlapCount == 0)
    }
  }

  @Test func diagnosticSnapshotUsesBoundedBackingResolution() throws {
    let view = RetainedCanvasView(
      frame: CGRect(x: 0, y: 0, width: 620, height: 420), motionPolicy: .fullMotion)
    view.presentation = .passiveOverlay
    let bitmap = try view.explanationSnapshot()
    #expect(bitmap.pixelsWide == 1240 && bitmap.pixelsHigh == 840)
    #expect(bitmap.size == view.bounds.size)
    view.frame.size = CGSize(width: 4096, height: 4096)
    do {
      _ = try view.explanationSnapshot()
      Issue.record("An oversized backing bitmap bypassed the8M pixel budget.")
    } catch {}
  }

  @Test func nativeCalloutsUseTightCanonicalBoundsAndPreserveAnchorsDuringPacing() throws {
    let view = RetainedCanvasView(
      frame: CGRect(x: 0, y: 0, width: 620, height: 420), motionPolicy: .fullMotion)
    view.presentation = .passiveOverlay
    let document = try fixture().validated()
    view.render(document, time: 0, selectedID: nil, presentationGeneration: 1)
    let frames = view.projectedLabelFrames
    #expect(frames.count == 12 && view.unresolvedLabelOverlapCount == 0)
    assertFrames(frames, canvas: view, document: document)
    for id in frames.keys {
      let native = view.canvasFrame(forDocumentRect: try #require(frames[id]))
      #expect(native.width < 150)  // Short labels do not reserve a260pt column.
      #expect(view.projectedLeaderPath(id: id) != nil)
      #expect(view.projectedLabelText(id: id) == "")
    }
    view.advanceSpatialLabels(by: 0.01)
    #expect(view.projectedLabelFrames == frames)
    #expect(view.projectedLabelText(id: "label-00") == "Assembly")
    view.advanceSpatialLabels(by: 0, reduceMotion: true)
    #expect(view.projectedLabelFrames == frames)
    #expect(view.projectedLabelText(id: "label-00") == "Assembly coil00")
    view.render(document, time: 0, selectedID: nil, presentationGeneration: 1)
    #expect(view.projectedLabelFrames == frames)
  }

  @Test func largeValidDocumentKeepsVisibleCalloutsAndOrbitReprojectsCollisionFree() throws {
    var document = fixture()
    document.width = 100_000
    document.height = 68_000
    let view = RetainedCanvasView(
      frame: CGRect(x: 0, y: 0, width: 620, height: 420), motionPolicy: .fullMotion)
    view.render(try document.validated(), time: 0, selectedID: nil)
    #expect(view.projectedLabelFrames.count == 12 && view.unresolvedLabelOverlapCount == 0)
    assertFrames(view.projectedLabelFrames, canvas: view, document: document)
    let before = try #require(view.projectedLeaderPath(id: "label-00"))
    let camera = try #require(view.spatialStage?.pointOfView)
    camera.position.x += 0.4
    camera.look(at: .init(0, 0, 0))
    view.updateCameraProjection()
    let after = try #require(view.projectedLeaderPath(id: "label-00"))
    #expect(before.boundingBoxOfPath != after.boundingBoxOfPath)
    #expect(view.projectedLabelFrames.count == 12 && view.unresolvedLabelOverlapCount == 0)
    assertFrames(view.projectedLabelFrames, canvas: view, document: document)
  }

  private func assertFrames(
    _ frames: [String: CGRect], canvas: RetainedCanvasView, document: SceneDocument
  ) {
    let bounds = CGRect(x: 0, y: 0, width: document.width, height: document.height)
    let ids = frames.keys.sorted()
    for (index, id) in ids.enumerated() {
      if let frame = frames[id] {
        #expect(bounds.contains(frame))
        for other in ids.dropFirst(index + 1) {
          if let second = frames[other] { #expect(!frame.intersects(second)) }
        }
      }
    }
  }

  private func fixture() -> SceneDocument {
    let body = SceneNode(
      id: "rotor", kind: .mesh, color: "#EEAA33",
      spatial3D: .init(geometry: .cylinder(radius: 0.7, height: 1.5)))
    let labels = (0..<12).map { index in
      SceneNode(
        id: String(format: "label-%02d", index), kind: .text,
        text: String(format: "Assembly coil%02d", index), color: "#FFFFFF", fontSize: 18,
        spatial3D: .init(
          labelAnchor: .init(
            targetID: "rotor", point: .init(x: Double(index) * 0.015, y: 0.1, z: 0.2),
            screenOffset: .init(x: 20, y: -20))))
    }
    return SceneDocument(
      id: "crowded-native-labels", width: 900, height: 560, nodes: [body] + labels)
  }
}
