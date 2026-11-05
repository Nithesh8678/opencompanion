import Foundation

/// Pure, bounded sampling over already-owned bitmap bytes. No image conversion,
/// renderer access or pixel storage is performed here.
enum NativeCompositeGeometryComparison {
  static let maximumPixels = 8_000_000
  static let maximumDimension = 8_192
  static let maximumSamples = 128

  struct Counts: Equatable, Sendable {
    let samples: Int
    let matches: Int
  }

  enum Method: String, Codable, Sendable { case viewportGrid, opaqueQuantiles }

  struct Result: Equatable, Sendable {
    let samples: Int
    let matches: Int
    let method: Method
    let gridSamples: Int
    let gridMatches: Int
    let opaqueNativePixels: Int?
    let alphaPixelsVisited: Int
    let selectedNativePixels: Int
  }

  struct Sample: Equatable, Sendable {
    let nativeX: Int
    let nativeY: Int
    let compositeX: Int
    let compositeY: Int
  }

  struct Color: Sendable {
    let red: Double
    let green: Double
    let blue: Double
    let alpha: Double
  }

  static func preservingGrid(_ grid: Counts) -> Result {
    .init(
      samples: grid.samples, matches: grid.matches, method: .viewportGrid,
      gridSamples: grid.samples, gridMatches: grid.matches, opaqueNativePixels: nil,
      alphaPixelsVisited: 0, selectedNativePixels: 0)
  }

  /// Keep a sufficiently populated legacy result exactly, including failures.
  /// Otherwise choose opaque-pixel rank midpoints, spread across the full raster
  /// rather than the first geometry encountered. Two passes use constant state;
  /// only the selected <=128 pairs need color conversion by the caller.
  /// This checks sampled consistency, not every pixel or every semantic part.
  static func compare(
    grid: Counts, nativeWidth: Int, nativeHeight: Int,
    compositeWidth: Int, compositeHeight: Int, stageFrame: CGRect, canvasSize: CGSize,
    nativeAlpha: (Int, Int) -> UInt8,
    colors: (Sample) -> (expected: Color, actual: Color)?
  ) -> Result {
    let original = preservingGrid(grid)
    guard grid.samples < 20 else { return original }
    guard validSize(width: nativeWidth, height: nativeHeight),
      validSize(width: compositeWidth, height: compositeHeight),
      stageFrame.origin.x.isFinite, stageFrame.origin.y.isFinite,
      stageFrame.size.width.isFinite, stageFrame.size.height.isFinite,
      stageFrame.maxX.isFinite, stageFrame.maxY.isFinite,
      stageFrame.size.width > 0, stageFrame.size.height > 0,
      canvasSize.width.isFinite, canvasSize.height.isFinite,
      canvasSize.width > 0, canvasSize.height > 0,
      stageFrame.minX >= 0, stageFrame.minY >= 0,
      stageFrame.maxX <= canvasSize.width, stageFrame.maxY <= canvasSize.height
    else { return original }
    var opaque = 0
    var visited = 0
    for y in 0..<nativeHeight {
      for x in 0..<nativeWidth {
        visited += 1
        // Exactly the original expected-alpha >0.9 threshold for RGBA8.
        if nativeAlpha(x, y) >= 230 { opaque += 1 }
      }
    }
    let selectedCount = min(maximumSamples, opaque)
    var samples = 0
    var matches = 0
    var selected = 0
    var ordinal = 0
    if selectedCount > 0 {
      var nextOrdinal = opaque / (2 * selectedCount)
      sampling: for y in 0..<nativeHeight {
        for x in 0..<nativeWidth {
          visited += 1
          guard nativeAlpha(x, y) >= 230 else { continue }
          defer { ordinal += 1 }
          guard ordinal == nextOrdinal else { continue }
          selected += 1
          let localX =
            stageFrame.minX
            + (Double(x) + 0.5) / Double(nativeWidth) * stageFrame.width
          let localY =
            stageFrame.minY
            + (Double(y) + 0.5) / Double(nativeHeight) * stageFrame.height
          let px = localX / canvasSize.width * Double(compositeWidth)
          let py = localY / canvasSize.height * Double(compositeHeight)
          if px.isFinite, py.isFinite, px >= 0, py >= 0,
            px < Double(compositeWidth), py < Double(compositeHeight)
          {
            let sample = Sample(
              nativeX: x, nativeY: y, compositeX: Int(px), compositeY: Int(py))
            samples += 1
            if let pair = colors(sample), matching(pair.expected, pair.actual) { matches += 1 }
          }
          if selected == selectedCount { break sampling }
          nextOrdinal = ((2 * selected + 1) * opaque) / (2 * selectedCount)
        }
      }
    }
    return .init(
      samples: samples, matches: matches, method: .opaqueQuantiles,
      gridSamples: grid.samples, gridMatches: grid.matches, opaqueNativePixels: opaque,
      alphaPixelsVisited: visited, selectedNativePixels: selected)
  }

  private static func validSize(width: Int, height: Int) -> Bool {
    width > 0 && height > 0 && width <= maximumDimension && height <= maximumDimension
      && width <= maximumPixels / height
  }

  private static func matching(_ expected: Color, _ actual: Color) -> Bool {
    expected.alpha > 0.9 && actual.alpha > 0.5
      && abs(actual.red - expected.red) < 0.18
      && abs(actual.green - expected.green) < 0.18
      && abs(actual.blue - expected.blue) < 0.18
  }
}
