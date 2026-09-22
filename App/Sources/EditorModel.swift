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

    /// The annotation tools the palette offers: vector marks + step markers (LIG-9), the
    /// highlighter and region redaction (LIG-12), plus crop (LIG-10).
    enum Tool: String, CaseIterable, Identifiable {
        case select, arrow, line, rectangle, ellipse, freehand, text, step, highlight, focus, redact, crop
        var id: String { rawValue }

        /// SF Symbol for the palette button.
        var symbol: String { info.symbol }
        /// Short name, shown the moment the pointer is over the button.
        var title: String { info.title }
        /// Longer description, for assistive technology.
        var help: String { info.help }

        /// Single source for the per-tool palette metadata, so symbol, title, and help can't
        /// drift out of a case each (one switch, not one per attribute).
        private var info: (symbol: String, title: String, help: String) {
            switch self {
            case .select: return ("arrow.up.left.and.arrow.down.right", "Select", "Select, move, and resize")
            case .arrow: return ("arrow.up.right", "Arrow", "Arrow")
            case .line: return ("line.diagonal", "Line", "Line")
            case .rectangle: return ("rectangle", "Rectangle", "Rectangle")
            case .ellipse: return ("circle", "Ellipse", "Ellipse")
            case .freehand: return ("scribble", "Freehand", "Freehand")
            case .text: return ("textformat", "Text", "Text")
            case .step: return ("1.circle.fill", "Step Marker", "Step marker")
            case .highlight: return ("highlighter", "Highlighter", "Highlighter — translucent wash, doesn't hide content")
            case .focus: return ("rectangle.center.inset.filled", "Focus", "Focus — dim everything outside the areas you draw")
            case .redact: return ("eye.slash", "Redact", "Redact a region (pixelate, blur, or blackout)")
            case .crop: return ("crop", "Crop", "Crop")
            }
        }
    }

    private(set) var document: AnnotationDocument
    private let copy: (AnnotationDocument) -> Void
    private let done: (AnnotationDocument) -> Void
    private let saveAs: (AnnotationDocument) -> Void

    var tool: Tool = .select {
        didSet {
            if tool != .select { endTextEditing() }
            if tool == .redact {
                // Opening the redact tool always starts a new redaction at the default style,
                // whatever the last one (or a selected one) was showing in the picker.
                document.select(nil)
                redactionStyle = Self.defaultRedactionStyle
            }
            if tool == .crop {
                // Enter crop mode seeded with the current crop (or the whole image), and
                // drop any element selection — crop has its own rectangle, not an element.
                document.select(nil)
                cropDraft = documentCropFrame
            } else if oldValue == .crop {
                cropDraft = nil
            }
        }
    }

    /// Which style a new redaction uses. **Defaults to `pixelate`** each time the redact tool
    /// is opened (spec 0004). Pixelate merely obscures — only `blackout` is secure redaction
    /// (story 24) — so the toolbar keeps its "not secure" warning on it and on `blur`.
    private(set) var redactionStyle: RedactionStyle = EditorModel.defaultRedactionStyle

    /// How hard a new (or the selected) `blur`/`pixelate` redaction obscures, `0...1`.
    private(set) var redactionStrength: Double = EditorModel.lastRedactionStrength

    /// Which style a new (or the selected) arrow is drawn in. Starts at the last style used.
    private(set) var arrowStyle: ArrowStyle = EditorModel.lastArrowStyle

    private static let defaultRedactionStyle: RedactionStyle = .pixelate

    /// The last intensity used, shared by every editor this launch so obscuring a run of
    /// captures doesn't mean re-setting the slider each time. Not persisted across launches.
    private static var lastRedactionStrength: Double = RedactionStyle.defaultStrength

    /// The last arrow style used, remembered across launches.
    private static var lastArrowStyle: ArrowStyle {
        get {
            let stored = UserDefaults.standard.integer(forKey: arrowStyleDefaultsKey)
            return ArrowStyle.allCases.indices.contains(stored) ? ArrowStyle.allCases[stored] : .standard
        }
        set { UserDefaults.standard.set(ArrowStyle.allCases.firstIndex(of: newValue) ?? 0, forKey: arrowStyleDefaultsKey) }
    }
    private static let arrowStyleDefaultsKey = "editor.lastArrowStyle"

    /// Flattened backdrops and obscured patches for the blur/pixelate previews. A cache,
    /// not state — it must not trigger view updates when it fills during a draw.
    @ObservationIgnored private let redactionPreviews = RedactionPreviewCache()

    /// The style applied to new marks, kept in sync with the selection while one exists.
    private(set) var style: Style = .default

    /// The text element currently being edited (from placing or double-clicking a label).
    private(set) var editingTextID: ElementID?

    /// Current aspect-fit scale, pushed in by the view; sizes the handle grab radius.
    var viewScale: Double = 1

    // In-progress interaction (nil when idle). Exactly one is ever non-nil.
    private var draft: Draft?
    private var drag: DragSession?
    private var cropSession: CropSession?
    private var gestureActive = false

    /// The crop rectangle being edited while the crop tool is active (image space).
    /// Committed to the document live on each drag; `nil` outside crop mode.
    private(set) var cropDraft: Rect?

    init(
        document: AnnotationDocument,
        copy: @escaping (AnnotationDocument) -> Void,
        done: @escaping (AnnotationDocument) -> Void,
        saveAs: @escaping (AnnotationDocument) -> Void
    ) {
        self.document = document
        self.copy = copy
        self.done = done
        self.saveAs = saveAs
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
    var displayElements: [AnnotationElement] { displayDocument.elements }

    /// The document as currently shown: the real one, plus any in-progress drag.
    private var displayDocument: AnnotationDocument {
        guard let drag else { return document }
        var preview = document
        preview.transform(drag.id, by: drag.transform)
        return preview
    }

    /// The shape being drawn right now, if any (drawn on top of `displayElements`).
    var draftElement: AnnotationElement? {
        guard let draft, let kind = draft.kind else { return nil }
        return AnnotationElement(kind: kind, style: style)
    }

    /// The real obscured pixels for the blur/pixelate redaction at `index` of
    /// `displayElements` — cut by the same code the export uses, so the canvas shows
    /// exactly what will be flattened. `nil` for anything else (including `blackout`).
    func redactionPatch(at index: Int) -> RedactionPatch? {
        redactionPreviews.patch(at: index, in: displayDocument)
    }

    /// The obscured pixels for a redaction still being drawn; it will land on top.
    var draftRedactionPatch: RedactionPatch? {
        guard let draftElement else { return nil }
        return redactionPreviews.patch(for: draftElement, at: displayElements.count, in: displayDocument)
    }

    /// The bounding box (image space) to hang selection handles on, or nil. Lines and
    /// arrows are grabbed by their endpoints instead (see `selectionEndpoints`).
    var selectionBox: Rect? {
        guard let kind = selectedKindAtRest, kind.endpointHandles == nil else { return nil }
        if case .text = kind { return nil }   // a label has its own chrome (`textBox`)
        if kind.focusRect != nil { return nil }   // so does a focus area (`focusBox`)
        return kind.boundingBox
    }

    /// The selected focus area, for its solid rounded selection edge and handles (LIG-47).
    var focusBox: Rect? {
        selectedKindAtRest?.focusRect
    }

    /// The box of the selected label (or the one being typed into), for its border and its
    /// three handles (LIG-47); nil while a gesture reshapes it or when no label is selected.
    var textBox: Rect? {
        guard drag == nil, draft == nil, let id = editingTextID ?? document.selectedID,
              case let .text(_, box)? = document.element(id: id)?.kind else { return nil }
        return box.standardized
    }

    /// The endpoint handles (image space) of a selected line or arrow, or nil.
    var selectionEndpoints: [Point]? {
        selectedKindAtRest?.endpointHandles?.map(\.point)
    }

    /// The selected element's geometry, while no gesture is reshaping the canvas.
    private var selectedKindAtRest: AnnotationElement.Kind? {
        guard drag == nil, draft == nil, let id = document.selectedID else { return nil }
        return document.element(id: id)?.kind
    }

    /// The style controls the toolbar shows (LIG-46): the selected element's, else the active
    /// drawing tool's; none for Select with nothing selected, or for Crop.
    var styleFields: StyleFields {
        // A selected mark shows its own controls, whichever tool picked it up.
        if tool != .crop, let kind = selectedKind { return StyleFields.fields(for: kind) }
        switch tool {
        case .arrow: return [.color, .strokeWidth, .arrowStyle]
        case .line, .rectangle, .ellipse, .freehand: return [.color, .strokeWidth]
        case .text, .step: return [.color, .fontSize]
        case .highlight: return [.color]
        case .redact: return [.redaction]
        case .focus, .crop: return []
        case .select: return selectedKind.map(StyleFields.fields(for:)) ?? []
        }
    }

    private var selectedKind: AnnotationElement.Kind? {
        document.selectedID.flatMap { document.element(id: $0)?.kind }
    }

    // MARK: - Crop (stories 36–38)

    /// Whether the crop tool is active (its rectangle and handles are shown).
    var isCropping: Bool { tool == .crop }

    /// The crop frame to visualize (image space), or `nil` when the full image shows.
    /// In crop mode this is the live draft; otherwise it's the applied crop, but only
    /// when it actually trims the image — a crop equal to the full frame dims nothing.
    var cropFrame: Rect? {
        if isCropping { return cropDraft }
        return hasEffectiveCrop ? document.cropRect : nil
    }

    /// Whether a crop is in effect and can be reversed to the full frame.
    var canResetCrop: Bool { hasEffectiveCrop }

    /// Reverses the crop, restoring the full frame with every element intact. Recorded as
    /// an undoable command (setting the crop to the whole image), so ⌘Z reverses it too.
    func resetCrop() {
        document.applyCrop(document.imageBounds)
        syncCropDraft()
    }

    /// The document's current crop frame (the crop rect, or the whole image), standardized.
    /// Reuses the document's `visibleFrame` seam rather than re-deriving it.
    private var documentCropFrame: Rect { document.visibleFrame.standardized }

    /// Whether the applied crop actually trims the image (vs. equalling the full frame).
    private var hasEffectiveCrop: Bool {
        guard let crop = document.cropRect else { return false }
        return crop.standardized != document.imageBounds.standardized
    }

    /// Re-points the live crop draft at whatever the document now shows, so the overlay can't
    /// go stale when a command changes the crop out from under it (undo, redo, reset).
    private func syncCropDraft() {
        if isCropping { cropDraft = documentCropFrame }
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

    /// Picks the arrow style for new arrows and restyles a selected arrow in place.
    func setArrowStyle(_ arrowStyle: ArrowStyle) {
        self.arrowStyle = arrowStyle
        Self.lastArrowStyle = arrowStyle
        if let id = document.selectedID { document.setArrowStyle(id, arrowStyle) }
    }

    func setRedactionStyle(_ redactionStyle: RedactionStyle) {
        self.redactionStyle = redactionStyle
        applyRedactionToSelection()
    }

    func setRedactionStrength(_ strength: Double) {
        redactionStrength = strength
        applyRedactionToSelection()
    }

    private func applyRedactionToSelection() {
        Self.lastRedactionStrength = redactionStrength
        if let id = document.selectedID {
            document.setRedaction(id, style: redactionStyle, strength: redactionStrength)
        }
    }

    /// Closes the current style-edit coalescing run so the next drag is a distinct undo
    /// step. The view calls this when a slider ends editing (story 35).
    func commitStyleEdit() { document.endCoalescing() }

    private func applyStyleToSelection() {
        if let id = document.selectedID { document.setStyle(id, style) }
    }

    // MARK: - History & output

    func undo() { endTextEditing(); document.undo(); syncCropDraft() }
    func redo() { endTextEditing(); document.redo(); syncCropDraft() }
    func deleteSelection() {
        guard let id = document.selectedID else { return }
        endTextEditing()
        document.delete(id)
    }
    func copyToClipboard() { endTextEditing(); copy(document) }

    /// The finishing gesture (⌘S, LIG-23): copy the flattened document and close the editor. No
    /// file is written — saving to disk stays on Save As….
    func copyAndClose() { endTextEditing(); done(document) }

    /// Save to disk choosing location and format (stories 41–42).
    func saveToDiskAs() { endTextEditing(); saveAs(document) }

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
        guard tool != .crop else { return false }
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
        // A label opened by the Text tool is let go when its typing ends; one the user selected
        // (then double-clicked, or clicked again) stays selected.
        if releasesTextWhenDone, document.selectedID == id { document.select(nil) }
        releasesTextWhenDone = false
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
        case .crop:
            beginCropGesture(at: point)
        case .text:
            if beginHandleDrag(at: point) { return }
            // The Text tool on a finished label reopens it instead of starting a new one.
            if let hit = document.elementID(at: point), isText(hit) {
                document.select(hit)
                syncStyleToSelection()
                editingTextID = hit
                releasesTextWhenDone = true
                return
            }
            startDraft(at: point)
        case .arrow, .line, .rectangle, .ellipse, .freehand, .step, .highlight, .focus, .redact:
            // The tool stays active after a mark is placed (the user switches tools, not us). A
            // press on the selection's handles reshapes it; a press on a mark picks it up —
            // selects it and moves it — so marks can be selected again with any tool (LIG-47);
            // a press anywhere else starts a new mark.
            if beginHandleDrag(at: point) { return }
            if let hit = document.grabbableElementID(at: point) {
                document.select(hit)
                syncStyleToSelection()
                drag = DragSession(id: hit, mode: .move, start: point, current: point)
                return
            }
            startDraft(at: point)
        }
    }

    private func move(to point: Point) {
        if let cropSession {
            cropDraft = cropSession.rect(at: point, bounds: document.imageBounds)
        } else if drag != nil {
            drag?.current = point
        } else if draft != nil {
            draft?.current = point
            draft?.points.append(point)
        }
    }

    private func end(at point: Point) {
        defer { draft = nil; drag = nil; cropSession = nil }

        if let cropSession {
            let rect = cropSession.rect(at: point, bounds: document.imageBounds)
            // Ignore an accidental click/tiny drag so it can't collapse the crop to nothing;
            // a real drag commits the crop as one undo step.
            if rect.width >= Self.minCropSize, rect.height >= Self.minCropSize {
                cropDraft = rect
                document.applyCrop(rect)
            }
            return
        }
        if let drag {
            let reopen = reopensText
            reopensText = false
            // A click (no drag) on the label that was already selected: edit it again.
            if reopen, drag.start.distance(to: point) < 2 {
                editingTextID = drag.id
                return
            }
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
            // A new mark is not selected: selecting is the user's own act. A click that drew
            // nothing lets go of whatever was selected.
            if let kind = draft.kind {
                document.add(AnnotationElement(kind: kind, style: style))
            } else {
                document.select(nil)
            }
        }
    }

    // MARK: - Select / move / resize (stories 29–31)

    private func beginSelectGesture(at point: Point) {
        if beginHandleDrag(at: point) { return }
        if let hit = document.elementID(at: point) {
            // A click on a label that is already selected opens it for editing (see `end`).
            reopensText = document.selectedID == hit && isText(hit)
            document.select(hit)
            drag = DragSession(id: hit, mode: .move, start: point, current: point)
        } else {
            document.select(nil)
        }
    }

    /// Starts a reshape/resize drag if `point` is on one of the selected element's
    /// handles. Returns false (and starts nothing) otherwise.
    private func beginHandleDrag(at point: Point) -> Bool {
        guard let id = document.selectedID, let kind = document.element(id: id)?.kind else { return false }
        if let endpoints = kind.endpointHandles {
            // Later handles win a tie, so a bend resting near an endpoint stays grabbable.
            guard let hit = endpoints.last(where: { isWithinGrabRadius(point, of: $0.point) }) else { return false }
            drag = DragSession(id: id, mode: .reshape(hit.handle), start: point, current: point)
        } else {
            // A label offers only its side edges and its bottom-right corner (LIG-47).
            let offered: [Handle]
            if case .text = kind { offered = AnnotationDocument.textHandles } else { offered = Handle.allCases }
            guard let handle = handle(at: point, of: kind.boundingBox, among: offered) else { return false }
            drag = DragSession(id: id, mode: .resize(handle), start: point, current: point)
        }
        return true
    }

    /// Starts a crop drag: grab a handle to resize, press inside to move, or press
    /// outside to draw a fresh rectangle. The current draft (or the whole image) is the
    /// rect being adjusted.
    private func beginCropGesture(at point: Point) {
        let rect = cropDraft ?? document.imageBounds
        if let handle = cropHandle(at: point, of: rect) {
            cropSession = CropSession(mode: .resize(handle), start: point, origin: rect)
        } else if rect.contains(point) {
            cropSession = CropSession(mode: .move, start: point, origin: rect)
        } else {
            cropSession = CropSession(mode: .draw, start: point, origin: rect)
        }
    }

    /// The resize handle near `point`, if the point is within a grab radius of one.
    private func handle(at point: Point, of box: Rect, among handles: [Handle] = Handle.allCases) -> Handle? {
        handles.first { isWithinGrabRadius(point, of: handlePoint($0, in: box)) }
    }

    private func isWithinGrabRadius(_ point: Point, of handle: Point) -> Bool {
        let tolerance = max(Self.handleRadius / max(viewScale, 0.0001), 4)
        return abs(handle.x - point.x) <= tolerance && abs(handle.y - point.y) <= tolerance
    }

    // MARK: - Placement (stories 20, 25)

    /// Starts drawing a new mark with the active tool at `point`.
    private func startDraft(at point: Point) {
        draft = Draft(
            tool: tool, start: point, current: point, points: [point], arrowStyle: arrowStyle,
            redactionStyle: redactionStyle, redactionStrength: redactionStrength,
            redactionSeed: UInt64.random(in: .min ... .max)
        )
    }

    /// Whether the label being typed was opened by the Text tool (placed, or clicked with it),
    /// rather than selected by the user — it is deselected when the typing ends.
    private var releasesTextWhenDone = false

    /// The crop handle under `point`: a corner near its point, else an edge anywhere along it
    /// (LIG-47), so the whole border can be grabbed, not only its midpoint.
    private func cropHandle(at point: Point, of rect: Rect) -> Handle? {
        let corners: [Handle] = [.topLeft, .topRight, .bottomLeft, .bottomRight]
        if let corner = handle(at: point, of: rect, among: corners) { return corner }
        let box = rect.standardized
        let tolerance = max(Self.handleRadius / max(viewScale, 0.0001), 4)
        let withinX = point.x >= box.minX - tolerance && point.x <= box.maxX + tolerance
        let withinY = point.y >= box.minY - tolerance && point.y <= box.maxY + tolerance
        if withinY, abs(point.x - box.minX) <= tolerance { return .left }
        if withinY, abs(point.x - box.maxX) <= tolerance { return .right }
        if withinX, abs(point.y - box.minY) <= tolerance { return .top }
        if withinX, abs(point.y - box.maxY) <= tolerance { return .bottom }
        return nil
    }

    /// The pointer while cropping (LIG-47): a resize arrow over the border, an open hand over
    /// the crop (a closed one while moving it), a crosshair outside to draw a new one; nil when
    /// not cropping, so the canvas keeps the ordinary arrow.
    func cropCursor(at point: Point) -> PointerCursor? {
        guard isCropping else { return nil }
        if let cropSession {
            switch cropSession.mode {
            case .move: return .closedHand
            case let .resize(handle): return .resize(handle)
            case .draw: return .crosshair
            }
        }
        let rect = cropDraft ?? document.imageBounds
        if let handle = cropHandle(at: point, of: rect) { return .resize(handle) }
        return rect.contains(point) ? .openHand : .crosshair
    }

    /// Set when a Select click lands on the label that was already selected: if the press ends
    /// without a drag, the label opens for editing.
    private var reopensText = false

    private func isText(_ id: ElementID) -> Bool {
        if case .text? = document.element(id: id)?.kind { return true }
        return false
    }

    private func placeText(at point: Point) {
        // A caret-sized box at the click that grows as the label is typed (LIG-47).
        let box = TextLayout.box(for: "", fontSize: style.fontSize, origin: point)
        let id = document.add(AnnotationElement(kind: .text("", box: box), style: style))
        // Selected only while it is typed (the style controls apply to it), then let go.
        document.select(id)
        editingTextID = id
        releasesTextWhenDone = true
    }

    private func placeStepMarker(at point: Point) {
        let radius = max(style.fontSize, 14)
        document.add(AnnotationElement(kind: .stepMarker(number: 0, center: point, radius: radius), style: style))
        document.select(nil)
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
        // Likewise the arrow-style picker and redaction controls show the selection's own values.
        switch element.kind {
        case let .arrow(_, _, _, arrowStyle):
            self.arrowStyle = arrowStyle
        case let .redaction(_, redactionStyle, strength, _):
            self.redactionStyle = redactionStyle
            redactionStrength = strength
        default:
            break
        }
    }

    private static let handleRadius: Double = 6
    /// Smallest crop a drag can commit, in image pixels — below this the drag is ignored.
    private static let minCropSize: Double = 8
}

/// A shape being drawn from a press-drag, before it becomes a committed element.
private struct Draft {
    let tool: EditorModel.Tool
    var start: Point
    var current: Point
    var points: [Point]
    /// The arrow and redaction settings captured when the draft began, so a mid-draw change
    /// can't retroactively alter the mark being drawn. The seed is rolled once per draft so
    /// the scramble holds still while the region is dragged out.
    let arrowStyle: ArrowStyle
    let redactionStyle: RedactionStyle
    let redactionStrength: Double
    let redactionSeed: UInt64

    /// The element geometry for this draft, or nil when it's too small / not a shape tool.
    var kind: AnnotationElement.Kind? {
        switch tool {
        case .arrow:
            guard hasMinimumLength else { return nil }
            let bend = arrowStyle.isBendable ? defaultArrowBend(from: start, to: current) : nil
            return .arrow(from: start, to: current, bend: bend, style: arrowStyle)
        case .line: return hasMinimumLength ? .line(from: start, to: current) : nil
        case .rectangle: return hasMinimumArea ? .rectangle(rectBetween(start, current)) : nil
        case .ellipse: return hasMinimumArea ? .ellipse(rectBetween(start, current)) : nil
        case .freehand: return points.count > 1 ? .freehand(points: points) : nil
        case .highlight: return hasMinimumArea ? .highlight(rectBetween(start, current)) : nil
        case .focus: return hasMinimumArea ? .focus(rectBetween(start, current)) : nil
        case .redact:
            guard hasMinimumArea else { return nil }
            return .redaction(rectBetween(start, current), style: redactionStyle,
                              strength: redactionStrength, seed: redactionSeed)
        case .select, .text, .step, .crop: return nil
        }
    }

    /// Whether the drag spans far enough to commit a one-dimensional mark (line/arrow).
    private var hasMinimumLength: Bool { start.distance(to: current) >= 3 }
    /// Whether the drag spans far enough in both axes to commit an area mark (rect/ellipse).
    private var hasMinimumArea: Bool { abs(current.x - start.x) >= 3 && abs(current.y - start.y) >= 3 }
}

/// An in-progress move or resize of the selected element.
private struct DragSession {
    enum Mode { case move; case resize(Handle); case reshape(EndpointHandle) }
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
        case let .reshape(handle): return .reshape(handle: handle, dx: dx, dy: dy)
        }
    }
}

/// Keeps the blur/pixelate canvas preview cheap. Flattening what lies beneath a redaction
/// is the costly step, so each redaction's backdrop is kept until the elements under it (or
/// the crop) change; cutting the obscured patch is fast and is redone only when the
/// redaction itself changes — so dragging one out re-cuts per frame but never re-flattens.
@MainActor
private final class RedactionPreviewCache {
    private struct Entry {
        let below: [AnnotationElement]
        let frame: Rect
        let backdrop: RedactionBackdrop
        var kind: AnnotationElement.Kind?
        var patch: RedactionPatch?
    }

    /// Keyed by z-order index; `elements.count` is the redaction still being drawn.
    private var entries: [Int: Entry] = [:]

    func patch(at index: Int, in document: AnnotationDocument) -> RedactionPatch? {
        guard document.elements.indices.contains(index) else { return nil }
        return patch(for: document.elements[index], at: index, in: document)
    }

    func patch(for element: AnnotationElement, at index: Int, in document: AnnotationDocument) -> RedactionPatch? {
        // Slots past the top of the z-order (after a delete or undo) would otherwise pin a
        // full-size bitmap each for the life of the editor.
        entries = entries.filter { $0.key <= document.elements.count }
        guard case let .redaction(rect, style, strength, seed) = element.kind, style != .blackout else {
            entries[index] = nil  // don't hold a full-size bitmap for a slot that stopped needing one
            return nil
        }
        let below = Array(document.elements.prefix(index))
        var entry: Entry
        if let cached = entries[index], cached.below == below, cached.frame == document.visibleFrame {
            entry = cached
        } else {
            guard let backdrop = redactionBackdrop(document, below: index) else { return nil }
            entry = Entry(below: below, frame: document.visibleFrame, backdrop: backdrop)
        }
        if entry.kind != element.kind {
            entry.kind = element.kind
            entry.patch = entry.backdrop.patch(rect, style: style, strength: strength, seed: seed)
        }
        entries[index] = entry
        return entry.patch
    }
}

/// An in-progress crop-rectangle drag: drawing a fresh rect, moving it, or resizing a
/// handle. The result is always clamped to the image so the crop never leaves the frame.
private struct CropSession {
    enum Mode { case draw, move, resize(Handle) }
    let mode: Mode
    let start: Point
    /// The crop rect at the moment the drag began (unused when drawing fresh).
    let origin: Rect

    /// The crop rect for the current pointer location, clamped to `bounds`.
    func rect(at point: Point, bounds: Rect) -> Rect {
        switch mode {
        case .draw:
            return bounds.intersection(rectBetween(start, point))
                ?? Rect(x: point.x, y: point.y, width: 0, height: 0)
        case .move:
            // Slide the whole rect, keeping its size and pinning it inside the image.
            let dx = point.x - start.x
            let dy = point.y - start.y
            let x = min(max(origin.minX + dx, bounds.minX), bounds.maxX - origin.width)
            let y = min(max(origin.minY + dy, bounds.minY), bounds.maxY - origin.height)
            return Rect(x: x, y: y, width: origin.width, height: origin.height)
        case let .resize(handle):
            // Reuse the exact edge math elements use, then clip to the image.
            let resized = origin.resized(handle: handle, dx: point.x - start.x, dy: point.y - start.y)
            return bounds.intersection(resized) ?? origin
        }
    }
}
