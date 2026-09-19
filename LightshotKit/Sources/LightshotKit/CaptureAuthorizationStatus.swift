import Foundation

/// Screen Recording permission state, as the app understands it before a capture.
///
/// A three-state value (matching the AVFoundation/TCC pattern) so the coordinator can tell a
/// genuine **first run** — never asked — apart from a standing grant or denial. This is what
/// drives first-run onboarding (story 57): only `.notDetermined` triggers the system prompt.
///
/// It is deliberately **advisory**: the coordinator uses it only to decide whether to guide the
/// user up front. The capture call itself remains authoritative — a permission revoked between
/// this check and the capture still surfaces as `CaptureError.permissionDenied` and routes to the
/// recovery path (story 58).
public enum CaptureAuthorizationStatus: Equatable, Sendable {
    /// The user has never been asked — a true first run. Onboarding prompts here.
    case notDetermined
    /// Screen Recording permission is granted (as far as a preflight can tell).
    case authorized
    /// The user has been asked and declined, or later revoked. Recovery, not a re-prompt.
    case denied
}
