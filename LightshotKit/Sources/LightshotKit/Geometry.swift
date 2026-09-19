import Foundation

// Pure value-type geometry, expressed in **image pixel coordinates**.
//
// The domain core deliberately does not import CoreGraphics: keeping our own
// `Point` / `Size` / `Rect` makes the module provably framework-free (the litmus
// test AGENTS.md calls out) and keeps every computation deterministic `Double`
// math with no platform dependency. The render layer maps these into CG space.

/// A point in image pixel coordinates. Origin is top-left; `y` grows downward.
public struct Point: Equatable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    /// Euclidean distance to another point.
    public func distance(to other: Point) -> Double {
        (self - other).length
    }

    static func - (lhs: Point, rhs: Point) -> Point {
        Point(x: lhs.x - rhs.x, y: lhs.y - rhs.y)
    }

    /// Vector length treating the point as a vector from the origin.
    var length: Double { (x * x + y * y).squareRoot() }
}

/// A size in image pixels.
public struct Size: Equatable, Sendable {
    public var width: Double
    public var height: Double

    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }
}

/// An axis-aligned rectangle in image pixel coordinates.
public struct Rect: Equatable, Sendable {
    public var origin: Point
    public var size: Size

    public init(origin: Point, size: Size) {
        self.origin = origin
        self.size = size
    }

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.init(origin: Point(x: x, y: y), size: Size(width: width, height: height))
    }

    public var minX: Double { min(origin.x, origin.x + size.width) }
    public var minY: Double { min(origin.y, origin.y + size.height) }
    public var maxX: Double { max(origin.x, origin.x + size.width) }
    public var maxY: Double { max(origin.y, origin.y + size.height) }
    public var midX: Double { (minX + maxX) / 2 }
    public var midY: Double { (minY + maxY) / 2 }
    public var width: Double { abs(size.width) }
    public var height: Double { abs(size.height) }
    public var center: Point { Point(x: midX, y: midY) }

    /// A copy with a non-negative size and its origin at the top-left corner.
    public var standardized: Rect {
        Rect(x: minX, y: minY, width: width, height: height)
    }

    /// Inclusive containment test against the standardized bounds.
    public func contains(_ point: Point) -> Bool {
        point.x >= minX && point.x <= maxX && point.y >= minY && point.y <= maxY
    }

    /// Grows (positive) or shrinks (negative) the rect on all sides.
    public func insetBy(dx: Double, dy: Double) -> Rect {
        Rect(x: minX + dx, y: minY + dy, width: width - 2 * dx, height: height - 2 * dy)
    }

    /// The overlapping region with another rect, or `nil` when they don't overlap.
    public func intersection(_ other: Rect) -> Rect? {
        let x0 = max(minX, other.minX)
        let y0 = max(minY, other.minY)
        let x1 = min(maxX, other.maxX)
        let y1 = min(maxY, other.maxY)
        guard x1 > x0, y1 > y0 else { return nil }
        return Rect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }
}

/// The eight resize handles on an element's bounding box.
public enum Handle: Equatable, Sendable, CaseIterable {
    case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left
}

/// Shortest distance from `point` to the line segment `a`–`b`.
///
/// Used by hit-testing for one-dimensional marks (lines, arrows, freehand
/// strokes) where bounding-box containment would be far too generous.
func distanceFromPoint(_ point: Point, toSegment a: Point, _ b: Point) -> Double {
    let dx = b.x - a.x
    let dy = b.y - a.y
    let lengthSquared = dx * dx + dy * dy
    guard lengthSquared > 0 else { return point.distance(to: a) }
    // Project `point` onto the segment, clamped to the [a, b] extent.
    let t = max(0, min(1, ((point.x - a.x) * dx + (point.y - a.y) * dy) / lengthSquared))
    let projection = Point(x: a.x + t * dx, y: a.y + t * dy)
    return point.distance(to: projection)
}
