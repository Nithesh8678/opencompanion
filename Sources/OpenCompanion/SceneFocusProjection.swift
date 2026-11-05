import CoreGraphics
import Foundation

/// A renderer-owned surface projected into global AppKit logical points. The
/// floating host adds its own presentation lease and narration/beat identity.
struct SceneFocusProjection: Codable, Equatable, Sendable {
  let targetID: String
  let surfaceNodeID: String
  let documentID: String
  let documentRevision: Int
  let generation: UInt64
  let renderSerial: UInt64
  let globalPoint: CGPoint
}

enum SceneFocusCoordinates {
  /// The native canvas supplies its actual view-to-window affine transform and
  /// `window.convertPoint(toScreen: .zero)`. Backing pixels never enter this map.
  static func globalPoint(
    canvasPoint: CGPoint, canvasBounds: CGRect, canvasToWindow: CGAffineTransform,
    windowScreenOrigin: CGPoint, screenFrames: [CGRect]
  ) -> CGPoint? {
    guard finite(canvasPoint), finite(canvasBounds), canvasBounds.width > 0,
      canvasBounds.height > 0, canvasBounds.contains(canvasPoint),
      [
        canvasToWindow.a, canvasToWindow.b, canvasToWindow.c, canvasToWindow.d,
        canvasToWindow.tx, canvasToWindow.ty,
      ].allSatisfy(\.isFinite),
      finite(windowScreenOrigin)
    else { return nil }
    let determinant = canvasToWindow.a * canvasToWindow.d - canvasToWindow.b * canvasToWindow.c
    guard determinant.isFinite, abs(determinant) > 1e-12 else { return nil }
    let base = canvasPoint.applying(canvasToWindow)
    let point = CGPoint(x: base.x + windowScreenOrigin.x, y: base.y + windowScreenOrigin.y)
    guard finite(point),
      screenFrames.prefix(32).contains(where: {
        finite($0) && $0.width > 0 && $0.height > 0 && $0.contains(point)
      })
    else { return nil }
    return point
  }

  private static func finite(_ point: CGPoint) -> Bool { point.x.isFinite && point.y.isFinite }
  private static func finite(_ rect: CGRect) -> Bool {
    finite(rect.origin) && rect.width.isFinite && rect.height.isFinite
      && rect.maxX.isFinite && rect.maxY.isFinite
  }
}
