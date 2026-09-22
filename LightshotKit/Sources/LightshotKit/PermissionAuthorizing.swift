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

    /// Trigger the one-time system permission prompt and report the status *as of the call returning*.
    ///
    /// **Does not wait for the user.** For Screen Recording the OS raises its prompt and returns
    /// un-authorized within milliseconds; the grant itself happens later, in System Settings. Treat an
    /// un-authorized result on a first ask as "the system prompt is showing", never as a decision.
    ///
    /// Safe to call when already decided: the OS prompts at most once, so a standing grant or denial
    /// returns without re-prompting.
    @discardableResult
    func requestAuthorization() async -> CaptureAuthorizationStatus

    /// Whether `requestAuthorization()` returns the user's actual decision (AVFoundation's microphone
    /// and camera prompts wait for the answer) rather than returning at once with the prompt still
    /// on screen (Screen Recording, Input Monitoring). `PermissionGate` uses it to tell a decline
    /// from a prompt in progress. Defaults to `false`, the Screen Recording behaviour.
    var requestWaitsForAnswer: Bool { get }
}

public extension PermissionAuthorizing {
    var requestWaitsForAnswer: Bool { false }
}
