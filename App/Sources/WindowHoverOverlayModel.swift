import SwiftUI
import LightshotKit

/// Interaction state for the window-capture overlay (stories 6–7), split out of the SwiftUI view so
/// the view stays a thin projection of it — the same split the drag overlay uses
/// (`SelectionOverlayModel`).
///
/// The candidate windows are enumerated once by the controller (an OS query) and handed in as
/// `HoverWindow`s with frames in **screen points** (top-left origin), 1:1 with the overlay window —
/// so hit-testing is pure geometry (`Rect.contains`) with no projection. As the pointer moves, the
/// front-most window under it becomes `hovered`; a click on it resolves to a `.window`
/// `CaptureRegion`; Escape resolves to `nil`.
@MainActor
@Observable
final class WindowHoverOverlayModel {

    /// A capture candidate: the window server's id plus its on-screen bounds in screen points.
    struct HoverWindow: Identifiable, Equatable {
        let id: UInt32
        let frame: Rect
    }

    /// Candidates ordered front-most first, so the first frame containing the pointer is the one
    /// the user visually sees on top — the correct hover/click target when windows overlap.
    let windows: [HoverWindow]
    private let finish: (CaptureRegion?) -> Void

    /// The window currently under the pointer, or `nil` over bare desktop — what the view highlights.
    private(set) var hovered: HoverWindow?

    init(windows: [HoverWindow], finish: @escaping (CaptureRegion?) -> Void) {
        self.windows = windows
        self.finish = finish
    }

    /// The front-most window whose frame contains `point`, or `nil` over the desktop.
    private func window(at point: Point) -> HoverWindow? {
        windows.first { $0.frame.contains(point) }
    }

    // MARK: - Pointer

    /// Update the highlight as the pointer moves.
    func hover(at point: Point) {
        hovered = window(at: point)
    }

    /// The pointer left the overlay — clear the highlight so nothing looks armed.
    func hoverEnded() {
        hovered = nil
    }

    // MARK: - Resolution

    /// Click: capture the window under the pointer. A click over bare desktop is a no-op — the user
    /// must land on a window (or press Escape) — so an empty click never resolves to a capture.
    func click(at point: Point) {
        guard let window = window(at: point) else { return }
        finish(.window(id: window.id, frame: window.frame))
    }

    /// Return confirms the currently hovered window, mirroring the drag overlay's Return-to-confirm.
    func confirmHovered() {
        guard let hovered else { return }
        finish(.window(id: hovered.id, frame: hovered.frame))
    }

    /// Cancel (Escape): resolves to `nil`, a silent no-op with no capture.
    func cancel() { finish(nil) }
}
