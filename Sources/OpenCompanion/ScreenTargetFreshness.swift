import CoreGraphics
import Foundation
import ImageIO

/// A late model response may use a new capture only after local visual checks.
/// This does not mutate the old evidence or extend its admission timestamp.
enum ScreenTargetFreshness {
  private static let maximumImageBytes = 12_000_000
  // Production captures currently cap the long side at 1440. Leave room for
  // rounding while bounding decode memory before any raster is allocated.
  private static let maximumDimension = 2_048

  static func verified(
    target: ProviderTarget, original: ScreenEvidence, refreshed: ScreenEvidence
  ) async throws -> ProviderTarget {
    try Task.checkCancellation()
    let verification = Task.detached(priority: .userInitiated) {
      try check(target: target, original: original, refreshed: refreshed)
    }
    return try await withTaskCancellationHandler {
      let result = try await verification.value
      try Task.checkCancellation()
      return result
    } onCancel: {
      verification.cancel()
    }
  }

  private static func check(
    target: ProviderTarget, original: ScreenEvidence, refreshed: ScreenEvidence
  ) throws -> ProviderTarget {
    try Task.checkCancellation()
    let now = ProcessInfo.processInfo.systemUptime
    let originalAge = now - original.capturedAt
    let refreshedAge = now - refreshed.capturedAt
    guard original.frameID != refreshed.frameID,
      original.foregroundPID == refreshed.foregroundPID,
      original.foregroundPID > 0,
      original.displayID == refreshed.displayID,
      original.windowID == refreshed.windowID,
      original.screenRect == refreshed.screenRect,
      validSourceRect(original.screenRect),
      originalAge.isFinite, originalAge >= 0, originalAge <= 90,
      refreshedAge.isFinite, refreshedAge >= 0, refreshedAge < 15,
      target.x.isFinite, target.y.isFinite,
      target.width.isFinite, target.height.isFinite,
      target.x >= 0, target.y >= 0, target.width > 0, target.height > 0,
      target.x + target.width <= 1, target.y + target.height <= 1
    else { throw failure() }

    let before = try decode(original)
    let after = try decode(refreshed)
    guard before.width == after.width, before.height == after.height else { throw failure() }
    try Task.checkCancellation()
    guard try similarImages(before, after, width: 256, height: 160, maximumChangedFraction: 0.01)
    else {
      throw failure()
    }

    // Expand in logical capture points before converting to encoded pixels.
    // CGImage crops, like provider targets, use the image's top-left pixel axis.
    let paddingX = 12 / original.screenRect.width
    let paddingY = 12 / original.screenRect.height
    let left = max(0, target.x - paddingX)
    let top = max(0, target.y - paddingY)
    let right = min(1, target.x + target.width + paddingX)
    let bottom = min(1, target.y + target.height + paddingY)
    let crop = CGRect(
      x: left * Double(before.width), y: top * Double(before.height),
      width: (right - left) * Double(before.width),
      height: (bottom - top) * Double(before.height)
    ).integral
    guard let beforeRegion = before.cropping(to: crop),
      let afterRegion = after.cropping(to: crop)
    else { throw failure() }
    guard
      try similarImages(
        beforeRegion, afterRegion, width: 96, height: 96, maximumChangedFraction: 0.005)
    else {
      throw failure()
    }
    try Task.checkCancellation()
    let finishedAt = ProcessInfo.processInfo.systemUptime
    guard finishedAt - refreshed.capturedAt < 15,
      finishedAt - original.capturedAt <= 90
    else { throw failure() }
    var verified = target
    // Old candidate IDs never acquire authority in a new capture. Only the
    // already resolved geometry survives successful visual verification.
    verified.candidateID = nil
    return verified
  }

  private static func decode(_ evidence: ScreenEvidence) throws -> CGImage {
    try Task.checkCancellation()
    guard !evidence.image.isEmpty, evidence.image.count <= maximumImageBytes,
      let source = CGImageSourceCreateWithData(
        evidence.image as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
      CGImageSourceGetCount(source) == 1,
      (CGImageSourceGetType(source) as String?) == "public.jpeg",
      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
      let width = properties[kCGImagePropertyPixelWidth] as? Int,
      let height = properties[kCGImagePropertyPixelHeight] as? Int,
      (1...maximumDimension).contains(width), (1...maximumDimension).contains(height),
      (properties[kCGImagePropertyOrientation] as? Int ?? 1) == 1,
      evidence.imageWidth == 0 || evidence.imageWidth == width,
      evidence.imageHeight == 0 || evidence.imageHeight == height,
      let image = CGImageSourceCreateImageAtIndex(
        source, 0, [kCGImageSourceShouldCache: false] as CFDictionary),
      image.width == width, image.height == height
    else { throw failure() }
    return image
  }

  private static func grayscale(_ image: CGImage, width: Int, height: Int) throws -> [UInt8] {
    try Task.checkCancellation()
    var bytes = [UInt8](repeating: 0, count: width * height)
    let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
      guard
        let context = CGContext(
          data: buffer.baseAddress, width: width, height: height,
          bitsPerComponent: 8, bytesPerRow: width,
          space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
      else { return false }
      context.interpolationQuality = .high
      context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
      return true
    }
    guard drawn else { throw failure() }
    try Task.checkCancellation()
    return bytes
  }

  private static func similar(
    _ lhs: [UInt8], _ rhs: [UInt8], maximumChangedFraction: Double,
    stride: Int = 1, channels: Int = 1
  ) throws -> Bool {
    guard !lhs.isEmpty, lhs.count == rhs.count else { return false }
    var absoluteDifference = 0
    var changed = 0
    let count = lhs.count / stride
    for pixel in 0..<count {
      let index = pixel * stride
      if index % 256 == 0 { try Task.checkCancellation() }
      var difference = 0
      for channel in 0..<channels {
        difference = max(difference, abs(Int(lhs[index + channel]) - Int(rhs[index + channel])))
      }
      absoluteDifference += difference
      if difference > 16 { changed += 1 }
    }
    return Double(absoluteDifference) / Double(count) <= 2
      && Double(changed) / Double(count) <= maximumChangedFraction
  }

  private static func similarImages(
    _ lhs: CGImage, _ rhs: CGImage, width: Int, height: Int, maximumChangedFraction: Double
  ) throws -> Bool {
    let grayBefore = try grayscale(lhs, width: width, height: height)
    let grayAfter = try grayscale(rhs, width: width, height: height)
    guard try similar(grayBefore, grayAfter, maximumChangedFraction: maximumChangedFraction) else {
      return false
    }
    // Preserve the grayscale checks and also reject equal-luminance hue changes
    // (for example, a colored status changing while its brightness is stable).
    let colorBefore = try colorSamples(lhs, width: width, height: height)
    let colorAfter = try colorSamples(rhs, width: width, height: height)
    return try similar(
      colorBefore, colorAfter, maximumChangedFraction: maximumChangedFraction,
      stride: 4, channels: 3)
  }

  private static func colorSamples(_ image: CGImage, width: Int, height: Int) throws -> [UInt8] {
    try Task.checkCancellation()
    var bytes = [UInt8](repeating: 0, count: width * height * 4)
    let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
      guard let space = CGColorSpace(name: CGColorSpace.sRGB),
        let context = CGContext(
          data: buffer.baseAddress, width: width, height: height,
          bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
      else { return false }
      context.interpolationQuality = .high
      context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
      return true
    }
    guard drawn else { throw failure() }
    try Task.checkCancellation()
    return bytes
  }

  private static func validSourceRect(_ rect: CGRect) -> Bool {
    rect.origin.x.isFinite && rect.origin.y.isFinite
      && rect.size.width.isFinite && rect.size.height.isFinite
      && rect.size.width > 0 && rect.size.height > 0
      && rect.size.width <= 100_000 && rect.size.height <= 100_000
      && rect.maxX.isFinite && rect.maxY.isFinite
  }

  private static func failure() -> ProviderError {
    .message(
      "The screen could not be verified unchanged while I was thinking. Ask for screen guidance again."
    )
  }
}
