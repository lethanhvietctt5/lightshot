import Foundation

/// The permission surface for a single OS authorization the app must hold — split out of
/// `CaptureService` so first-run onboarding (LIG-21) can drive **any** required permission through
/// one seam, not just capture. A source reports its current status and can trigger the system
/// prompt; both are `async` because the underlying TCC calls can block.
///
/// Reused, not re-invented: `CaptureService` already spoke exactly this pair for Screen Recording
/// (LIG-19), so it now *refines* this protocol and satisfies it for free. A new required permission
/// adds a conformer here rather than a parallel API — the onboarding model treats every requirement
/// through this one interface.
public protocol PermissionAuthorizing: Sendable {
    /// The current authorization state, as a preflight can tell.
    ///
    /// **Advisory only** — the capability's own call (a capture, say) stays authoritative.
    /// `.notDetermined` means never asked, so onboarding can prompt; `.authorized` is a standing
    /// grant; `.denied` means the user must re-enable it in System Settings (a re-prompt won't show).
    func authorizationStatus() async -> CaptureAuthorizationStatus

    /// Trigger the one-time system permission prompt and report the resulting status.
    ///
    /// Safe to call when already decided: the OS prompts at most once, so a standing grant or denial
    /// returns without re-prompting.
    @discardableResult
    func requestAuthorization() async -> CaptureAuthorizationStatus
}
