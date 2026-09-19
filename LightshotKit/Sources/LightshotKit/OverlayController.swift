import Foundation

/// The pre-capture selection overlay seam, fronted as a protocol so the coordinator's
/// area-capture sequencing is testable without AppKit or a window server.
///
/// The concrete implementation (app target) is a full-screen dimmed `NSWindow`: drag a
/// selection rect with a live pixel-dimension readout, fine-tune it with edge/corner handles,
/// Escape to cancel. It runs *before* capture and does **not** itself capture — it only resolves
/// the user's choice into a `CaptureRegion`. A fake in tests returns a canned region (or `nil`),
/// which is how the coordinator's overlay → capture → toolbar ordering is verified with no screen.
@MainActor
public protocol OverlayController: AnyObject {
    /// Present the selection overlay and await the user's choice.
    ///
    /// Resolves to the chosen `CaptureRegion`, or `nil` when the user cancels (Escape) — a `nil`
    /// is a silent no-op, never a capture. The overlay is dismissed by the time this returns.
    func selectRegion() async -> CaptureRegion?
}
