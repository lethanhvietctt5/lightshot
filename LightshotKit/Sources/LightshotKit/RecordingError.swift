import Foundation

/// Typed failure surface for a recording session (spec 0006).
///
/// The recording counterpart of `CaptureError`: `RecordingService` never yields a silently
/// empty file — every failure is one of these, and `AppCoordinator` routes each case to a distinct
/// outcome. `permissionDenied` carries *which* permission is missing: today only Screen Recording
/// exists, but the microphone, camera and input-monitoring kinds arrive with their features (R6),
/// and the recovery message and System Settings pane differ per kind.
///
/// `systemFailure` carries a description rather than the underlying `Error`, exactly as
/// `CaptureError` does, so the type stays `Equatable`/`Sendable` and the core leaks no concrete
/// framework error.
public enum RecordingError: Error, Equatable, Sendable {
    /// A permission the recording needs is missing or was revoked. The preflight is advisory; the
    /// recording call is authoritative, so this also covers a grant revoked mid-session.
    case permissionDenied(PermissionKind)
    /// No display was available to record.
    case noDisplayAvailable
    /// The user backed out (Escape in the overlay or countdown). A silent no-op, never surfaced.
    case userCancelled
    /// The output volume ran out of space while writing.
    case diskFull
    /// Any other failure from the OS capture/encoding layer, described for diagnostics.
    case systemFailure(String)
}
