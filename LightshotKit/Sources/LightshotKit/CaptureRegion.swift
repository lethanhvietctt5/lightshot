import Foundation

/// What an area/window capture targets — the output of the pre-capture overlay, the input to
/// the region path of `CaptureService`.
///
/// The overlay (`OverlayController`) resolves the user's choice into a `CaptureRegion` and hands
/// it to `CaptureService`; the overlay itself never captures. Modeled as a sum type because the
/// spec's two selection modes are genuinely different targets — a dragged rectangle (this ticket,
/// stories 2–4) versus a hovered window id (LIG-14, stories 6–7). Keeping it an enum means the
/// window case is an addition, not a breaking change to the capture signature.
public enum CaptureRegion: Equatable, Sendable {
    /// A rectangular selection in **screen point coordinates** (top-left origin), as dragged in
    /// the overlay. The concrete `CaptureService` maps it to the target display's native pixels.
    case rect(Rect)
}
