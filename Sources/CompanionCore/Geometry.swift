import Foundation

public struct Point2D: Codable, Hashable, Sendable {
    public var x: Double
    public var y: Double
    public init(x: Double, y: Double) { self.x = x; self.y = y }
    public var isFinite: Bool { x.isFinite && y.isFinite }
}

public struct Size2D: Codable, Hashable, Sendable {
    public var width: Double
    public var height: Double
    public init(width: Double, height: Double) { self.width = width; self.height = height }
}

public struct Rect2D: Codable, Hashable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
    public var center: Point2D { Point2D(x: x + width / 2, y: y + height / 2) }
    public var isFinite: Bool { [x, y, width, height].allSatisfy(\.isFinite) && width >= 0 && height >= 0 }
    public func contains(_ point: Point2D) -> Bool {
        point.x >= x && point.x <= x + width && point.y >= y && point.y <= y + height
    }
}

/// Column-vector affine transform: x' = a*x + c*y + tx; y' = b*x + d*y + ty.
public struct AffineTransform2D: Codable, Equatable, Sendable {
    public var a, b, c, d, tx, ty: Double
    public init(a: Double = 1, b: Double = 0, c: Double = 0, d: Double = 1, tx: Double = 0, ty: Double = 0) {
        self.a = a; self.b = b; self.c = c; self.d = d; self.tx = tx; self.ty = ty
    }
    public static let identity = AffineTransform2D()
    public var isFinite: Bool { [a, b, c, d, tx, ty].allSatisfy(\.isFinite) }
    public func applying(to point: Point2D) -> Point2D {
        Point2D(x: a * point.x + c * point.y + tx, y: b * point.x + d * point.y + ty)
    }
    /// Applies this transform followed by `next`.
    public func concatenating(_ next: Self) -> Self {
        Self(a: next.a * a + next.c * b, b: next.b * a + next.d * b,
             c: next.a * c + next.c * d, d: next.b * c + next.d * d,
             tx: next.a * tx + next.c * ty + next.tx, ty: next.b * tx + next.d * ty + next.ty)
    }
    public func inverted() throws -> Self {
        let determinant = a * d - b * c
        guard isFinite, determinant.isFinite, abs(determinant) > 1e-12 else { throw CoreError.invalidTransform }
        let result = Self(a: d / determinant, b: -b / determinant, c: -c / determinant, d: a / determinant,
                          tx: (c * ty - d * tx) / determinant, ty: (b * tx - a * ty) / determinant)
        guard result.isFinite else { throw CoreError.invalidTransform }
        return result
    }
    /// Maps an image's top-left pixels, including a crop/letterbox removal, to an AppKit display rectangle.
    public static func imageToAppKit(pixelSize: Size2D, display: Rect2D) throws -> Self {
        guard pixelSize.width.isFinite, pixelSize.height.isFinite, pixelSize.width > 0, pixelSize.height > 0,
              display.isFinite, display.width > 0, display.height > 0 else { throw CoreError.invalidTransform }
        return Self(a: display.width / pixelSize.width, d: -display.height / pixelSize.height,
                    tx: display.x, ty: display.y + display.height)
    }
}

public enum CoordinateSpace: String, Codable, Sendable {
    case imagePixels, imageNormalized, visionNormalized, accessibilityGlobal, appKitGlobal, overlayLocal
}

public struct LocatedPoint: Codable, Equatable, Sendable {
    public var point: Point2D
    public var space: CoordinateSpace
    public var transformID: String
    public init(point: Point2D, space: CoordinateSpace, transformID: String) {
        self.point = point; self.space = space; self.transformID = transformID
    }
}

public enum CoreError: Error, Equatable, Sendable, LocalizedError {
    case invalidDocument(String), invalidExpression(String), budgetExceeded(String), missingReference(String)
    case duplicateID(String), revisionConflict(expected: Int, received: Int), invalidTransform
    case invalidEvent(String), staleGeneration, staleEvidence, invalidTransition(String)
    public var errorDescription: String? {
        switch self {
        case .invalidDocument(let detail): return "Invalid scene: \(detail)"
        case .invalidExpression(let detail): return "Invalid expression: \(detail)"
        case .budgetExceeded(let detail): return "Resource limit exceeded: \(detail)"
        case .missingReference(let id): return "Missing reference: \(id)"
        case .duplicateID(let id): return "Duplicate identifier: \(id)"
        case .revisionConflict(let expected, let received): return "Document changed (current \(expected), patch base \(received))."
        case .invalidTransform: return "Coordinate transform is invalid or singular."
        case .invalidEvent(let detail): return "Invalid event: \(detail)"
        case .staleGeneration: return "This event belongs to an interrupted task."
        case .staleEvidence: return "The screen has changed. Capture it again before continuing."
        case .invalidTransition(let detail): return "Invalid state transition: \(detail)"
        }
    }
}
