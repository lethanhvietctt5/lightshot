import SwiftUI
import LightshotKit

/// Interaction state for the pre-capture selection overlay, kept out of the SwiftUI view so the
/// view stays a thin projection of it — the same split the editor uses (`EditorModel`).
///
/// All geometry is in **screen points** (top-left origin) at 1:1 with the overlay window, so no
/// projection is needed; the pixel-dimension readout scales points by the display's backing scale.
/// Selecting reuses the domain's pure geometry (`rectBetween`) — the overlay never reinvents the
/// arithmetic the editor already relies on.
///
/// **Releasing the drag confirms** (LIG-23): there is no adjust-then-Return step, so the capture
/// reaches the editor in one gesture. A release too small to be a real selection resolves nothing
/// and leaves the overlay up for another try.
@MainActor
@Observable
final class SelectionOverlayModel {

    /// Screen points → native pixels, for the dimension readout (story 3).
    private let pixelScale: Double
    private let finish: (CaptureRegion?) -> Void

    /// The current selection in screen points, or `nil` before the first drag. Kept standardized
    /// only when read out; in-flight it may be inverted (dragging up/left).
    private(set) var selection: Rect?

    private var draftStart: Point?

    init(pixelScale: Double, finish: @escaping (CaptureRegion?) -> Void) {
        self.pixelScale = pixelScale
        self.finish = finish
    }

    // MARK: - Derived state for the view

    /// Whether a selection large enough to capture exists. The floor keeps a stray click (or a
    /// jittery one) from confirming a useless few-pixel capture on release.
    var hasSelection: Bool {
        guard let s = selection?.standardized else { return false }
        return s.width >= Self.minimumSide && s.height >= Self.minimumSide
    }

    /// The selection's pixel dimensions for the live readout, or `nil` when there's nothing yet.
    var pixelSize: (width: Int, height: Int)? {
        guard let s = selection, hasSelection else { return nil }
        return (Int((s.width * pixelScale).rounded()), Int((s.height * pixelScale).rounded()))
    }

    // MARK: - Drag gesture (screen-point coordinates)

    func dragChanged(to point: Point) {
        if let start = draftStart {
            selection = rectBetween(start, point)
        } else {
            draftStart = point
            selection = Rect(origin: point, size: Size(width: 0, height: 0))
        }
    }

    /// Releasing the mouse confirms the selection. A release with nothing worth capturing clears
    /// the draft and keeps the overlay up.
    func dragEnded(to point: Point) {
        dragChanged(to: point)
        draftStart = nil
        if hasSelection {
            confirm()
        } else {
            selection = nil
        }
    }

    // MARK: - Resolution

    /// Confirm the selection (mouse-up; Return mid-drag also lands here): resolves to a
    /// `CaptureRegion`. A no-op with no selection.
    func confirm() {
        guard let selection, hasSelection else { return }
        finish(.rect(selection.standardized))
    }

    /// Cancel (Escape): resolves to `nil`, a silent no-op with no capture (story 5).
    func cancel() { finish(nil) }

    /// The smallest side, in screen points, that counts as a real selection.
    private static let minimumSide: Double = 4
}

/// The adjustable Capture Area selection on one display (spec 0016, *Adjust the area before
/// capturing*): releasing the drag does **not** confirm. The selection stays editable — drag inside
/// to move it, a handle to resize it, the arrow keys to nudge it, anywhere outside to draw a
/// different one — until the Capture button (or Return, via the hosting window) resolves it.
///
/// The geometry is the domain's `EditableSelection`, as in `RecordingOverlayModel`, always freeform.
/// This model adds what needs a screen: the click-vs-drag threshold, the pointer, and resolution.
/// Coordinates are this display's screen points (top-left origin) at 1:1 with its overlay window;
/// `OverlaySelectionController` shifts the result into global points and keeps one selection across
/// displays.
@MainActor
@Observable
final class AdjustableSelectionOverlayModel {
    private let pixelScale: Double
    private let finish: (CaptureRegion?) -> Void
    /// A new area started drawing here, so the controller sets every other display's aside (story 24).
    var onDrawBegan: () -> Void = {}
    /// That redraw ended: `kept` when it left a real area; otherwise the controller puts the area
    /// it set aside back, so a slip on another display costs nothing either.
    var onDrawEnded: (_ kept: Bool) -> Void = { _ in }

    private(set) var selection: EditableSelection
    /// What the pointer should look like where it is: a crosshair over empty screen, an open hand
    /// inside the selection, a closed hand while moving it, a resize cursor over a handle, the
    /// arrow over the Capture button.
    private(set) var cursor: PointerCursor = .crosshair
    private(set) var isDragging = false

    private var dragStart: Point?
    private var isDrawing = false
    /// The selection before a redraw began, put back if the redraw comes to nothing — a slip never
    /// costs the area the user already adjusted.
    private var beforeRedraw: EditableSelection?

    init(bounds: Rect, pixelScale: Double, finish: @escaping (CaptureRegion?) -> Void) {
        self.selection = EditableSelection(bounds: bounds)
        self.pixelScale = pixelScale
        self.finish = finish
    }

    // MARK: - Derived state for the view

    var hasSelection: Bool { selection.hasSelection }

    /// Handles and the Capture button show for a settled selection, never mid-drag.
    var showsControls: Bool { hasSelection && !isDragging }

    var pixelSize: (width: Int, height: Int)? {
        guard let rect = selection.rect, hasSelection else { return nil }
        return (Int((rect.width * pixelScale).rounded()), Int((rect.height * pixelScale).rounded()))
    }

    // MARK: - Pointer

    func hover(at point: Point) {
        if !isDragging { cursor = cursor(at: point) }
    }

    /// The pointer left the canvas — for the Capture button or another display.
    func hoverEnded() {
        if !isDragging { cursor = .arrow }
    }

    private func cursor(at point: Point) -> PointerCursor {
        PointerCursor(selection.dragKind(at: point))
    }

    /// Only movement past a few points becomes a drag, so a click outside the selection leaves it
    /// alone (story 23) and a click with nothing selected leaves the overlay waiting (story 10).
    func dragChanged(to point: Point) {
        guard let start = dragStart else {
            dragStart = point
            return
        }
        if !isDragging {
            guard start.distance(to: point) >= Self.dragThreshold else { return }
            isDragging = true
            let kind = selection.dragKind(at: start)
            cursor = PointerCursor(kind, grabbing: true)
            if kind == .draw {
                isDrawing = true
                beforeRedraw = hasSelection ? selection : nil
                onDrawBegan()
            }
            selection.dragBegan(at: start)
        }
        selection.dragChanged(to: point)
    }

    func dragEnded(at point: Point) {
        defer { dragStart = nil; isDragging = false; isDrawing = false; beforeRedraw = nil }
        if isDragging {
            selection.dragEnded(at: point)
            if isDrawing {
                let kept = hasSelection
                if !kept, let beforeRedraw { selection = beforeRedraw }
                onDrawEnded(kept)
            }
        }
        cursor = cursor(at: point)
    }

    /// Arrow keys: move by 1 px; with ⇧, grow or shrink from the top-left by 10 px (native pixels,
    /// like the readout), as in the recording overlay.
    func arrow(dx: Double, dy: Double, shift: Bool) {
        guard hasSelection else { return }
        if shift {
            selection.resize(dw: dx * 10 / pixelScale, dh: dy * 10 / pixelScale)
        } else {
            selection.nudge(dx: dx / pixelScale, dy: dy / pixelScale)
        }
    }

    /// Another display started drawing: there is only ever one area to capture.
    func clearSelection() {
        selection = EditableSelection(bounds: selection.bounds)
    }

    /// Another display's redraw came to nothing: the area set aside for it comes back.
    func restore(_ selection: EditableSelection) {
        self.selection = selection
    }

    // MARK: - Resolution

    /// Capture (the button, or Return): resolves to the selection. A no-op with nothing selected
    /// or mid-drag.
    func confirm() {
        guard let rect = selection.rect, hasSelection, !isDragging else { return }
        finish(.rect(rect))
    }

    /// Cancel (Escape): resolves to `nil`, a silent no-op with no capture.
    func cancel() { finish(nil) }

    private static let dragThreshold: Double = 3
}
