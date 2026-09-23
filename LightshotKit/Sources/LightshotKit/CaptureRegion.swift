import Foundation

/// What an area/window capture targets — the output of the pre-capture overlay, the input to
/// the region path of `CaptureService`.
///
/// The overlay (`OverlayController`) resolves the user's choice into a `CaptureRegion` and hands
/// it to `CaptureService`; the overlay itself never captures. Modeled as a sum type because the
/// spec's two selection modes are genuinely different targets — a dragged rectangle (LIG-13,
/// stories 2–4) versus a hovered window id (LIG-14, stories 6–7). Keeping it an enum means the
/// window case is an addition, not a breaking change to the capture signature.
public enum CaptureRegion: Equatable, Codable, Sendable {
    /// A rectangular selection in **screen point coordinates** (top-left origin), as dragged in
    /// the overlay. The concrete `CaptureService` maps it to the target display's native pixels.
    case rect(Rect)

    /// A single window, hover-picked in window-capture mode (stories 6–7). `id` is the window
    /// server's `CGWindowID` — modeled as `UInt32` so the domain core stays free of CoreGraphics —
    /// which `CaptureService` resolves back to the live window it captures cleanly, without the
    /// surroundings. `frame` is the window's on-screen bounds in **screen point coordinates**
    /// (top-left origin), carried so the post-capture toolbar can position itself at the window
    /// exactly as it does for a dragged rect — the capture itself only needs the `id`.
    case window(id: UInt32, frame: Rect)

    /// A whole display, chosen in the recorder's record mode (spec 0006, story 6). `id` is the
    /// window server's `CGDirectDisplayID`, modeled as `UInt32` exactly as `captureFullscreen`'s
    /// `displayID` is. Screenshots never produce this case — fullscreen capture skips the overlay —
    /// but recording resolves every target through one `CaptureRegion`, so the recorder can hand a
    /// display to the same `RecordingService.start` as a rect or a window.
    case display(id: UInt32)
}

/// What a recording of a `CaptureRegion` streams (spec 0006, story 5): the whole display, or an
/// area of it. There is deliberately no window-only case — a recording is of a place on screen, so
/// an app opened over it mid-take is recorded, as in CleanShot X. (Screenshots of a window still
/// capture the window alone; that is `CaptureService`'s business, not this.)
public enum RecordedArea: Equatable, Sendable {
    case display(id: UInt32)
    /// A sub-rect of the display, standardized, in screen points (top-left origin).
    case area(Rect)
}

extension CaptureRegion {
    /// A picked window records the area its frame covers, exactly like a drawn rect over it.
    public var recordedArea: RecordedArea {
        switch self {
        case let .display(id): .display(id: id)
        case let .rect(rect), let .window(_, rect): .area(rect.standardized)
        }
    }
}
