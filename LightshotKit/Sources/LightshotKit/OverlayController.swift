import Foundation

/// The pre-capture selection overlay seam, fronted as a protocol so the coordinator's
/// area-capture sequencing is testable without AppKit or a window server.
///
/// The concrete implementation (app target) is a full-screen dimmed `NSWindow`: drag a
/// selection rect with a live pixel-dimension readout, fine-tune it with edge/corner handles,
/// Escape to cancel. It runs *before* capture and does **not** itself capture — it only resolves
/// the user's choice into a `CaptureRegion`. A fake in tests returns a canned region (or `nil`),
/// which is how the coordinator's overlay → capture → toolbar ordering is verified with no screen.
///
/// The two entry points map to the spec's two selection modes and share the same overlay
/// infrastructure: `selectRegion()` drags a rect (LIG-13), `selectWindow()` hover-highlights and
/// clicks a window (LIG-14). Both resolve to a `CaptureRegion` (or `nil` on Escape) fed to the
/// same `CaptureService.captureRegion(_:)`.
@MainActor
public protocol OverlayController: AnyObject {
    /// Present the drag-a-rect selection overlay and await the user's choice (stories 2–5).
    ///
    /// Resolves to the chosen `CaptureRegion`, or `nil` when the user cancels (Escape) — a `nil`
    /// is a silent no-op, never a capture. The overlay is dismissed by the time this returns.
    func selectRegion() async -> CaptureRegion?

    /// Present the window-capture overlay and await the user's choice (stories 6–7): windows
    /// highlight on hover, a click picks one, Escape cancels.
    ///
    /// Resolves to a `.window` `CaptureRegion` for the clicked window, or `nil` on cancel — the
    /// same silent-no-op contract as `selectRegion()`. The overlay is dismissed by the time this
    /// returns, so it is never itself the window that gets captured.
    func selectWindow() async -> CaptureRegion?

    /// Present the recording overlay (spec 0006, stories 3–9): drag a rect that stays editable
    /// (handles, move, arrow keys, ratio lock, typed size), hover-and-click a window to snap to it,
    /// or pick the whole display — with the recorder toolbar at the selection: Start Video, Start
    /// GIF and the per-recording toggles seeded from `defaults`. Unlike `selectRegion()`, releasing
    /// the drag does not confirm; a Start button (or Return, for video) does. `initial` is a
    /// remembered region to pre-fill: a rect is clipped to what still fits (or dropped), a window
    /// only if it is still open, a display only if it is the one the overlay covers.
    ///
    /// Resolves to the region, the chosen output and the toggle overrides, or `nil` on Escape.
    func selectRecording(initial: CaptureRegion?, defaults: RecordingDefaults) async -> RecordingChoice?
}
