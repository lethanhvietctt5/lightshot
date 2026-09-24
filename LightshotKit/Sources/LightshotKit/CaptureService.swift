import Foundation

/// The OS capture seam, fronted as a protocol so the domain core never imports ScreenCaptureKit.
///
/// The concrete implementation (in the app target) wraps ScreenCaptureKit; a fake in tests returns
/// canned results, which is how the coordinator's routing is verified without a real display or TCC
/// state. Fullscreen (story 8) is the target itself; the area path (LIG-13) takes a `CaptureRegion`
/// the overlay resolved *before* capturing. Both return a typed `Result`, never a silent empty image.
///
/// The Screen Recording permission surface (`authorizationStatus()` / `requestAuthorization()`) is
/// inherited from `PermissionAuthorizing`: the coordinator uses it to decide whether to run
/// first-run onboarding (`.notDetermined` ⇒ prompt) — advisory only — and LIG-21's onboarding drives
/// the same pair through that shared seam. The capture calls below stay authoritative: a permission
/// revoked after an advisory check still lands as `.permissionDenied`.
public protocol CaptureService: PermissionAuthorizing {
    /// Capture a full display at native (Retina) resolution.
    ///
    /// Returns a `Result` rather than an optional so failures are always typed and never a
    /// silently empty image. Fullscreen skips the pre-capture overlay: the display is the target.
    ///
    /// `displayID` chooses which display to grab on a multi-monitor setup (story 8): it is the
    /// window server's `CGDirectDisplayID`, modeled as `UInt32` so the domain core stays free of
    /// CoreGraphics — exactly as `CaptureRegion.window` carries a `CGWindowID`. `nil` means "the
    /// primary display", which is what the hotkey/default path uses; the menu passes an explicit id
    /// per display when more than one is attached.
    func captureFullscreen(displayID: UInt32?) async -> Result<CapturedImage, CaptureError>

    /// Capture a `CaptureRegion` resolved by the overlay, at native (Retina) resolution.
    ///
    /// Called *after* `OverlayController` hands back a region — the overlay chooses the target, the
    /// service captures it. Same typed-`Result` contract as fullscreen: a failure is never a
    /// silently empty image, and `permissionDenied` still routes to the System-Settings recovery.
    func captureRegion(_ region: CaptureRegion) async -> Result<CapturedImage, CaptureError>

    /// Take one still of the display the selection overlay covers (spec 0011, Freeze Screen),
    /// honouring the include-cursor setting. Called *before* the overlay exists, so none of
    /// Lightshot's windows are in it. The overlay shows it as its backdrop and an area result is cut
    /// from it; failures route exactly as a capture's do, and the overlay is never shown.
    func freezeScreen() async -> Result<FrozenScreen, CaptureError>
}
