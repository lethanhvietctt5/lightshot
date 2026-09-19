import Foundation

/// The OS capture seam, fronted as a protocol so the domain core never imports ScreenCaptureKit.
///
/// The concrete implementation (in the app target) wraps ScreenCaptureKit; a fake in tests returns
/// canned results, which is how the coordinator's routing is verified without a real display or TCC
/// state. Fullscreen (story 8) is the target itself; the area path (LIG-13) takes a `CaptureRegion`
/// the overlay resolved *before* capturing. Both return a typed `Result`, never a silent empty image.
public protocol CaptureService: Sendable {
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
