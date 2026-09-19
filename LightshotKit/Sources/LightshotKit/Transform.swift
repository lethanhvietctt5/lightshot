import Foundation

/// A geometric edit applied to an element via the `transform` command.
///
/// Both cases are expressed as deltas so the editor can feed raw drag offsets
/// straight through: `move` translates the whole element, while `resize` drags a
/// single bounding-box `Handle` by `(dx, dy)` and the element's geometry is
/// remapped into the new box (see `Kind.resized(from:to:)`).
public enum Transform: Equatable, Sendable {
    case move(dx: Double, dy: Double)
    case resize(handle: Handle, dx: Double, dy: Double)
}

extension Rect {
    /// The new bounding box produced by dragging `handle` by `(dx, dy)`.
    ///
    /// Only the edges the handle touches move; the result is standardized so an
    /// overshoot that flips an edge past its opposite still yields a valid rect.
    ///
    /// Public so the editor's crop rectangle drags share the exact edge math used to
    /// resize an element, rather than duplicating (and risking drift from) it.
    public func resized(handle: Handle, dx: Double, dy: Double) -> Rect {
        var left = minX
        var top = minY
        var right = maxX
        var bottom = maxY

        switch handle {
        case .topLeft: left += dx; top += dy
        case .top: top += dy
        case .topRight: right += dx; top += dy
        case .right: right += dx
        case .bottomRight: right += dx; bottom += dy
        case .bottom: bottom += dy
        case .bottomLeft: left += dx; bottom += dy
        case .left: left += dx
        }

        return Rect(x: left, y: top, width: right - left, height: bottom - top).standardized
    }
}
