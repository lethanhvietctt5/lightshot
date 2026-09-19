import Foundation

/// Typed failure surface for opening an existing image file (story 39).
///
/// `ImageSource` returns `Result<CapturedImage, ImageLoadError>` so a decode failure or a
/// dismissed panel is never a silently blank editor. The coordinator routes each case to a
/// distinct outcome — mirroring how `CaptureError` is handled — so the open-file path lands the
/// user in the editor, a silent no-op, or a specific error message, but never a blank window.
public enum ImageLoadError: Error, Equatable, Sendable {
    /// The file could not be read as bytes (missing, unreadable, or an I/O failure).
    case unreadable
    /// The bytes were read but are not a decodable image (or not an image format we support).
    case unsupportedFormat
    /// The user dismissed the open panel. A silent no-op — not an error to surface.
    case userCancelled
}
