import Foundation

/// Typed failure surface for a capture attempt.
///
/// `CaptureService` returns `Result<CapturedImage, CaptureError>` so a capture never silently
/// yields an empty/black image. The coordinator routes each case to a distinct outcome — most
/// importantly `permissionDenied`, which drives the System-Settings recovery path (stories
/// 57–58) rather than a blank editor.
///
/// `systemFailure` carries a human-readable description instead of the underlying `Error` so the
/// type stays `Equatable`/`Sendable` and the domain core avoids leaking a concrete error type.
public enum CaptureError: Error, Equatable, Sendable {
    /// Screen Recording permission is missing or was revoked. The status check is advisory; the
    /// actual capture call is authoritative, so this also covers the revoked-after-check race.
    case permissionDenied
    /// No display was available to capture (e.g. the shareable-content query returned none).
    case noDisplayAvailable
    /// The user backed out of the capture. A silent no-op — not an error to surface.
    case userCancelled
    /// Any other failure from the OS capture layer, described for logging/diagnostics.
    case systemFailure(String)
}
