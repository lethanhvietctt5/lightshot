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
    /// Show the permission recovery path: a message plus a deep link to System Settings.
    func presentPermissionDenied()
    /// Surface a distinct, non-blank error message for a failure other than permission/cancel.
    func presentCaptureFailure(_ error: CaptureError)
}

/// Thin composition root: sequences a capture through to the editor, and the editor's output back
/// out through the sink. Holds only protocol references, so the domain core never imports the OS
/// capture/clipboard APIs.
///
/// This tracer bullet wires the single fullscreen spine — capture → `openEditor(with:)` →
/// base-only `render` → clipboard — proving the whole path before any annotation exists.
@MainActor
public final class AppCoordinator {
    private let captureService: CaptureService
    private let imageSink: ImageSink
    private unowned let ui: CaptureUI

    public init(captureService: CaptureService, imageSink: ImageSink, ui: CaptureUI) {
        self.captureService = captureService
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

    /// Editor output: flatten the image (base-only for now) and place it on the clipboard
    /// (stories 40/44). What lands on the clipboard is the *rendered* image, not the raw capture.
    public func copyToClipboard(_ image: CapturedImage) {
        imageSink.copyToClipboard(render(image))
    }

    /// Editor output for an annotated document (stories 40/44): flatten base + all
    /// elements in z-order via `render(_ document:)` and place that on the clipboard.
    public func copyToClipboard(_ document: AnnotationDocument) {
        imageSink.copyToClipboard(render(document))
    }
}
