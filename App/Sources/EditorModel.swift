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

    /// The annotation tools the palette offers (LIG-9 scope: vector marks + step markers).
    enum Tool: String, CaseIterable, Identifiable {
        case select, arrow, line, rectangle, ellipse, freehand, text, step
        var id: String { rawValue }

        var symbol: String {
            switch self {
            case .select: return "arrow.up.left.and.arrow.down.right"
            case .arrow: return "arrow.up.right"
            case .line: return "line.diagonal"
            case .rectangle: return "rectangle"
            case .ellipse: return "circle"
            case .freehand: return "scribble"
            case .text: return "textformat"
            case .step: return "1.circle.fill"
            }
        }

        var help: String {
            switch self {
            case .select: return "Select, move, and resize"
            case .arrow: return "Arrow"
            case .line: return "Line"
            case .rectangle: return "Rectangle"
            case .ellipse: return "Ellipse"
            case .freehand: return "Freehand"
            case .text: return "Text"
            case .step: return "Step marker"
            }
        }
    }

    private(set) var document: AnnotationDocument
    private let copy: (AnnotationDocument) -> Void

    var tool: Tool = .select { didSet { if tool != .select { endTextEditing() } } }

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
    func setFontSize(_ size: Double) { style.fontSize = size; applyStyleToSelection() }

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
        case .arrow, .line, .rectangle, .ellipse, .freehand, .text, .step:
            draft = Draft(tool: tool, start: point, current: point, points: [point])
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
        if let id = document.selectedID, let element = document.element(id: id) {
            style = element.style
        }
    }

    private static let handleRadius: Double = 6
}

/// Where the eight resize handles sit on a bounding box, in image space.
func handlePoint(_ handle: Handle, in box: Rect) -> Point {
    let b = box.standardized
    switch handle {
    case .topLeft: return Point(x: b.minX, y: b.minY)
    case .top: return Point(x: b.midX, y: b.minY)
    case .topRight: return Point(x: b.maxX, y: b.minY)
    case .right: return Point(x: b.maxX, y: b.midY)
    case .bottomRight: return Point(x: b.maxX, y: b.maxY)
    case .bottom: return Point(x: b.midX, y: b.maxY)
    case .bottomLeft: return Point(x: b.minX, y: b.maxY)
    case .left: return Point(x: b.minX, y: b.midY)
    }
}

/// A shape being drawn from a press-drag, before it becomes a committed element.
private struct Draft {
    let tool: EditorModel.Tool
    var start: Point
    var current: Point
    var points: [Point]

    /// The element geometry for this draft, or nil when it's too small / not a shape tool.
    var kind: AnnotationElement.Kind? {
        switch tool {
        case .arrow: return committedLength ? .arrow(from: start, to: current) : nil
        case .line: return committedLength ? .line(from: start, to: current) : nil
        case .rectangle: return committedArea ? .rectangle(rectBetween(start, current)) : nil
        case .ellipse: return committedArea ? .ellipse(rectBetween(start, current)) : nil
        case .freehand: return points.count > 1 ? .freehand(points: points) : nil
        case .select, .text, .step: return nil
        }
    }

    private var committedLength: Bool { start.distance(to: current) >= 3 }
    private var committedArea: Bool { abs(current.x - start.x) >= 3 && abs(current.y - start.y) >= 3 }
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

/// The axis-aligned rect spanned by two corner points.
func rectBetween(_ a: Point, _ b: Point) -> Rect {
    Rect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
}
