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
/// It wires the single fullscreen spine — capture → `openEditor(with:)` → `render` →
/// clipboard — so what the user copies is always the flattened document.
@MainActor
public final class AppCoordinator {
    private let captureService: CaptureService
    private let imageSink: ImageSink
    private let settings: SettingsStore
    private unowned let ui: CaptureUI

    public init(captureService: CaptureService, imageSink: ImageSink, settings: SettingsStore, ui: CaptureUI) {
        self.captureService = captureService
        self.imageSink = imageSink
        self.settings = settings
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

    /// Editor output (stories 40/44): flatten base + all elements in z-order via
    /// `render(_ document:)` and place that on the clipboard. What lands on the clipboard
    /// is the *rendered* image, not the raw capture.
    public func copyToClipboard(_ document: AnnotationDocument) {
        imageSink.copyToClipboard(render(document))
    }

    /// Save the flattened document to an explicit destination and format — a per-save override,
    /// e.g. from a Save-As panel (stories 41–42, 44). The chosen `ImageFormat` reaches the sink
    /// unchanged, so what lands on disk is the *rendered* document in exactly the requested format.
    public func save(_ document: AnnotationDocument, to url: URL, format: ImageFormat) throws {
        try imageSink.write(render(document), to: url, format: format)
    }

    /// Save using the configured defaults — no dialog (story 43). Resolves the destination from the
    /// settings' save location + filename pattern and writes in the default format, returning the
    /// URL written to. This is the "used when no override is given" path.
    @discardableResult
    public func save(_ document: AnnotationDocument, at date: Date = Date()) throws -> URL {
        let url = settings.defaultDestination(at: date)
        try save(document, to: url, format: settings.defaultFormat)
        return url
    }

    /// Build the drag-out payload for the editor (story 45): the flattened render encoded in the
    /// default format, named by the same filename pattern the default save uses. The app wraps this
    /// in an `NSItemProvider`, so dragging drops the rendered image straight into another app.
    public func dragItem(for document: AnnotationDocument, at date: Date = Date()) -> ImageDragItem {
        let format = settings.defaultFormat
        let data = encode(render(document), as: format)
        let name = FilenameFormatter(pattern: settings.filenamePattern).filename(at: date)
        return ImageDragItem(data: data, format: format, suggestedName: name)
    }
}
