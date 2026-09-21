import Foundation

// Pure arrow geometry. Coordinate-space-agnostic: every function returns points in the
// same space as its inputs, so the on-screen preview (view space) and the flatten render
// (context space) share one definition of each arrow style instead of duplicating the
// trigonometry. All sizes derive from `lineWidth` alone, so the two never disagree.

/// The draggable points of a selected line or arrow. Lines and straight arrows expose
/// `tail` and `tip`; a bendable arrow adds `bend`, which sits on the shaft's middle.
public enum EndpointHandle: Equatable, Sendable, CaseIterable {
    case tail, tip, bend
}

/// One step of a vector outline, in the same space as the points that produced it.
public enum PathElement: Equatable, Sendable {
    case move(Point)
    case line(Point)
    case quadCurve(to: Point, control: Point)
    case close
}

/// A drawable arrow: an outline plus how to paint it.
public struct ArrowShape: Equatable, Sendable {
    public enum Paint: Equatable, Sendable {
        /// Fill the outline. A non-zero `rounding` also strokes it at that width with
        /// round joins, which is what softens the corners of the `standard` head.
        case fill(rounding: Double)
        /// Stroke the outline at `width` with round caps and joins.
        case stroke(width: Double)
    }

    public var path: [PathElement]
    public var paint: Paint
}

/// The midpoint of the straight segment `a`–`b` — where a bend handle rests before it is dragged.
public func arrowMidpoint(_ a: Point, _ b: Point) -> Point {
    Point(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
}

/// The bend a freshly drawn bendable arrow starts with: a gentle arc (bowing upward for an
/// arrow drawn right-to-left), so the style reads as curved the moment it is drawn.
public func defaultArrowBend(from: Point, to: Point) -> Point {
    let mid = arrowMidpoint(from, to)
    return Point(x: mid.x - (to.y - from.y) * defaultBendRatio, y: mid.y + (to.x - from.x) * defaultBendRatio)
}

/// The shaft's centerline as a polyline — two points when straight, a sampled quadratic
/// through `bend` otherwise. Used for hit-testing.
public func arrowCenterline(from: Point, to: Point, bend: Point?) -> [Point] {
    guard let bend else { return [from, to] }
    let control = bendControl(from: from, to: to, bend: bend)
    return (0...centerlineSamples).map { i in
        let t = Double(i) / Double(centerlineSamples)
        let a = (1 - t) * (1 - t), b = 2 * (1 - t) * t, c = t * t
        return Point(x: a * from.x + b * control.x + c * to.x, y: a * from.y + b * control.y + c * to.y)
    }
}

/// The outline of an arrow from `from` (tail) to `to` (tip) in `style`, sized from
/// `lineWidth`. Returns an empty path for a zero-length arrow. `bend` is honored only by
/// bendable styles.
public func arrowShape(
    from: Point, to: Point, bend: Point?, style: ArrowStyle, lineWidth: Double
) -> ArrowShape {
    let length = from.distance(to: to)
    guard length > 0 else { return ArrowShape(path: [], paint: .fill(rounding: 0)) }

    switch style {
    case .standard, .fancy:
        return taperedArrow(from: from, to: to, length: length, fancy: style == .fancy, lineWidth: lineWidth)
    case .curved, .double:
        return strokedArrow(from: from, to: to, bend: bend, length: length,
                            bothEnds: style == .double, lineWidth: lineWidth)
    }
}

// MARK: - Styles

/// A filled arrow whose shaft widens from a thin tail into the head. `fancy` sweeps the
/// head's barbs back past a notch and keeps every corner sharp; otherwise the head is a
/// plain triangle with softened corners.
private func taperedArrow(from: Point, to: Point, length: Double, fancy: Bool, lineWidth: Double) -> ArrowShape {
    let u = Point(x: (to.x - from.x) / length, y: (to.y - from.y) / length)
    let p = Point(x: -u.y, y: u.x)
    // A short arrow shrinks its head (and everything sized from it) rather than letting
    // the head swallow the shaft.
    let head = min(lineWidth * 5, length * 0.6)
    let rounding = fancy ? 0 : head * 0.1
    let headHalf = head * 0.5
    let shaftHalf = head * 0.17
    let tailHalf = head * (fancy ? 0.02 : 0.04)

    func at(_ along: Double, _ across: Double) -> Point {
        Point(x: to.x - u.x * along + p.x * across, y: to.y - u.y * along + p.y * across)
    }
    // The rounding stroke grows the outline by half its width, so pull the tip and tail
    // in by that much to keep the drawn arrow ending exactly at `from` and `to`.
    let inset = rounding / 2
    let neck = fancy ? head * 0.8 : head

    return ArrowShape(
        path: [
            .move(at(length - inset, tailHalf)),
            .line(at(neck, shaftHalf)),
            .line(at(head, headHalf)),
            .line(at(inset, 0)),
            .line(at(head, -headHalf)),
            .line(at(neck, -shaftHalf)),
            .line(at(length - inset, -tailHalf)),
            .close,
        ],
        paint: .fill(rounding: rounding)
    )
}

/// An even stroke along the (possibly bent) shaft with an open two-stroke head at the tip,
/// and at the tail too when `bothEnds`. Each head follows the shaft's tangent where it ends.
private func strokedArrow(
    from: Point, to: Point, bend: Point?, length: Double, bothEnds: Bool, lineWidth: Double
) -> ArrowShape {
    let control = bendControl(from: from, to: to, bend: bend ?? arrowMidpoint(from, to))
    let arm = min(lineWidth * 4, length * 0.5)

    /// The two-stroke open head at `tip`, pointing away from `toward`.
    func head(at tip: Point, comingFrom toward: Point) -> [PathElement] {
        var dx = tip.x - toward.x, dy = tip.y - toward.y
        var d = (dx * dx + dy * dy).squareRoot()
        if d == 0 { dx = to.x - from.x; dy = to.y - from.y; d = length }
        let t = Point(x: dx / d, y: dy / d)
        // Arms sweep back from the tip at ±45° to the tangent.
        let k = arm * 0.5.squareRoot()
        let left = Point(x: tip.x - (t.x - t.y) * k, y: tip.y - (t.y + t.x) * k)
        let right = Point(x: tip.x - (t.x + t.y) * k, y: tip.y - (t.y - t.x) * k)
        return [.move(left), .line(tip), .line(right)]
    }

    var path: [PathElement] = [.move(from), .quadCurve(to: to, control: control)]
    path += head(at: to, comingFrom: control)
    if bothEnds { path += head(at: from, comingFrom: control) }
    return ArrowShape(path: path, paint: .stroke(width: lineWidth))
}

// MARK: - Bend math

/// The quadratic control point that makes the curve pass through `bend` at its middle.
private func bendControl(from: Point, to: Point, bend: Point) -> Point {
    let mid = arrowMidpoint(from, to)
    return Point(x: 2 * bend.x - mid.x, y: 2 * bend.y - mid.y)
}

/// Where `bend` lands after the shaft `from`→`to` becomes `newFrom`→`newTo`: the bend is
/// held fixed in the shaft's own frame (along / across, as fractions of its length), so
/// dragging an endpoint rotates and scales the curve instead of distorting it.
func carriedBend(_ bend: Point, from: Point, to: Point, newFrom: Point, newTo: Point) -> Point {
    let v = to - from
    let lengthSquared = v.x * v.x + v.y * v.y
    guard lengthSquared > 0 else {
        let oldMid = arrowMidpoint(from, to), newMid = arrowMidpoint(newFrom, newTo)
        return Point(x: bend.x + newMid.x - oldMid.x, y: bend.y + newMid.y - oldMid.y)
    }
    let d = bend - from
    let along = (d.x * v.x + d.y * v.y) / lengthSquared
    let across = (v.x * d.y - v.y * d.x) / lengthSquared
    let nv = newTo - newFrom
    return Point(x: newFrom.x + along * nv.x - across * nv.y, y: newFrom.y + along * nv.y + across * nv.x)
}

/// How far a new bendable arrow bows, as a fraction of its length.
private let defaultBendRatio: Double = 0.18
private let centerlineSamples = 16
