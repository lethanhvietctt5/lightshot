import SwiftUI
import AppKit
import LightshotKit

/// The editor's UI-facing state and interaction logic, kept out of the SwiftUI view so
/// the view stays a thin projection of it.
///
/// Every edit is expressed as an `AnnotationDocument` command — the model never stores
/// geometry of its own. In-progress gestures (drawing a shape, dragging a selection or a
/// resize handle) are shown as a **preview** computed from a throwaway copy of the
/// document and are committed as a **single** command on release, so one gesture is one
/// undo step (story 35). All coordinates cross into image space through `CanvasProjection`.
@MainActor
@Observable
final class EditorModel {

    /// The annotation tools the palette offers: vector marks + step markers (LIG-9), plus the
    /// highlighter and region redaction (LIG-12).
    enum Tool: String, CaseIterable, Identifiable {
        case select, arrow, line, rectangle, ellipse, freehand, text, step, highlight, redact
        var id: String { rawValue }

        /// SF Symbol for the palette button.
        var symbol: String { info.symbol }
        /// Tooltip shown on hover.
        var help: String { info.help }

        /// Single source for the per-tool palette metadata, so symbol and help can't
        /// drift out of a case each (one switch, not one per attribute).
        private var info: (symbol: String, help: String) {
            switch self {
            case .select: return ("arrow.up.left.and.arrow.down.right", "Select, move, and resize")
            case .arrow: return ("arrow.up.right", "Arrow")
            case .line: return ("line.diagonal", "Line")
            case .rectangle: return ("rectangle", "Rectangle")
            case .ellipse: return ("circle", "Ellipse")
            case .freehand: return ("scribble", "Freehand")
            case .text: return ("textformat", "Text")
            case .step: return ("1.circle.fill", "Step marker")
            case .highlight: return ("highlighter", "Highlighter — translucent wash, doesn't hide content")
            case .redact: return ("eye.slash", "Redact a region (blackout, blur, or pixelate)")
            }
        }
    }

    private(set) var document: AnnotationDocument
    private let copy: (AnnotationDocument) -> Void

    var tool: Tool = .select { didSet { if tool != .select { endTextEditing() } } }

    /// Which style a new redaction uses. **Defaults to `blackout`** — the only secure
    /// redaction (story 24): `blur`/`pixelate` merely obscure and must never be presented as
    /// secret-safe. The toolbar surfaces this and warns when a non-secure style is chosen.
    var redactionStyle: RedactionStyle = .blackout

    /// The style applied to new marks, kept in sync with the selection while one exists.
    private(set) var style: Style = .default

    /// The text element currently being edited (from placing or double-clicking a label).
    private(set) var editingTextID: ElementID?

    /// Current aspect-fit scale, pushed in by the view; sizes the handle grab radius.
    var viewScale: Double = 1

    // In-progress interaction (nil when idle). Exactly one is ever non-nil.
    private var draft: Draft?
    private var drag: DragSession?
    private var gestureActive = false

    init(document: AnnotationDocument, copy: @escaping (AnnotationDocument) -> Void) {
        self.document = document
        self.copy = copy
    }

    // MARK: - Derived state for the view

    var baseSize: Size {
        Size(width: Double(document.baseImage.pixelWidth), height: Double(document.baseImage.pixelHeight))
    }
    var imageBounds: Rect { document.imageBounds }
    var selectedID: ElementID? { document.selectedID }
    var canUndo: Bool { document.canUndo }
    var canRedo: Bool { document.canRedo }
    var hasSelection: Bool { document.selectedID != nil }

    /// Elements to draw, with any in-progress move/resize applied as a preview.
    var displayElements: [AnnotationElement] {
        guard let drag else { return document.elements }
        var preview = document
        preview.transform(drag.id, by: drag.transform)
        return preview.elements
    }

    /// The shape being drawn right now, if any (drawn on top of `displayElements`).
    var draftElement: AnnotationElement? {
        guard let draft, let kind = draft.kind else { return nil }
        return AnnotationElement(kind: kind, style: style)
    }

    /// The bounding box (image space) to hang selection handles on, or nil.
    var selectionBox: Rect? {
        guard drag == nil, draft == nil, let id = document.selectedID else { return nil }
        return document.element(id: id)?.kind.boundingBox
    }

    // MARK: - Tool palette

    func selectTool(_ tool: Tool) { self.tool = tool }

    // MARK: - Style controls (story 26–28)

    func setColor(_ color: RGBAColor) { style.color = color; applyStyleToSelection() }
    func setStrokeWidth(_ width: Double) { style.strokeWidth = width; applyStyleToSelection() }

    /// Changes the font size of the selection. For a text label this reweights the glyphs;
    /// for a step marker — whose drawn size is its geometry `radius`, not `style.fontSize`
    /// — it also resizes the disc, so the control isn't a no-op there (story 28).
    func setFontSize(_ size: Double) {
        style.fontSize = size
        guard let id = document.selectedID else { return }
        document.setStyle(id, style)
        if case .stepMarker? = document.element(id: id)?.kind {
            document.setStepRadius(id, size)
        }
    }

    /// Closes the current style-edit coalescing run so the next drag is a distinct undo
    /// step. The view calls this when a slider ends editing (story 35).
    func commitStyleEdit() { document.endCoalescing() }

    private func applyStyleToSelection() {
        if let id = document.selectedID { document.setStyle(id, style) }
    }

    // MARK: - History & output

    func undo() { endTextEditing(); document.undo() }
    func redo() { endTextEditing(); document.redo() }
    func deleteSelection() {
        guard let id = document.selectedID else { return }
        endTextEditing()
        document.delete(id)
    }
    func copyToClipboard() { endTextEditing(); copy(document) }

    // MARK: - Z-order (story 33)

    /// Moves the selected element one step up in the z-order (toward the front).
    func bringForward() {
        guard let id = document.selectedID, let index = selectedIndex else { return }
        document.reorder(id, to: index + 1)
    }

    /// Moves the selected element one step down in the z-order (toward the back).
    func sendBackward() {
        guard let id = document.selectedID, let index = selectedIndex else { return }
        document.reorder(id, to: index - 1)
    }

    /// z-order index of the current selection, or nil when nothing is selected.
    private var selectedIndex: Int? {
        guard let id = document.selectedID else { return nil }
        return document.elements.firstIndex { $0.id == id }
    }

    // MARK: - Text editing (story 21)

    /// Live-bound text of the label under edit; commits through `updateText`.
    var editingText: String {
        get {
            guard let id = editingTextID, case let .text(string, _)? = document.element(id: id)?.kind else { return "" }
            return string
        }
        set {
            guard let id = editingTextID else { return }
            document.updateText(id, to: newValue)
        }
    }

    func beginEditingSelectedText() {
        guard let id = document.selectedID, case .text? = document.element(id: id)?.kind else { return }
        editingTextID = id
    }

    /// Double-clicking selects the element under the point and, if it's a label, opens it
    /// for editing (story 21). Returns whether a text edit session began.
    @discardableResult
    func doubleClick(at point: Point) -> Bool {
        guard let id = document.elementID(at: point) else { return false }
        document.select(id)
        syncStyleToSelection()
        beginEditingSelectedText()
        return editingTextID != nil
    }

    /// Ends the editing session, discarding a label the user left empty.
    func endTextEditing() {
        guard let id = editingTextID else { return }
        editingTextID = nil
        // Close the typing run so re-editing the same label later is a distinct undo step.
        document.endCoalescing()
        if case let .text(string, _)? = document.element(id: id)?.kind,
           string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            document.delete(id)
        }
    }

    // MARK: - Canvas gesture (image-space points)

    func gestureChanged(at point: Point) {
        if gestureActive {
            move(to: point)
        } else {
            gestureActive = true
            begin(at: point)
        }
    }

    func gestureEnded(at point: Point) {
        if !gestureActive { begin(at: point) }
        move(to: point)
        end(at: point)
        gestureActive = false
    }

    private func begin(at point: Point) {
        endTextEditing()
        switch tool {
        case .select:
            beginSelectGesture(at: point)
        case .arrow, .line, .rectangle, .ellipse, .freehand, .text, .step, .highlight, .redact:
            draft = Draft(tool: tool, start: point, current: point, points: [point], redactionStyle: redactionStyle)
        }
    }

    private func move(to point: Point) {
        if drag != nil {
            drag?.current = point
        } else if draft != nil {
            draft?.current = point
            draft?.points.append(point)
        }
    }

    private func end(at point: Point) {
        defer { draft = nil; drag = nil }

        if let drag {
            document.transform(drag.id, by: drag.transform)
            return
        }
        guard let draft else { return }

        switch draft.tool {
        case .text:
            placeText(at: draft.start)
        case .step:
            placeStepMarker(at: draft.start)
        default:
            if let kind = draft.kind {
                let id = document.add(AnnotationElement(kind: kind, style: style))
                document.select(id)
                tool = .select
            }
        }
    }

    // MARK: - Select / move / resize (stories 29–31)

    private func beginSelectGesture(at point: Point) {
        if let id = document.selectedID,
           let box = document.element(id: id)?.kind.boundingBox,
           let handle = handle(at: point, of: box) {
            drag = DragSession(id: id, mode: .resize(handle), start: point, current: point)
            return
        }
        if let hit = document.elementID(at: point) {
            document.select(hit)
            drag = DragSession(id: hit, mode: .move, start: point, current: point)
        } else {
            document.select(nil)
        }
    }

    /// The resize handle near `point`, if the point is within a grab radius of one.
    private func handle(at point: Point, of box: Rect) -> Handle? {
        let tolerance = max(Self.handleRadius / max(viewScale, 0.0001), 4)
        return Handle.allCases.first { h in
            let hp = handlePoint(h, in: box)
            return abs(hp.x - point.x) <= tolerance && abs(hp.y - point.y) <= tolerance
        }
    }

    // MARK: - Placement (stories 20, 25)

    private func placeText(at point: Point) {
        let box = Rect(x: point.x, y: point.y, width: max(style.fontSize * 6, 80), height: style.fontSize * 1.4)
        let id = document.add(AnnotationElement(kind: .text("", box: box), style: style))
        document.select(id)
        editingTextID = id
    }

    private func placeStepMarker(at point: Point) {
        let radius = max(style.fontSize, 14)
        let id = document.add(AnnotationElement(kind: .stepMarker(number: 0, center: point, radius: radius), style: style))
        document.select(id)
    }

    // MARK: - Selection sync

    /// Reflects the tapped element's style back into the palette controls so the sliders
    /// and color well show what they will change. Called by the view after a click.
    func syncStyleToSelection() {
        guard let id = document.selectedID, let element = document.element(id: id) else { return }
        var synced = element.style
        // A step marker's size lives in its geometry, not `style.fontSize`; surface the
        // radius through the font-size control so the slider reflects (and drives) it.
        if case let .stepMarker(_, _, radius) = element.kind { synced.fontSize = radius }
        style = synced
    }

    private static let handleRadius: Double = 6
}

/// A shape being drawn from a press-drag, before it becomes a committed element.
private struct Draft {
    let tool: EditorModel.Tool
    var start: Point
    var current: Point
    var points: [Point]
    /// The redaction style captured when the draft began, so a mid-draw style change can't
    /// retroactively alter the mark being drawn.
    let redactionStyle: RedactionStyle

    /// The element geometry for this draft, or nil when it's too small / not a shape tool.
    var kind: AnnotationElement.Kind? {
        switch tool {
        case .arrow: return hasMinimumLength ? .arrow(from: start, to: current) : nil
        case .line: return hasMinimumLength ? .line(from: start, to: current) : nil
        case .rectangle: return hasMinimumArea ? .rectangle(rectBetween(start, current)) : nil
        case .ellipse: return hasMinimumArea ? .ellipse(rectBetween(start, current)) : nil
        case .freehand: return points.count > 1 ? .freehand(points: points) : nil
        case .highlight: return hasMinimumArea ? .highlight(rectBetween(start, current)) : nil
        case .redact: return hasMinimumArea ? .redaction(rectBetween(start, current), style: redactionStyle) : nil
        case .select, .text, .step: return nil
        }
    }

    /// Whether the drag spans far enough to commit a one-dimensional mark (line/arrow).
    private var hasMinimumLength: Bool { start.distance(to: current) >= 3 }
    /// Whether the drag spans far enough in both axes to commit an area mark (rect/ellipse).
    private var hasMinimumArea: Bool { abs(current.x - start.x) >= 3 && abs(current.y - start.y) >= 3 }
}

/// An in-progress move or resize of the selected element.
private struct DragSession {
    enum Mode { case move; case resize(Handle) }
    let id: ElementID
    let mode: Mode
    let start: Point
    var current: Point

    var transform: Transform {
        let dx = current.x - start.x
        let dy = current.y - start.y
        switch mode {
        case .move: return .move(dx: dx, dy: dy)
        case let .resize(handle): return .resize(handle: handle, dx: dx, dy: dy)
        }
    }
}
