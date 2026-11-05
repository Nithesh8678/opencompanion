import Foundation
import Testing

@testable import OpenCompanion

struct NativeCompositeGeometryComparisonTests {
  @Test func slenderOffGridGeometryGetsDistinctDistributedSamplesWithoutLoweringThresholds() {
    var native = Bitmap(width: 200, height: 200)
    native.fill(CGRect(x: 3, y: 1, width: 1, height: 198), color: ink)
    let grid = legacyGrid(native: native)
    #expect(grid.samples == 0)
    var selected: [Int] = []
    let result = compare(native: native, composite: native, grid: grid) { sample in
      selected.append(sample.nativeY * native.width + sample.nativeX)
    }
    #expect(result.method == .opaqueQuantiles)
    #expect(result.samples == 128 && result.matches == 128)
    #expect(passes(result))
    #expect(result.opaqueNativePixels == 198)
    #expect(Set(selected).count == 128)
    #expect((selected.first ?? 0) / native.width <= 3)
    #expect((selected.last ?? 0) / native.width >= 196)
    #expect(result.alphaPixelsVisited <= 2 * native.width * native.height)
  }

  @Test func displacedAndWrongColorGeometryCannotPassTheOriginalMatchFraction() {
    var native = Bitmap(width: 200, height: 200)
    native.fill(CGRect(x: 3, y: 1, width: 1, height: 198), color: ink)
    var displaced = Bitmap(width: 200, height: 200)
    displaced.fill(CGRect(x: 10, y: 1, width: 1, height: 198), color: ink)
    var wrongColor = Bitmap(width: 200, height: 200)
    wrongColor.fill(CGRect(x: 3, y: 1, width: 1, height: 198), color: [240, 20, 20, 255])
    for composite in [displaced, wrongColor] {
      let result = compare(native: native, composite: composite)
      #expect(result.samples == 128 && result.matches == 0)
      #expect(!passes(result))
    }
  }

  @Test func transparentNativeOrMissingCompositeDoesNotInventPassingEvidence() {
    let transparent = Bitmap(width: 200, height: 200)
    var native = transparent
    native.fill(CGRect(x: 3, y: 1, width: 1, height: 198), color: ink)
    let absentNative = compare(native: transparent, composite: native)
    #expect(absentNative.opaqueNativePixels == 0 && absentNative.samples == 0)
    #expect(!passes(absentNative))
    let absentComposite = compare(native: native, composite: transparent)
    #expect(absentComposite.samples == 128 && absentComposite.matches == 0)
    #expect(!passes(absentComposite))
  }

  @Test func fewerThanTwentyOpaquePixelsAreNeverDuplicatedToSatisfyTheMinimum() {
    var native = Bitmap(width: 100, height: 100)
    native.fill(CGRect(x: 3, y: 1, width: 1, height: 19), color: ink)
    let result = compare(native: native, composite: native)
    #expect(result.samples == 19 && result.matches == 19)
    #expect(result.selectedNativePixels == 19)
    #expect(!passes(result))
  }

  @Test func stageOffsetAndBackingScaleUseTheSamePixelCenterMapping() {
    var native = Bitmap(width: 80, height: 120)
    native.fill(CGRect(x: 3, y: 4, width: 1, height: 112), color: ink)
    var composite = Bitmap(width: 320, height: 360)
    for y in 4..<116 {
      composite.fill(CGRect(x: 46, y: CGFloat(30 + 2 * y), width: 2, height: 2), color: ink)
    }
    let frame = CGRect(x: 20, y: 15, width: 80, height: 120)
    let result = compare(
      native: native, composite: composite, stageFrame: frame,
      canvasSize: CGSize(width: 160, height: 180))
    #expect(result.samples == 112 && result.matches == 112 && passes(result))
    let misplaced = compare(
      native: native, composite: composite, stageFrame: frame.offsetBy(dx: 5, dy: 0),
      canvasSize: CGSize(width: 160, height: 180))
    #expect(misplaced.samples == 112 && misplaced.matches == 0 && !passes(misplaced))
  }

  @Test func sufficientlyPopulatedLegacyPassOrFailureIsPreservedWithoutFallbackWork() {
    for grid in [
      NativeCompositeGeometryComparison.Counts(samples: 20, matches: 20),
      .init(samples: 128, matches: 0),
    ] {
      var reads = 0
      let result = NativeCompositeGeometryComparison.compare(
        grid: grid, nativeWidth: 200, nativeHeight: 200,
        compositeWidth: 200, compositeHeight: 200,
        stageFrame: CGRect(x: 0, y: 0, width: 200, height: 200),
        canvasSize: CGSize(width: 200, height: 200),
        nativeAlpha: { _, _ in
          reads += 1
          return 255
        },
        colors: { _ in
          reads += 1
          return nil
        })
      #expect(result.method == .viewportGrid)
      #expect(result.samples == grid.samples && result.matches == grid.matches)
      #expect(reads == 0 && result.alphaPixelsVisited == 0)
    }
  }

  @Test func invalidDimensionsAndNonfiniteMappingNeverReadBitmapStorage() {
    for size in [CGSize(width: 8_193, height: 1), CGSize(width: 4_096, height: 4_096), .zero] {
      var reads = 0
      let result = NativeCompositeGeometryComparison.compare(
        grid: .init(samples: 0, matches: 0), nativeWidth: Int(size.width),
        nativeHeight: Int(size.height),
        compositeWidth: 100, compositeHeight: 100,
        stageFrame: CGRect(x: 0, y: 0, width: 100, height: 100),
        canvasSize: CGSize(width: 100, height: 100),
        nativeAlpha: { _, _ in
          reads += 1
          return 255
        }, colors: { _ in nil })
      #expect(result.samples == 0 && reads == 0)
    }
    var reads = 0
    let invalidFrame = NativeCompositeGeometryComparison.compare(
      grid: .init(samples: 0, matches: 0), nativeWidth: 100, nativeHeight: 100,
      compositeWidth: 100, compositeHeight: 100,
      stageFrame: CGRect(x: CGFloat.nan, y: 0, width: 100, height: 100),
      canvasSize: CGSize(width: 100, height: 100),
      nativeAlpha: { _, _ in
        reads += 1
        return 255
      }, colors: { _ in nil })
    #expect(invalidFrame.samples == 0 && reads == 0)
  }

  @Test func offCanvasMappingAndColorConversionFailureCannotPass() {
    var native = Bitmap(width: 100, height: 100)
    native.fill(CGRect(x: 3, y: 1, width: 1, height: 98), color: ink)
    let outside = compare(
      native: native, composite: native,
      stageFrame: CGRect(x: 200, y: 200, width: 100, height: 100))
    #expect(outside.samples == 0 && !passes(outside))
    let unavailableColors = NativeCompositeGeometryComparison.compare(
      grid: .init(samples: 0, matches: 0), nativeWidth: 100, nativeHeight: 100,
      compositeWidth: 100, compositeHeight: 100,
      stageFrame: CGRect(x: 0, y: 0, width: 100, height: 100),
      canvasSize: CGSize(width: 100, height: 100),
      nativeAlpha: { _, _ in 255 }, colors: { _ in nil })
    #expect(unavailableColors.samples == 128 && unavailableColors.matches == 0)
    #expect(!passes(unavailableColors))
  }

  @Test func partiallyOffCanvasStageCannotPassUsingOnlyItsMatchingSubset() {
    var reads = 0
    let color = NativeCompositeGeometryComparison.Color(red: 0.4, green: 0.5, blue: 0.6, alpha: 1)
    let result = NativeCompositeGeometryComparison.compare(
      grid: .init(samples: 0, matches: 0), nativeWidth: 100, nativeHeight: 100,
      compositeWidth: 100, compositeHeight: 100,
      stageFrame: CGRect(x: -20, y: 0, width: 100, height: 100),
      canvasSize: CGSize(width: 100, height: 100),
      nativeAlpha: { _, _ in
        reads += 1
        return 255
      }, colors: { _ in (color, color) })
    #expect(result.samples == 0 && result.matches == 0 && reads == 0)
    #expect(!passes(result))
  }

  private let ink: [UInt8] = [80, 120, 160, 255]

  private func passes(_ result: NativeCompositeGeometryComparison.Result) -> Bool {
    result.samples >= 20 && Double(result.matches) / Double(result.samples) >= 0.65
  }

  private func compare(
    native: Bitmap, composite: Bitmap,
    grid: NativeCompositeGeometryComparison.Counts = .init(samples: 0, matches: 0),
    stageFrame: CGRect? = nil, canvasSize: CGSize? = nil,
    selected: (NativeCompositeGeometryComparison.Sample) -> Void = { _ in }
  ) -> NativeCompositeGeometryComparison.Result {
    NativeCompositeGeometryComparison.compare(
      grid: grid, nativeWidth: native.width, nativeHeight: native.height,
      compositeWidth: composite.width, compositeHeight: composite.height,
      stageFrame: stageFrame
        ?? CGRect(
          x: 0, y: 0, width: CGFloat(native.width), height: CGFloat(native.height)),
      canvasSize: canvasSize
        ?? CGSize(
          width: CGFloat(composite.width), height: CGFloat(composite.height)),
      nativeAlpha: { x, y in native.bytes[(y * native.width + x) * 4 + 3] },
      colors: { sample in
        selected(sample)
        return (
          native.color(x: sample.nativeX, y: sample.nativeY),
          composite.color(x: sample.compositeX, y: sample.compositeY)
        )
      })
  }

  private func legacyGrid(native: Bitmap)
    -> NativeCompositeGeometryComparison.Counts
  {
    let step = max(1, Int(sqrt(Double(native.width * native.height) / 512)))
    var samples = 0
    for y in stride(from: 0, to: native.height, by: step) {
      for x in stride(from: 0, to: native.width, by: step) {
        if native.bytes[(y * native.width + x) * 4 + 3] >= 230 { samples += 1 }
      }
    }
    return .init(samples: samples, matches: samples)
  }

  private struct Bitmap {
    let width: Int
    let height: Int
    var bytes: [UInt8]

    init(width: Int, height: Int) {
      self.width = width
      self.height = height
      bytes = Array(repeating: 0, count: width * height * 4)
    }

    mutating func fill(_ rect: CGRect, color: [UInt8]) {
      for y in Int(rect.minY)..<Int(rect.maxY) {
        for x in Int(rect.minX)..<Int(rect.maxX) {
          for channel in 0..<4 { bytes[(y * width + x) * 4 + channel] = color[channel] }
        }
      }
    }

    func color(x: Int, y: Int) -> NativeCompositeGeometryComparison.Color {
      let index = (y * width + x) * 4
      return .init(
        red: Double(bytes[index]) / 255, green: Double(bytes[index + 1]) / 255,
        blue: Double(bytes[index + 2]) / 255, alpha: Double(bytes[index + 3]) / 255)
    }
  }
}
