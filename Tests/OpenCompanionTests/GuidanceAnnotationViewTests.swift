import AppKit
import QuartzCore
import Testing

@testable import OpenCompanion

struct GuidanceAnnotationViewTests {
  @Test func annotationOracleUsesTopBitmapRowsWithoutMirroringItsCrop() throws {
    // This independently authored RGBA bitmap bypasses CALayer.render and the
    // production raster transform. It fixes the pixel-row convention directly.
    let width = 160
    let height = 140
    var bytes = [UInt8](repeating: 0, count: width * height * 4)
    func red(_ x: Int, _ y: Int) {
      let offset = (y * width + x) * 4
      bytes[offset] = 255
      bytes[offset + 1] = 40
      bytes[offset + 2] = 50
      bytes[offset + 3] = 255
    }
    for x in 38...81 {
      for y in 74...76 { red(x, y) }
      for y in 94...96 { red(x, y) }
    }
    for y in 81...89 {
      for x in 19...21 { red(x, y) }
      for x in 99...101 { red(x, y) }
    }
    let provider = try #require(CGDataProvider(data: Data(bytes) as CFData))
    let image = try #require(
      CGImage(
        width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
        bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGBitmapInfo.byteOrder32Big.union(
          CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)),
        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    let raster = GuidanceMarkRaster(
      image: image, localBounds: CGRect(x: 0, y: 0, width: width, height: height), scale: 1)
    let target = CGRect(x: 20, y: 75, width: 80, height: 20)
    let actual = try ManualGuidanceLiveAcceptance.annotationRasterMetrics(
      raster, expectedTarget: target, shape: "roundedRectangle")
    #expect(actual.verified && actual.sidePixels.allSatisfy { $0 > 0 })
    let mirrored = try ManualGuidanceLiveAcceptance.annotationRasterMetrics(
      raster, expectedTarget: CGRect(x: 20, y: 45, width: 80, height: 20),
      shape: "roundedRectangle")
    #expect(!mirrored.verified)
  }

  @MainActor
  @Test(arguments: [
    GuidanceAnnotationView.Shape.roundedRectangle, GuidanceAnnotationView.Shape.ellipse,
  ])
  func retainedOwnMarkRasterProvesAnAsymmetricGroundedContour(
    _ shape: GuidanceAnnotationView.Shape
  ) throws {
    // Asymmetric location plus the label above the target catches an inverted
    // view-to-bitmap transform; outline evidence must cover every target side.
    let target = CGRect(x: 123, y: 151, width: 220, height: 38)
    let view = GuidanceAnnotationView(
      frame: CGRect(x: 0, y: 0, width: 800, height: 600), target: target,
      shape: shape, text: "Public field", reduceMotion: true)
    let raster = try GuidanceMarkRaster.render(view: view)
    let metrics = try ManualGuidanceLiveAcceptance.annotationRasterMetrics(
      raster, expectedTarget: target, shape: shape.rawValue)
    #expect(metrics.verified)
    #expect(metrics.sidePixels.count == 4 && metrics.sidePixels.allSatisfy { $0 > 0 })
    #expect(raster.image.width * raster.image.height <= 2_000_000)
    let shifted = try ManualGuidanceLiveAcceptance.annotationRasterMetrics(
      raster, expectedTarget: target.offsetBy(dx: 0, dy: 10), shape: shape.rawValue)
    #expect(!shifted.verified)
  }

  @MainActor @Test func labelPixelsCannotSubstituteForAnAbsentNativeOutline() throws {
    let target = CGRect(x: 123, y: 151, width: 220, height: 38)
    let view = GuidanceAnnotationView(
      frame: CGRect(x: 0, y: 0, width: 800, height: 600), target: target,
      shape: .roundedRectangle, text: "Public field", reduceMotion: true)
    for layer in view.layer?.sublayers ?? [] where layer is CAShapeLayer { layer.isHidden = true }
    let raster = try GuidanceMarkRaster.render(view: view)
    let metrics = try ManualGuidanceLiveAcceptance.annotationRasterMetrics(
      raster, expectedTarget: target, shape: "roundedRectangle")
    #expect(!metrics.verified && metrics.opaqueOutlinePixels == 0)
    let context = try #require(
      CGContext(
        data: nil, width: raster.image.width, height: raster.image.height,
        bitsPerComponent: 8, bytesPerRow: raster.image.width * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue
          | CGImageAlphaInfo.premultipliedLast.rawValue))
    let blank = GuidanceMarkRaster(
      image: try #require(context.makeImage()), localBounds: raster.localBounds, scale: raster.scale
    )
    let absent = try ManualGuidanceLiveAcceptance.annotationRasterMetrics(
      blank, expectedTarget: target, shape: "roundedRectangle")
    #expect(!absent.verified && absent.sidePixels.allSatisfy { $0 == 0 })
  }

  @MainActor @Test func retainedMarkRasterRefusesUnboundedAllocationAndUnsupportedShape() throws {
    let oversized = GuidanceAnnotationView(
      frame: CGRect(x: 0, y: 0, width: 10_000, height: 10_000),
      target: CGRect(x: 0, y: 0, width: 10_000, height: 10_000), shape: .ellipse,
      text: "", reduceMotion: true)
    #expect(throws: ProviderError.self) { try GuidanceMarkRaster.render(view: oversized) }
    let target = CGRect(x: 20, y: 30, width: 40, height: 30)
    let view = GuidanceAnnotationView(
      frame: CGRect(x: 0, y: 0, width: 200, height: 200), target: target,
      shape: .ellipse, text: "", reduceMotion: true)
    let raster = try GuidanceMarkRaster.render(view: view)
    #expect(throws: ProviderError.self) {
      try ManualGuidanceLiveAcceptance.annotationRasterMetrics(
        raster, expectedTarget: target, shape: "unsupported")
    }
  }

  @Test func labelClampsAtDisplayEdgesAndFallsBelowTopTarget() {
    let canvas = CGRect(x: 0, y: 0, width: 800, height: 600)
    let top = GuidanceAnnotationLayout.make(
      target: CGRect(x: 12, y: 2, width: 200, height: 30),
      labelSize: CGSize(width: 110, height: 26), canvas: canvas)
    #expect(top.label.minY == top.target.maxY + 5)
    #expect(canvas.contains(top.label))
    let right = GuidanceAnnotationLayout.make(
      target: CGRect(x: 790, y: 580, width: 100, height: 100),
      labelSize: CGSize(width: 900, height: 26), canvas: canvas)
    #expect(right.target == CGRect(x: 790, y: 580, width: 10, height: 20))
    #expect(right.label.width == 320)
    #expect(right.label.maxX == canvas.maxX - 6)
    #expect(right.label.maxY <= right.target.minY)
    #expect(canvas.contains(right.label))
  }

  @Test func layoutPreservesNegativeCoordinateOriginsAndRejectsNonfiniteInputs() {
    let canvas = CGRect(x: -900, y: -300, width: 800, height: 600)
    let layout = GuidanceAnnotationLayout.make(
      target: CGRect(x: -850, y: -200, width: 300, height: 30),
      labelSize: CGSize(width: 130, height: 26), canvas: canvas)
    #expect(layout.label.minX == -850)
    #expect(layout.label.maxY == layout.target.minY - 5)
    #expect(canvas.contains(layout.label))
    let invalid = GuidanceAnnotationLayout.make(
      target: CGRect(x: CGFloat.nan, y: 20, width: 30, height: 30),
      labelSize: CGSize(width: 30, height: 20), canvas: canvas)
    #expect(invalid.target == .zero)
    #expect(invalid.label == .zero)
    let unlabeled = GuidanceAnnotationLayout.make(
      target: layout.target, labelSize: .zero, canvas: canvas)
    #expect(unlabeled.target == layout.target)
    #expect(unlabeled.label == .zero)
  }

  @MainActor @Test func nativeLabelUsesOneBoundedGraphemeMaskAndFinalModelGeometry() throws {
    let text = "Ta👩🏽‍💻e\u{301}"
    let view = GuidanceAnnotationView(
      frame: CGRect(x: 0, y: 0, width: 800, height: 600),
      target: CGRect(x: 120, y: 120, width: 240, height: 40),
      shape: .roundedRectangle, text: text, reduceMotion: false)
    view.animateAppearance()
    let layers = try #require(view.layer?.sublayers)
    let outline = try #require(layers.first { $0.name == "guidance.outline" } as? CAShapeLayer)
    #expect(outline.lineDashPattern == [6, 4])
    #expect(outline.strokeEnd == 1)
    #expect(outline.animation(forKey: "guidance.draw")?.duration == 0.35)
    let pill = try #require(layers.first { $0.name == "guidance.label" })
    let label = try #require(pill.sublayers?.first as? CATextLayer)
    let mask = try #require(label.mask)
    let reveal = try #require(
      mask.animation(forKey: "guidance.labelReveal") as? CAKeyframeAnimation)
    #expect(reveal.calculationMode == .discrete)
    #expect(reveal.values?.count == text.count + 1)
    #expect(abs(reveal.duration - 0.06 * Double(text.count)) < 0.000_001)
    #expect(reveal.fillMode == .backwards)
    #expect(mask.bounds.width == label.bounds.width)
    #expect((label.string as? NSAttributedString)?.string == text)
    #expect(view.hitTest(CGPoint(x: 130, y: 130)) == nil)
  }

  @MainActor @Test func cursorLabelFrameUsesExactLocalNativePlacementAcrossDisplays() {
    let display = CGRect(x: -1512, y: 120, width: 1512, height: 982)
    let target = ProviderTarget(
      x: 0.2, y: 0.4, width: 0.3, height: 0.05, instruction: "Long fallback instruction",
      label: "Table name", shape: "roundedRectangle")
    let text = GuidanceAnnotationLayout.labelText(target: target, showInstruction: false)
    #expect(text == "Table name")
    let local = GuidanceAnnotationLayout.make(
      target: CGRect(
        x: target.x * display.width, y: target.y * display.height,
        width: target.width * display.width, height: target.height * display.height),
      labelSize: GuidanceAnnotationLayout.labelSize(text: text),
      canvas: CGRect(origin: .zero, size: display.size))
    let global = GuidanceAnnotationLayout.labelFrame(
      target: target, display: display, showInstruction: false)
    #expect(global.minX == display.minX + local.label.minX)
    #expect(global.maxY == display.maxY - local.label.minY)
    #expect(global.size == local.label.size)
    var withoutLabel = target
    withoutLabel.label = nil
    #expect(
      GuidanceAnnotationLayout.labelText(target: withoutLabel, showInstruction: false).isEmpty)
    #expect(GuidanceAnnotationLayout.labelPrefixWidths(text: "👩🏽‍💻e\u{301}").count == 3)
  }

  @MainActor @Test func ellipseHasContinuousOutlineAndReducedMotionHasNoEntranceAnimations() throws
  {
    let target = CGRect(x: 100, y: 100, width: 250, height: 70)
    let view = GuidanceAnnotationView(
      frame: CGRect(x: 0, y: 0, width: 800, height: 600),
      target: target, shape: .ellipse, text: String(repeating: "🧑🏽‍🚀", count: 120),
      reduceMotion: true)
    view.animateAppearance()
    let layers = try #require(view.layer?.sublayers)
    let outline = try #require(layers.first { $0.name == "guidance.outline" } as? CAShapeLayer)
    #expect(outline.lineDashPattern == nil)
    #expect(outline.animationKeys() == nil)
    let path = try #require(outline.path)
    #expect(target.insetBy(dx: -1, dy: -1).contains(path.boundingBoxOfPath))
    let pill = try #require(layers.first { $0.name == "guidance.label" })
    let label = try #require(pill.sublayers?.first as? CATextLayer)
    #expect((label.string as? NSAttributedString)?.string.count == 80)
    #expect(label.mask?.animationKeys() == nil)
    #expect(pill.animationKeys() == nil)
  }
}
