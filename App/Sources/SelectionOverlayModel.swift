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
