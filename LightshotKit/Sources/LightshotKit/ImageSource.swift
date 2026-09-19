import Foundation

/// The open-existing-image seam, fronted as a protocol so the domain core never imports the
/// file-picker or image-decoding frameworks (`NSOpenPanel` / ImageIO).
///
/// It is the input contract for story 39: opening a file produces the **same** `CapturedImage`
/// value a capture yields, so the editor entry point `openEditor(with:)` stays source-agnostic —
/// no ad-hoc file/UI dependency leaks into the editor. Both entry points return the *same*
/// `Result` type, so cancellation and decode failures are always surfaced, never silently dropped:
/// `loadImage(from:)` decodes a known URL, `openDocument()` first asks the user to pick one.
///
/// `@MainActor` because `openDocument()` drives a file panel; a fake in tests returns fixtures,
/// which is how the coordinator's open-file routing is verified with no panel and no filesystem.
@MainActor
public protocol ImageSource: AnyObject {
    /// Decode the image at `url` into a `CapturedImage`.
    ///
    /// Returns `.unreadable` when the bytes can't be read and `.unsupportedFormat` when they read
    /// but don't decode as an image — never a silently empty image. (`userCancelled` doesn't arise
    /// here; it's the `openDocument()` panel-dismissed case.)
    func loadImage(from url: URL) -> Result<CapturedImage, ImageLoadError>

    /// Present a file picker and load the chosen image, converging on the same result type.
    ///
    /// Resolves to the loaded `CapturedImage` on success, `.userCancelled` when the user dismisses
    /// the panel (a silent no-op, never a capture), or the same decode failures `loadImage` surfaces.
    func openDocument() -> Result<CapturedImage, ImageLoadError>
}
