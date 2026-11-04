import CoreGraphics
import Foundation
import ImageIO

/// Read only the bounded encoded image header. Pixel geometry never relies on
/// model-supplied dimensions, display scale, or an allocated decoded bitmap.
enum ScreenImageGeometry {
  static let maximumDimension: CGFloat = 16_384
  static let maximumImageBytes = 12_000_000

  static func trustedEncodedPixelSize(_ data: Data) throws -> CGSize {
    guard !data.isEmpty, data.count <= maximumImageBytes,
      let source = CGImageSourceCreateWithData(
        data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
      CGImageSourceGetCount(source) == 1,
      (CGImageSourceGetType(source) as String?) == "public.jpeg",
      CGImageSourceGetStatus(source) == .statusComplete,
      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
      let width = properties[kCGImagePropertyPixelWidth] as? Int,
      let height = properties[kCGImagePropertyPixelHeight] as? Int,
      width > 0, height > 0,
      width <= Int(maximumDimension), height <= Int(maximumDimension),
      (properties[kCGImagePropertyOrientation] as? Int ?? 1) == 1
    else {
      throw ProviderError.message(
        "The captured JPEG dimensions could not be verified. Capture again before requesting guidance."
      )
    }
    return CGSize(width: width, height: height)
  }
}

extension ScreenEvidence {
  /// Existing normalized and candidate-ID targets do not inspect image data.
  /// Pixel targets must use this capture's real encoded dimensions and metadata.
  func resolvingTarget(_ payload: ProviderTarget) throws -> ProviderTarget {
    let size: CGSize?
    if payload.pixelBounds != nil {
      let encoded = try ScreenImageGeometry.trustedEncodedPixelSize(image)
      guard imageWidth == 0 || imageWidth == Int(encoded.width),
        imageHeight == 0 || imageHeight == Int(encoded.height)
      else {
        throw ProviderError.message(
          "The captured image metadata changed. Capture again before requesting guidance.")
      }
      size = encoded
    } else {
      size = nil
    }
    return try ScreenGrounding.resolve(
      payload, candidates: groundingCandidates, frameID: frameID, imagePixelSize: size)
  }
}
