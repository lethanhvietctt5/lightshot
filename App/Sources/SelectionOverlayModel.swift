import SwiftUI
import LightshotKit

/// Interaction state for the pre-capture selection overlay, kept out of the SwiftUI view so the
/// view stays a thin projection of it — the same split the editor uses (`EditorModel`).
///
/// All geometry is in **screen points** (top-left origin) at 1:1 with the overlay window, so no
/// projection is needed; the pixel-dimension readout scales points by the display's backing scale.
/// Selecting, moving, and resizing reuse the domain's pure geometry (`rectBetween`, `handlePoint`,
/// `Rect.resized`) — the overlay never reinvents the arithmetic the editor already relies on.
@MainActor
@Observable
final class SelectionOverlayModel {

    /// Screen points → native pixels, for the dimension readout (story 3).
    private let pixelScale: Double
    private let finish: (CaptureRegion?) -> Void

    /// The current selection in screen points, or `nil` before the first drag. Kept standardized
    /// only when read out; in-flight it may be inverted (dragging up/left).
    private(set) var selection: Rect?

    private var gestureActive = false
    private var draftStart: Point?
    private var drag: OverlayDrag?

    init(pixelScale: Double, finish: @escaping (CaptureRegion?) -> Void) {
        self.pixelScale = pixelScale
        self.finish = finish
    }

    // MARK: - Derived state for the view

    /// Whether a selection large enough to capture exists.
    var hasSelection: Bool {
        guard let s = selection else { return false }
        return s.width >= 1 && s.height >= 1
    }

    /// The selection's pixel dimensions for the live readout, or `nil` when there's nothing yet.
    var pixelSize: (width: Int, height: Int)? {
        guard let s = selection, hasSelection else { return nil }
        return (Int((s.width * pixelScale).rounded()), Int((s.height * pixelScale).rounded()))
    }

    // MARK: - Drag gesture (screen-point coordinates)

    func dragChanged(to point: Point) {
        if gestureActive {
            update(to: point)
        } else {
            gestureActive = true
            begin(at: point)
        }
    }

    func dragEnded(to point: Point) {
        if !gestureActive { begin(at: point) }
        update(to: point)
        gestureActive = false
        drag = nil
        draftStart = nil
    }

    private func begin(at point: Point) {
        // With a selection in place, a press on a handle resizes it and a press inside moves it
        // (story 4 — fine-tune before capturing); anything else starts a fresh selection.
        if let selection, hasSelection, let handle = handle(at: point, of: selection) {
            drag = .resize(handle: handle, origin: selection.standardized, start: point)
        } else if let selection, hasSelection, selection.standardized.contains(point) {
            drag = .move(origin: selection.standardized, start: point)
        } else {
            draftStart = point
            selection = Rect(origin: point, size: Size(width: 0, height: 0))
        }
    }

    private func update(to point: Point) {
        if let drag {
            switch drag {
            case let .resize(handle, origin, start):
                selection = origin.resized(handle: handle, dx: point.x - start.x, dy: point.y - start.y)
            case let .move(origin, start):
                selection = Rect(
                    x: origin.minX + (point.x - start.x),
                    y: origin.minY + (point.y - start.y),
                    width: origin.width,
                    height: origin.height
                )
            }
        } else if let start = draftStart {
            selection = rectBetween(start, point)
        }
    }

    /// The resize handle near `point`, if within a grab tolerance of one.
    private func handle(at point: Point, of box: Rect) -> Handle? {
        Handle.allCases.first { h in
            let hp = handlePoint(h, in: box.standardized)
            return abs(hp.x - point.x) <= Self.handleTolerance
                && abs(hp.y - point.y) <= Self.handleTolerance
        }
    }

    // MARK: - Resolution

    /// Confirm the selection (Return): resolves to a `CaptureRegion`. A no-op with no selection.
    func confirm() {
        guard let selection, hasSelection else { return }
        finish(.rect(selection.standardized))
    }

    /// Cancel (Escape): resolves to `nil`, a silent no-op with no capture (story 5).
    func cancel() { finish(nil) }

    private static let handleTolerance: Double = 8
}

/// An in-progress resize or move of the committed selection.
private enum OverlayDrag {
    case resize(handle: Handle, origin: Rect, start: Point)
    case move(origin: Rect, start: Point)
}
