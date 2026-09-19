import Foundation

/// The OS capture seam, fronted as a protocol so the domain core never imports ScreenCaptureKit.
///
/// The concrete implementation (in the app target) wraps ScreenCaptureKit; a fake in tests returns
/// canned results, which is how the coordinator's routing is verified without a real display or TCC
/// state. This tracer bullet only needs the fullscreen path (story 8); the area/window entry points
/// — which resolve a `CaptureRegion` via the overlay *before* capturing — land with their tickets.
public protocol CaptureService: Sendable {
    /// Capture the full screen at native (Retina) resolution.
    ///
    /// Returns a `Result` rather than an optional so failures are always typed and never a
    /// silently empty image. Fullscreen skips the pre-capture overlay: the display is the target.
    func captureFullscreen() async -> Result<CapturedImage, CaptureError>
}
