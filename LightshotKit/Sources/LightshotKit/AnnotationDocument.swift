import Foundation

/// The domain heart: a pure value type holding a screenshot plus its annotations,
/// mutated **only** through an explicit command API.
///
/// The document owns everything expressible as pure functions over its state —
/// undo/redo history, step-marker auto-increment, crop math, and hit-testing — so
/// this behavior is fully verifiable through the public API with no display,
/// permissions, or AppKit/ScreenCaptureKit involvement.
///
/// Element geometry is stored in **image pixel coordinates** and is never rewritten
/// by a crop: `applyCrop` only records the visible frame, which is what keeps marks
/// correct across crop and multi-scale export.
public struct AnnotationDocument: Equatable, Sendable {

    /// The slice of document state that undo/redo captures.
    ///
    /// Selection is deliberately excluded — selecting an element is ephemeral UI
    /// state, not an editing action, so it must not land on the undo stack.
    private struct State: Equatable, Sendable {
        var elements: [AnnotationElement] = []
        var cropRect: Rect?
    }

    /// The immutable base image (handle + native pixel size).
    public let baseImage: CapturedImage

    private var state = State()
    private var undoStack: [State] = []
    private var redoStack: [State] = []

    /// Identifies a run of edits that should collapse into one undo entry.
    ///
    /// Consecutive commands sharing a key — with nothing else between — push only a
    /// single undo entry, so dragging a slider or typing a word is one undo step, not
    /// dozens. Any command with a different (or nil) key, a `select`, an `undo`/`redo`,
    /// or an explicit `endCoalescing()` closes the run.
    private enum CoalesceKey: Equatable {
        case style(ElementID)
        case text(ElementID)
    }

    /// The open coalescing run, if any (see `CoalesceKey`).
    private var coalesceKey: CoalesceKey?

    /// The currently selected element, if any. Not part of undo history.
    public private(set) var selectedID: ElementID?

    public init(baseImage: CapturedImage) {
        self.baseImage = baseImage
    }

    // MARK: - Read-only projections

    /// Elements in z-order — later means drawn on top.
    public var elements: [AnnotationElement] { state.elements }

    /// The recorded crop rect, or `nil` when the full image is visible.
    public var cropRect: Rect? { state.cropRect }

    /// The full base-image rect in pixel coordinates.
    public var imageBounds: Rect {
        Rect(x: 0, y: 0, width: Double(baseImage.pixelWidth), height: Double(baseImage.pixelHeight))
    }

    /// The currently visible frame: the crop rect if set, else the whole image.
    public var visibleFrame: Rect { state.cropRect ?? imageBounds }

    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }

    public func element(id: ElementID) -> AnnotationElement? {
        state.elements.first { $0.id == id }
    }

    // MARK: - Hit-testing

    /// The topmost element whose geometry contains `point` (image coordinates),
    /// or `nil` when the point misses every element. Pure — no view involvement.
    public func elementID(at point: Point) -> ElementID? {
        // Topmost first — but a focus area only catches a click no other mark takes, since it
        // usually frames the very marks the user wants to reach (LIG-47).
        let hits = state.elements.reversed().filter { element in
            element.kind.hitTest(point, tolerance: max(element.style.strokeWidth / 2, Self.minHitTolerance))
        }
        return (hits.first { $0.kind.focusRect == nil } ?? hits.first)?.id
    }

    /// The mark a drawing tool picks up at `point` instead of starting a new one (LIG-47): like
    /// `elementID(at:)`, but an unfilled rectangle or ellipse counts only near its outline, so a
    /// new mark can still be started inside one.
    public func grabbableElementID(at point: Point) -> ElementID? {
        let hits = state.elements.reversed().filter { element in
            let tolerance = max(element.style.strokeWidth / 2, Self.minHitTolerance)
            guard element.kind.hitTest(point, tolerance: tolerance) else { return false }
            guard element.style.fill == nil else { return true }
            return element.kind.isNearOutline(point, tolerance: tolerance) ?? true
        }
        return (hits.first { $0.kind.focusRect == nil } ?? hits.first)?.id
    }

    /// The step number a new marker would receive: one past the highest existing
    /// marker, or `1` when none exist ("based on existing markers", per spec 0001).
    ///
    /// Survivors are never renumbered by a delete. Because the value is derived from
    /// the *current* markers, deleting the highest marker frees its number for reuse
    /// by the next add, while deleting a middle marker leaves a gap. This matches the
    /// spec's stated rule; CleanShot parity here is flagged as "confirm if it matters."
    public var nextStepNumber: Int {
        let highest = state.elements.compactMap { element -> Int? in
            if case let .stepMarker(number, _, _) = element.kind { return number }
            return nil
        }.max()
        return (highest ?? 0) + 1
    }

    // MARK: - Commands

    /// Appends `element` on top of the z-order and returns its id. A `stepMarker`
    /// has its number reassigned to `nextStepNumber`, so callers never number by hand.
    @discardableResult
    public mutating func add(_ element: AnnotationElement) -> ElementID {
        var element = element
        if case let .stepMarker(_, center, radius) = element.kind {
            element.kind = .stepMarker(number: nextStepNumber, center: center, radius: radius)
        }
        let id = element.id
        perform { $0.elements.append(element) }
        return id
    }

    /// Appends every element on top of the z-order, in order, as **one** undo step (an auto
    /// redact batch, spec 0009). Step markers are numbered as consecutive `add`s would number
    /// them. An empty list changes nothing and records no undo step.
    @discardableResult
    public mutating func add(contentsOf elements: [AnnotationElement]) -> [ElementID] {
        var next = nextStepNumber
        let numbered = elements.map { element -> AnnotationElement in
            var element = element
            if case let .stepMarker(_, center, radius) = element.kind {
                element.kind = .stepMarker(number: next, center: center, radius: radius)
                next += 1
            }
            return element
        }
        perform { $0.elements.append(contentsOf: numbered) }
        return numbered.map(\.id)
    }

    /// Records the selection. Passing `nil` clears it; an unknown id is ignored,
    /// leaving the current selection intact. Not undoable, but it closes any open
    /// coalescing run so edits before and after a selection change stay distinct.
    public mutating func select(_ id: ElementID?) {
        coalesceKey = nil
        guard let id else { selectedID = nil; return }
        if state.elements.contains(where: { $0.id == id }) { selectedID = id }
    }

    /// Moves or resizes the element (see `Transform`). No-op if `id` is unknown.
    public mutating func transform(_ id: ElementID, by transform: Transform) {
        withElement(id) { element in
            switch transform {
            case let .move(dx, dy):
                element.kind = element.kind.moved(dx: dx, dy: dy)
            case let .resize(handle, dx, dy):
                if case .text = element.kind {
                    Self.resizeText(&element, handle: handle, dx: dx)
                } else {
                    element.kind = element.kind.resized(handle: handle, dx: dx, dy: dy)
                }
            case let .reshape(handle, dx, dy):
                element.kind = element.kind.reshaped(handle: handle, dx: dx, dy: dy)
            }
        }
    }

    /// Replaces the element's style. No-op if `id` is unknown. Consecutive style edits
    /// on the same element coalesce, so one slider drag is one undo step (story 35).
    public mutating func setStyle(_ id: ElementID, _ style: Style) {
        withElement(id, coalescing: .style(id)) { element in
            let oldSize = element.style.fontSize
            element.style = style
            // A label's box follows its type size: a natural-width one regrows, a hand-set one
            // keeps its width and rewraps.
            if case let .text(string, box) = element.kind, oldSize != style.fontSize {
                let natural = TextLayout.hasNaturalWidth(box, string: string, fontSize: oldSize)
                element.kind = .text(string, box: TextLayout.box(
                    for: string, fontSize: style.fontSize, origin: box.standardized.origin,
                    width: natural ? nil : box.standardized.width
                ))
            }
        }
    }

    /// Sets a step marker's `radius` — its on-image size. No-op if `id` is not a step
    /// marker. Shares the `setStyle` coalescing key so a font-size change (which sizes
    /// both the disc and its number) lands as a single undo step (stories 28, 35).
    public mutating func setStepRadius(_ id: ElementID, _ radius: Double) {
        withElement(id, coalescing: .style(id)) { element in
            guard case let .stepMarker(number, center, _) = element.kind else { return }
            element.kind = .stepMarker(number: number, center: center, radius: max(radius, 1))
        }
    }

    /// Redraws an arrow in `style`, keeping its tail and tip. No-op if `id` is not an arrow.
    /// Only bendable styles carry a bend: switching to one gives a straight arrow a bend at
    /// rest on its midpoint (still straight), and switching away drops the bend.
    public mutating func setArrowStyle(_ id: ElementID, _ style: ArrowStyle) {
        withElement(id) { element in
            guard case let .arrow(from, to, bend, _) = element.kind else { return }
            let newBend = style.isBendable ? (bend ?? defaultArrowBend(from: from, to: to)) : nil
            element.kind = .arrow(from: from, to: to, bend: newBend, style: style)
        }
    }

    /// Changes how a redaction obscures its region, keeping its rect and seed. `strength`
    /// is clamped to `0...1`. No-op if `id` is not a redaction. Shares the `setStyle`
    /// coalescing key, so one strength-slider drag is one undo step (story 35).
    public mutating func setRedaction(_ id: ElementID, style: RedactionStyle, strength: Double) {
        withElement(id, coalescing: .style(id)) { element in
            guard case let .redaction(rect, _, _, seed) = element.kind else { return }
            element.kind = .redaction(rect, style: style, strength: min(max(strength, 0), 1), seed: seed)
        }
    }

    /// Rewrites a text element's string, keeping its box. No-op if `id` is not text.
    /// Consecutive edits coalesce, so typing a word is one undo step (story 35).
    public mutating func updateText(_ id: ElementID, to string: String) {
        withElement(id, coalescing: .text(id)) { element in
            guard case let .text(old, box) = element.kind else { return }
            // A label with its natural width grows with its text; one whose width was set by hand
            // keeps it and wraps (LIG-47). Either way the box is as tall as the text.
            let fontSize = element.style.fontSize
            let natural = TextLayout.hasNaturalWidth(box, string: old, fontSize: fontSize)
            element.kind = .text(string, box: TextLayout.box(
                for: string, fontSize: fontSize, origin: box.standardized.origin,
                width: natural ? nil : box.standardized.width
            ))
        }
    }

    /// The handles a selected label offers (LIG-47): its side edges set the wrap width, its
    /// bottom-right corner scales the text.
    public static let textHandles: [Handle] = [.left, .right, .bottomRight]

    /// A side handle sets the label's width (the text rewraps, the opposite side stays put); the
    /// bottom-right corner scales the text and its box together from the top-left. Any other
    /// handle leaves a label alone.
    private static func resizeText(_ element: inout AnnotationElement, handle: Handle, dx: Double) {
        guard case let .text(string, box) = element.kind else { return }
        let old = box.standardized
        let fontSize = element.style.fontSize
        switch handle {
        case .left, .right:
            let width = max(old.width + (handle == .left ? -dx : dx), TextLayout.minimumWidth(for: fontSize))
            let x = handle == .left ? old.maxX - width : old.minX
            element.kind = .text(string, box: TextLayout.box(
                for: string, fontSize: fontSize, origin: Point(x: x, y: old.minY), width: width
            ))
        case .bottomRight:
            let scale = max(old.width + dx, 1) / max(old.width, 1)
            let size = min(max((fontSize * scale).rounded(), textFontSizes.lowerBound), textFontSizes.upperBound)
            let ratio = size / fontSize
            let natural = TextLayout.hasNaturalWidth(old, string: string, fontSize: fontSize)
            element.style.fontSize = size
            element.kind = .text(string, box: TextLayout.box(
                for: string, fontSize: size, origin: old.origin, width: natural ? nil : old.width * ratio
            ))
        default:
            break
        }
    }

    /// The type sizes a label can be scaled to.
    public static let textFontSizes: ClosedRange<Double> = 6...200

    /// Closes any open coalescing run so the next edit starts a fresh undo entry. The
    /// editor calls this at interaction boundaries (a slider release, the end of a text
    /// edit) so two separate drags become two undo steps rather than one.
    public mutating func endCoalescing() { coalesceKey = nil }

    /// Removes the element. Clears selection if it pointed at it. No-op if unknown.
    public mutating func delete(_ id: ElementID) {
        perform { $0.elements.removeAll { $0.id == id } }
        if selectedID == id { selectedID = nil }
    }

    /// Moves the element to `index` in the z-order (clamped). No-op if unknown or
    /// already there. Step numbers are unaffected — only draw order changes.
    public mutating func reorder(_ id: ElementID, to index: Int) {
        perform { state in
            guard let current = state.elements.firstIndex(where: { $0.id == id }) else { return }
            let element = state.elements.remove(at: current)
            let clamped = min(max(index, 0), state.elements.count)
            state.elements.insert(element, at: clamped)
        }
    }

    /// Records the visible frame, clamped to the image bounds. Elements are left in
    /// image coordinates, so undoing this restores the full frame with marks intact.
    /// A rect that doesn't overlap the image is ignored.
    public mutating func applyCrop(_ rect: Rect) {
        let bounds = imageBounds
        perform { state in
            guard let clamped = bounds.intersection(rect) else { return }
            state.cropRect = clamped
        }
    }

    /// Reverts the most recent content command; no-op when there's nothing to undo.
    public mutating func undo() {
        coalesceKey = nil
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(state)
        state = previous
        sanitizeSelection()
    }

    /// Re-applies the most recently undone command; no-op when the redo stack is empty.
    public mutating func redo() {
        coalesceKey = nil
        guard let next = redoStack.popLast() else { return }
        undoStack.append(state)
        state = next
        sanitizeSelection()
    }

    // MARK: - History plumbing

    /// Applies `body` to the element addressed by `id` (if any) as a content
    /// mutation. Centralizes the id lookup shared by `transform`/`setStyle`/`updateText`.
    /// `key` opts the edit into a coalescing run (see `CoalesceKey`); `nil` keeps it a
    /// standalone undo step.
    private mutating func withElement(
        _ id: ElementID,
        coalescing key: CoalesceKey? = nil,
        _ body: (inout AnnotationElement) -> Void
    ) {
        perform(coalescing: key) { state in
            guard let index = state.elements.firstIndex(where: { $0.id == id }) else { return }
            body(&state.elements[index])
        }
    }

    /// Runs a content mutation, pushing an undo entry only if the state actually
    /// changed. A new content command clears the redo stack (redo invalidation).
    ///
    /// When `key` matches the open coalescing run, the change folds into the entry
    /// already on the stack instead of pushing a new one, so a continuous interaction
    /// (a slider drag, a burst of keystrokes) collapses to a single undo step. Any other
    /// key — including the default `nil` — closes the run and starts a fresh entry.
    private mutating func perform(coalescing key: CoalesceKey? = nil, _ change: (inout State) -> Void) {
        let before = state
        change(&state)
        guard state != before else { return }
        if key == nil || key != coalesceKey {
            undoStack.append(before)
        }
        redoStack.removeAll()
        coalesceKey = key
    }

    /// Drops a dangling selection after undo/redo removed the selected element.
    private mutating func sanitizeSelection() {
        if let id = selectedID, !state.elements.contains(where: { $0.id == id }) {
            selectedID = nil
        }
    }

    /// Minimum grab margin for thin marks, in image pixels.
    private static let minHitTolerance: Double = 6
}
