import Foundation

/// The aspect-ratio lock for a recording selection (spec 0006, story 4).
public enum AspectRatio: String, CaseIterable, Codable, Sendable {
    case freeform
    case r16x9
    case r4x3
    case r1x1
    case r9x16
    case r5x4

    /// Width divided by height, or `nil` for freeform.
    public var value: Double? {
        switch self {
        case .freeform: return nil
        case .r16x9: return 16.0 / 9.0
        case .r4x3: return 4.0 / 3.0
        case .r1x1: return 1
        case .r9x16: return 9.0 / 16.0
        case .r5x4: return 5.0 / 4.0
        }
    }

    public var title: String {
        switch self {
        case .freeform: return "Freeform"
        case .r16x9: return "16:9"
        case .r4x3: return "4:3"
        case .r1x1: return "1:1"
        case .r9x16: return "9:16"
        case .r5x4: return "5:4"
        }
    }
}

/// The recording overlay's selection as pure geometry (spec 0006, stories 3–4): a rect inside a
/// display's bounds that a drag draws, handles resize, a drag inside moves, the arrow keys nudge,
/// and typed sizes set — all under an optional aspect-ratio lock, all clamped to the bounds.
///
/// Unlike the screenshot overlay, releasing a drag never confirms: the rect stays editable until
/// the caller resolves it. Everything is in **screen points** (top-left origin), 1:1 with the
/// overlay window, so the app's model is a thin projection of this value and the geometry rules
/// are unit-tested without a window.
///
/// Ratio rule: the dragged edge or corner moves, the opposite edge stays anchored, and the other
/// axis follows the width (edges) or the pointer's dominant axis (corners); typed sizes and ratio
/// changes re-fit from the top-left corner. Anything that would leave the bounds is shrunk to fit,
/// never silently unlocked.
public struct EditableSelection: Equatable, Sendable {
    /// What a drag starting at a point does.
    public enum DragKind: Equatable, Sendable {
        case draw
        case move
        case resize(Handle)
    }

    /// The smallest side, in points, that counts as a real selection (matches the screenshot overlay).
    public static let minimumSide: Double = 4
    /// How close, in points, a drag must start to a handle to grab it.
    public static let handleGrabRadius: Double = 8

    /// The display the selection lives in (screen points).
    public let bounds: Rect
    public private(set) var ratio: AspectRatio
    /// The selection, standardized and inside `bounds`; `nil` before the first drag or after a
    /// degenerate one. In-flight it may be smaller than `minimumSide`.
    public private(set) var rect: Rect?

    private var drag: Drag?

    private struct Drag: Equatable, Sendable {
        let kind: DragKind
        /// The fixed point the pointer works against: the drag origin, the opposite corner/edge,
        /// or the pointer's start for a move.
        let anchor: Point
        let startRect: Rect?
    }

    /// Start with an optional remembered rect: clipped to the bounds if it still overlaps them by
    /// at least the minimum size, otherwise discarded rather than shown wrong.
    public init(bounds: Rect, ratio: AspectRatio = .freeform, rect: Rect? = nil) {
        self.bounds = bounds.standardized
        self.ratio = ratio
        if let rect, let inside = rect.standardized.intersection(self.bounds),
           inside.width >= Self.minimumSide, inside.height >= Self.minimumSide {
            self.rect = inside
        } else {
            self.rect = nil
        }
    }

    public var isDragging: Bool { drag != nil }

    /// Whether a selection large enough to record exists.
    public var hasSelection: Bool {
        guard let rect else { return false }
        return rect.width >= Self.minimumSide && rect.height >= Self.minimumSide
    }

    // MARK: - Dragging

    /// What a drag beginning at `point` would do: grab a handle, move the selection, or draw a new one.
    public func dragKind(at point: Point) -> DragKind {
        guard let rect, hasSelection else { return .draw }
        for handle in Handle.allCases where handlePoint(handle, in: rect).distance(to: point) <= Self.handleGrabRadius {
            return .resize(handle)
        }
        return rect.contains(point) ? .move : .draw
    }

    public mutating func dragBegan(at point: Point) {
        let kind = dragKind(at: point)
        switch kind {
        case .draw:
            drag = Drag(kind: .draw, anchor: clamp(point), startRect: nil)
            rect = Rect(origin: clamp(point), size: Size(width: 0, height: 0))
        case .move:
            drag = Drag(kind: .move, anchor: point, startRect: rect)
        case let .resize(handle):
            guard let rect else { return }
            drag = Drag(kind: .resize(handle), anchor: Self.anchor(opposite: handle, in: rect), startRect: rect)
        }
    }

    /// `forceSquare` is the Option key: a 1:1 lock for this drag only.
    public mutating func dragChanged(to point: Point, forceSquare: Bool = false) {
        guard let drag else { return }
        let lock: Double? = forceSquare ? 1 : ratio.value
        switch drag.kind {
        case .draw:
            rect = fitted(anchor: drag.anchor, toward: point, lock: lock)
        case .move:
            guard let start = drag.startRect else { return }
            rect = translated(start, by: Point(x: point.x - drag.anchor.x, y: point.y - drag.anchor.y))
        case let .resize(handle):
            guard let start = drag.startRect else { return }
            rect = resized(start, handle: handle, anchor: drag.anchor, toward: point, lock: lock)
        }
    }

    public mutating func dragEnded(at point: Point, forceSquare: Bool = false) {
        dragChanged(to: point, forceSquare: forceSquare)
        drag = nil
        if !hasSelection { rect = nil }
    }

    // MARK: - Keyboard and fields

    /// Arrow keys: move by `dx`/`dy` points, stopping at the bounds.
    public mutating func nudge(dx: Double, dy: Double) {
        guard let rect, hasSelection, !isDragging else { return }
        self.rect = translated(rect, by: Point(x: dx, y: dy))
    }

    /// ⇧-arrows: grow or shrink from the top-left corner by `dw`/`dh` points. Under a ratio lock
    /// whichever axis the key moved drives the other.
    public mutating func resize(dw: Double, dh: Double) {
        guard let rect, hasSelection, !isDragging else { return }
        if let lock = ratio.value {
            let width = dw != 0 ? rect.width + dw : (rect.height + dh) * lock
            setSize(width: width, height: width / lock)
        } else {
            setSize(width: rect.width + dw, height: rect.height + dh)
        }
    }

    /// The typed width field: resize from the top-left; the height follows a ratio lock.
    public mutating func setWidth(_ width: Double) {
        guard let rect, hasSelection else { return }
        setSize(width: width, height: ratio.value.map { width / $0 } ?? rect.height)
    }

    /// The typed height field: resize from the top-left; the width follows a ratio lock.
    public mutating func setHeight(_ height: Double) {
        guard let rect, hasSelection else { return }
        setSize(width: ratio.value.map { height * $0 } ?? rect.width, height: height)
    }

    /// Change the lock; an existing selection is re-fitted from its top-left, keeping its width.
    public mutating func setRatio(_ ratio: AspectRatio) {
        self.ratio = ratio
        guard let rect, hasSelection, let lock = ratio.value else { return }
        setSize(width: rect.width, height: rect.width / lock)
    }

    /// Replace the selection with `frame` (a picked window), clipped to the bounds.
    /// The area Record Screen starts with when nothing is remembered: a centred 16:9 rect, 1280
    /// points wide at most and never more than 60 % of the display's width (or 70 % of its height),
    /// so the take starts at a shareable size and the rest of the screen stays visible around it.
    public static func defaultRecordingRect(in bounds: Rect) -> Rect {
        var width = min(1280, bounds.width * 0.6)
        var height = width * 9 / 16
        if height > bounds.height * 0.7 {
            height = bounds.height * 0.7
            width = height * 16 / 9
        }
        return Rect(x: bounds.minX + (bounds.width - width) / 2, y: bounds.minY + (bounds.height - height) / 2, width: width, height: height)
    }

    public mutating func snap(to frame: Rect) {
        drag = nil
        rect = frame.standardized.intersection(bounds)
    }

    // MARK: - Geometry

    private mutating func setSize(width: Double, height: Double) {
        guard let rect else { return }
        var w = max(Self.minimumSide, width)
        var h = max(Self.minimumSide, height)
        // Cap at what fits from the top-left; under a lock shrink both axes together.
        let maxW = bounds.maxX - rect.minX
        let maxH = bounds.maxY - rect.minY
        if let lock = ratio.value {
            let scale = min(1, maxW / w, maxH / h)
            w *= scale
            h = w / lock
        } else {
            w = min(w, maxW)
            h = min(h, maxH)
        }
        self.rect = Rect(x: rect.minX, y: rect.minY, width: w, height: h)
    }

    private func clamp(_ point: Point) -> Point {
        Point(x: min(max(point.x, bounds.minX), bounds.maxX), y: min(max(point.y, bounds.minY), bounds.maxY))
    }

    private func translated(_ rect: Rect, by delta: Point) -> Rect {
        let x = min(max(rect.minX + delta.x, bounds.minX), bounds.maxX - rect.width)
        let y = min(max(rect.minY + delta.y, bounds.minY), bounds.maxY - rect.height)
        return Rect(x: x, y: y, width: rect.width, height: rect.height)
    }

    /// The rect spanned from `anchor` toward `point`, ratio-locked (driven by the pointer's
    /// dominant axis) and shrunk to stay inside the bounds without moving the anchor.
    private func fitted(anchor: Point, toward point: Point, lock: Double?) -> Rect {
        let target = clamp(point)
        var dx = target.x - anchor.x
        var dy = target.y - anchor.y
        if let lock {
            let sx: Double = dx < 0 ? -1 : 1
            let sy: Double = dy < 0 ? -1 : 1
            var w = abs(dx)
            var h = abs(dy)
            if w >= h * lock { h = w / lock } else { w = h * lock }
            // Shrink to fit the bounds on the far side of the anchor, keeping the lock.
            let roomX = sx > 0 ? bounds.maxX - anchor.x : anchor.x - bounds.minX
            let roomY = sy > 0 ? bounds.maxY - anchor.y : anchor.y - bounds.minY
            let scale = min(1, w > 0 ? roomX / w : 1, h > 0 ? roomY / h : 1)
            w *= scale
            h = w / lock
            dx = sx * w
            dy = sy * h
        }
        return rectBetween(anchor, Point(x: anchor.x + dx, y: anchor.y + dy))
    }

    private func resized(_ start: Rect, handle: Handle, anchor: Point, toward point: Point, lock: Double?) -> Rect {
        let target = clamp(point)
        switch handle {
        case .topLeft, .topRight, .bottomLeft, .bottomRight:
            return fitted(anchor: anchor, toward: target, lock: lock)
        case .left, .right:
            // The edge follows the pointer's x (crossing the anchor flips the rect). Under a lock the
            // height follows, anchored at the top, and both are capped by the room on that side.
            let dx = target.x - anchor.x
            guard let lock else {
                return Rect(x: min(anchor.x, anchor.x + dx), y: start.minY, width: abs(dx), height: start.height)
            }
            let roomX = dx < 0 ? anchor.x - bounds.minX : bounds.maxX - anchor.x
            var width = min(abs(dx), roomX)
            var height = width / lock
            let roomY = bounds.maxY - start.minY
            if height > roomY { height = roomY; width = height * lock }
            return Rect(x: dx < 0 ? anchor.x - width : anchor.x, y: start.minY, width: width, height: height)
        case .top, .bottom:
            let dy = target.y - anchor.y
            guard let lock else {
                return Rect(x: start.minX, y: min(anchor.y, anchor.y + dy), width: start.width, height: abs(dy))
            }
            let roomY = dy < 0 ? anchor.y - bounds.minY : bounds.maxY - anchor.y
            var height = min(abs(dy), roomY)
            var width = height * lock
            let roomX = bounds.maxX - start.minX
            if width > roomX { width = roomX; height = width / lock }
            return Rect(x: start.minX, y: dy < 0 ? anchor.y - height : anchor.y, width: width, height: height)
        }
    }

    /// The point that stays fixed while `handle` is dragged: the opposite corner, or the opposite
    /// edge's midpoint.
    private static func anchor(opposite handle: Handle, in rect: Rect) -> Point {
        let opposite: Handle
        switch handle {
        case .topLeft: opposite = .bottomRight
        case .top: opposite = .bottom
        case .topRight: opposite = .bottomLeft
        case .right: opposite = .left
        case .bottomRight: opposite = .topLeft
        case .bottom: opposite = .top
        case .bottomLeft: opposite = .topRight
        case .left: opposite = .right
        }
        return handlePoint(opposite, in: rect)
    }
}
