import Foundation

/// The OS capture seam, fronted as a protocol so the domain core never imports ScreenCaptureKit.
///
/// The concrete implementation (in the app target) wraps ScreenCaptureKit; a fake in tests returns
/// canned results, which is how the coordinator's routing is verified without a real display or TCC
/// state. Fullscreen (story 8) is the target itself; the area path (LIG-13) takes a `CaptureRegion`
/// the overlay resolved *before* capturing. Both return a typed `Result`, never a silent empty image.
public protocol CaptureService: Sendable {
    /// The current Screen Recording permission state, as a preflight can tell.
    ///
    /// **Advisory only** — the coordinator uses it to decide whether to run first-run onboarding
    /// (`.notDetermined` ⇒ prompt), never to gate a capture. The capture calls below stay
    /// authoritative: a permission revoked after this returns still lands as `.permissionDenied`.
    func authorizationStatus() async -> CaptureAuthorizationStatus

    /// Trigger the system Screen Recording permission prompt and report the resulting status.
    ///
    /// Called on first run (`authorizationStatus() == .notDetermined`) to guide the user through
    /// granting permission before their first capture (story 57), rather than letting the capture
    /// fail cryptically. Safe to call when already decided: the OS prompts at most once, so a
    /// standing denial returns `.denied` without re-prompting.
    @discardableResult
    func requestAuthorization() async -> CaptureAuthorizationStatus

    /// Capture the full screen at native (Retina) resolution.
    ///
    /// Returns a `Result` rather than an optional so failures are always typed and never a
    /// silently empty image. Fullscreen skips the pre-capture overlay: the display is the target.
    func captureFullscreen() async -> Result<CapturedImage, CaptureError>

    /// Capture a `CaptureRegion` resolved by the overlay, at native (Retina) resolution.
    ///
    /// Called *after* `OverlayController` hands back a region — the overlay chooses the target, the
    /// service captures it. Same typed-`Result` contract as fullscreen: a failure is never a
    /// silently empty image, and `permissionDenied` still routes to the System-Settings recovery.
    func captureRegion(_ region: CaptureRegion) async -> Result<CapturedImage, CaptureError>
}
