import Foundation

/// Stable identity for an annotation element, handed back by `add` so callers
/// can address later commands (`transform`, `setStyle`, `delete`, …) at it.
public struct ElementID: Hashable, Sendable {
    public let raw: UUID
    public init(_ raw: UUID = UUID()) { self.raw = raw }
}

/// One annotation on the image: an identity, a geometric `Kind`, and a `Style`.
///
/// Geometry is stored in **image pixel coordinates** so it survives crop and
/// multi-scale export unchanged. Elements are held in an ordered array on the
/// document; later in the array means higher in the z-order (drawn on top).
public struct AnnotationElement: Identifiable, Equatable, Sendable {
    public let id: ElementID
    public var kind: Kind
    public var style: Style

    public init(id: ElementID = ElementID(), kind: Kind, style: Style = .default) {
        self.id = id
        self.kind = kind
        self.style = style
    }

    /// The geometric shape of an element. Each case carries its own geometry.
    public enum Kind: Equatable, Sendable {
        /// A pointer from a tail (`from`) to a tip (`to`). `bend` is the point the shaft
        /// passes through at its middle — only bendable styles (`ArrowStyle.isBendable`)
        /// carry one; `nil` means a straight shaft.
        case arrow(from: Point, to: Point, bend: Point? = nil, style: ArrowStyle = .standard)
        case line(from: Point, to: Point)
        case rectangle(Rect)
        case ellipse(Rect)
        case freehand(points: [Point])
        case text(String, box: Rect)
        case highlight(Rect)
        /// `strength` (`0...1`) sets how hard `blur`/`pixelate` obscure; `seed` fixes their
        /// randomization so the same element always flattens to the same pixels.
        case redaction(Rect, style: RedactionStyle,
                       strength: Double = RedactionStyle.defaultStrength, seed: UInt64 = 0)
        /// An auto-numbered step marker drawn as a circle of `radius` about `center`.
        /// The document assigns `number` on `add`; callers pass any placeholder.
        case stepMarker(number: Int, center: Point, radius: Double)
    }
}

extension AnnotationElement.Kind {
    /// The axis-aligned box enclosing the shape — the anchor for transforms and
    /// the coarse hit-test for area shapes.
    public var boundingBox: Rect {
        switch self {
        case let .arrow(from, to, bend, _):
            return Self.boundingBox(of: [from, to] + (bend.map { [$0] } ?? []))
        case let .line(from, to):
            return Self.boundingBox(of: [from, to])
        case let .rectangle(rect), let .ellipse(rect),
             let .highlight(rect), let .redaction(rect, _, _, _):
            return rect.standardized
        case let .text(_, box):
            return box.standardized
        case let .freehand(points):
            return Self.boundingBox(of: points)
        case let .stepMarker(_, center, radius):
            return Rect(x: center.x - radius, y: center.y - radius,
                        width: radius * 2, height: radius * 2)
        }
    }

    /// Where a selected line or arrow can be grabbed: its tail and tip, plus — for a bendable
    /// arrow — the bend on the middle of its shaft. `nil` for every other shape, which is
    /// resized by its bounding box instead.
    public var endpointHandles: [(handle: EndpointHandle, point: Point)]? {
        switch self {
        case let .line(from, to):
            return [(.tail, from), (.tip, to)]
        case let .arrow(from, to, bend, style):
            let ends: [(handle: EndpointHandle, point: Point)] = [(.tail, from), (.tip, to)]
            return style.isBendable ? ends + [(.bend, bend ?? arrowMidpoint(from, to))] : ends
        default:
            return nil
        }
    }

    /// Translates every stored coordinate by `(dx, dy)`.
    func moved(dx: Double, dy: Double) -> AnnotationElement.Kind {
        func shift(_ p: Point) -> Point { Point(x: p.x + dx, y: p.y + dy) }
        func shift(_ r: Rect) -> Rect { Rect(origin: shift(r.origin), size: r.size) }

        switch self {
        case let .arrow(from, to, bend, style):
            return .arrow(from: shift(from), to: shift(to), bend: bend.map(shift), style: style)
        case let .line(from, to): return .line(from: shift(from), to: shift(to))
        case let .rectangle(rect): return .rectangle(shift(rect))
        case let .ellipse(rect): return .ellipse(shift(rect))
        case let .highlight(rect): return .highlight(shift(rect))
        case let .redaction(rect, style, strength, seed):
            return .redaction(shift(rect), style: style, strength: strength, seed: seed)
        case let .text(string, box): return .text(string, box: shift(box))
        case let .freehand(points): return .freehand(points: points.map(shift))
        case let .stepMarker(number, center, radius):
            return .stepMarker(number: number, center: shift(center), radius: radius)
        }
    }

    /// Resizes the shape by dragging bounding-box `handle` by `(dx, dy)`, keeping the
    /// box→geometry remap on the element rather than at the call site.
    func resized(handle: Handle, dx: Double, dy: Double) -> AnnotationElement.Kind {
        let old = boundingBox
        return resized(from: old, to: old.resized(handle: handle, dx: dx, dy: dy))
    }

    /// Remaps the shape from its old bounding box into `new`, preserving the
    /// shape's nature: point/rect shapes scale proportionally, a step marker
    /// stays a circle (centered in `new`, radius from its shorter side).
    func resized(from old: Rect, to new: Rect) -> AnnotationElement.Kind {
        func remap(_ p: Point) -> Point { Self.remap(p, from: old, to: new) }
        func remap(_ r: Rect) -> Rect {
            let a = remap(r.origin)
            let b = remap(Point(x: r.origin.x + r.size.width, y: r.origin.y + r.size.height))
            return Rect(x: a.x, y: a.y, width: b.x - a.x, height: b.y - a.y)
        }

        switch self {
        case let .arrow(from, to, bend, style):
            return .arrow(from: remap(from), to: remap(to), bend: bend.map(remap), style: style)
        case let .line(from, to): return .line(from: remap(from), to: remap(to))
        case let .rectangle(rect): return .rectangle(remap(rect))
        case let .ellipse(rect): return .ellipse(remap(rect))
        case let .highlight(rect): return .highlight(remap(rect))
        case let .redaction(rect, style, strength, seed):
            return .redaction(remap(rect), style: style, strength: strength, seed: seed)
        case let .text(string, box): return .text(string, box: remap(box))
        case let .freehand(points): return .freehand(points: points.map(remap))
        case let .stepMarker(number, _, _):
            return .stepMarker(number: number, center: new.center,
                               radius: min(new.width, new.height) / 2)
        }
    }

    /// Drags one `EndpointHandle` of a line or arrow by `(dx, dy)`. Moving an arrow's tail
    /// or tip carries its bend along — rotated and scaled with the shaft — so the curve
    /// keeps its shape; moving the bend re-curves a bendable arrow. Other shapes (and a
    /// bend on a straight style) are returned unchanged.
    func reshaped(handle: EndpointHandle, dx: Double, dy: Double) -> AnnotationElement.Kind {
        func shift(_ p: Point) -> Point { Point(x: p.x + dx, y: p.y + dy) }

        switch self {
        case let .line(from, to):
            switch handle {
            case .tail: return .line(from: shift(from), to: to)
            case .tip: return .line(from: from, to: shift(to))
            case .bend: return self
            }
        case let .arrow(from, to, bend, style):
            switch handle {
            case .tail:
                let moved = shift(from)
                let carried = bend.map { carriedBend($0, from: from, to: to, newFrom: moved, newTo: to) }
                return .arrow(from: moved, to: to, bend: carried, style: style)
            case .tip:
                let moved = shift(to)
                let carried = bend.map { carriedBend($0, from: from, to: to, newFrom: from, newTo: moved) }
                return .arrow(from: from, to: moved, bend: carried, style: style)
            case .bend:
                guard style.isBendable else { return self }
                return .arrow(from: from, to: to, bend: shift(bend ?? arrowMidpoint(from, to)), style: style)
            }
        default:
            return self
        }
    }

    /// Whether `point` hits the shape, using `tolerance` (derived from stroke
    /// width) to give thin marks a grabbable margin.
    func hitTest(_ point: Point, tolerance: Double) -> Bool {
        switch self {
        case let .line(from, to):
            return distanceFromPoint(point, toSegment: from, to) <= tolerance
        case let .arrow(from, to, bend, _):
            // A bent shaft is hit-tested along its sampled centerline, like a freehand stroke.
            return Self.freehand(points: arrowCenterline(from: from, to: to, bend: bend))
                .hitTest(point, tolerance: tolerance)
        case let .freehand(points):
            guard points.count > 1 else {
                return points.first.map { point.distance(to: $0) <= tolerance } ?? false
            }
            for i in 0..<(points.count - 1) where
                distanceFromPoint(point, toSegment: points[i], points[i + 1]) <= tolerance {
                return true
            }
            return false
        case let .ellipse(rect):
            let box = rect.standardized
            guard box.width > 0, box.height > 0 else { return false }
            let nx = (point.x - box.midX) / (box.width / 2)
            let ny = (point.y - box.midY) / (box.height / 2)
            return nx * nx + ny * ny <= 1
        case let .stepMarker(_, center, radius):
            return point.distance(to: center) <= radius + tolerance
        case .rectangle, .highlight, .redaction, .text:
            return boundingBox.insetBy(dx: -tolerance, dy: -tolerance).contains(point)
        }
    }

    private static func boundingBox(of points: [Point]) -> Rect {
        guard let first = points.first else { return Rect(x: 0, y: 0, width: 0, height: 0) }
        var minX = first.x, minY = first.y, maxX = first.x, maxY = first.y
        for p in points.dropFirst() {
            minX = min(minX, p.x); minY = min(minY, p.y)
            maxX = max(maxX, p.x); maxY = max(maxY, p.y)
        }
        return Rect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// Maps a point from the `old` box's normalized space into the `new` box.
    /// A zero-extent axis pins to the box's edge rather than dividing by zero.
    private static func remap(_ p: Point, from old: Rect, to new: Rect) -> Point {
        let fx = old.width == 0 ? 0 : (p.x - old.minX) / old.width
        let fy = old.height == 0 ? 0 : (p.y - old.minY) / old.height
        return Point(x: new.minX + fx * new.width, y: new.minY + fy * new.height)
    }
}
