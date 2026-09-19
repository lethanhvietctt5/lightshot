import Foundation

/// The user-facing surface the coordinator drives — implemented by the app shell (windows, alerts).
///
/// Kept as a protocol so the coordinator's sequencing is testable without AppKit: a fake records
/// which method fired, which is exactly what the story 8 / 57–58 tests assert. `openEditor(with:)`
/// is deliberately source-agnostic (a capture *or* a future opened file both arrive here).
@MainActor
public protocol CaptureUI: AnyObject {
    /// Open the annotation editor showing the captured image.
    func openEditor(with image: CapturedImage)
    /// Present the post-capture toolbar at the selection (story 14): quick actions — annotate,
    /// copy, discard — over the freshly captured image. A separate surface shown *after* the image
    /// exists, positioned using `region`; not part of the pre-capture selection overlay.
    func presentPostCaptureToolbar(for image: CapturedImage, at region: CaptureRegion)
    /// Show the permission recovery path: a message plus a deep link to System Settings.
    func presentPermissionDenied()
    /// Surface a distinct, non-blank error message for a failure other than permission/cancel.
    func presentCaptureFailure(_ error: CaptureError)
}

/// Thin composition root: sequences a capture through to the editor, and the editor's output back
/// out through the sink. Holds only protocol references, so the domain core never imports the OS
/// capture/clipboard APIs.
///
/// It wires the single fullscreen spine — capture → `openEditor(with:)` → `render` →
/// clipboard — so what the user copies is always the flattened document.
@MainActor
public final class AppCoordinator {
    private let captureService: CaptureService
    private let overlay: OverlayController
    private let imageSink: ImageSink
    private unowned let ui: CaptureUI

    public init(
        captureService: CaptureService,
        overlay: OverlayController,
        imageSink: ImageSink,
        ui: CaptureUI
    ) {
        self.captureService = captureService
        self.overlay = overlay
        self.imageSink = imageSink
        self.ui = ui
    }

    /// Fullscreen capture flow (story 8). Skips the overlay — the display is the target — then
    /// routes the typed result: success opens the editor, `permissionDenied` goes to the
    /// System-Settings recovery path (never a blank editor), `userCancelled` is a silent no-op,
    /// and anything else surfaces a distinct failure message.
    public func captureFullscreen() async {
        switch await captureService.captureFullscreen() {
        case let .success(image):
            ui.openEditor(with: image)
        case .failure(.permissionDenied):
            ui.presentPermissionDenied()
        case .failure(.userCancelled):
            break
        case let .failure(error):
            ui.presentCaptureFailure(error)
        }
    }

    /// Area capture flow (stories 1–5, 14). Ordering matters: the **overlay runs first** to
    /// resolve a `CaptureRegion` (drag a rect, Escape to cancel), *then* `CaptureService` captures
    /// it — the service needs a target. A cancelled overlay (`nil`) is a silent no-op with no
    /// capture. On success the post-capture toolbar is shown at the selection; failures route
    /// exactly as fullscreen does — `permissionDenied` to recovery, `userCancelled` silent, the
    /// rest to a distinct message — so a capture never lands the user in a blank editor.
    public func captureArea() async {
        guard let region = await overlay.selectRegion() else { return }
        switch await captureService.captureRegion(region) {
        case let .success(image):
            ui.presentPostCaptureToolbar(for: image, at: region)
        case .failure(.permissionDenied):
            ui.presentPermissionDenied()
        case .failure(.userCancelled):
            break
        case let .failure(error):
            ui.presentCaptureFailure(error)
        }
    }

    /// Editor output (stories 40/44): flatten base + all elements in z-order via
    /// `render(_ document:)` and place that on the clipboard. What lands on the clipboard
    /// is the *rendered* image, not the raw capture.
    public func copyToClipboard(_ document: AnnotationDocument) {
        imageSink.copyToClipboard(render(document))
    }
}
