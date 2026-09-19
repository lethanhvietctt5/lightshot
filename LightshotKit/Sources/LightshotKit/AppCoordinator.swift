import Foundation

/// The user-facing surface the coordinator drives — implemented by the app shell (windows, alerts).
///
/// Kept as a protocol so the coordinator's sequencing is testable without AppKit: a fake records
/// which method fired, which is exactly what the story 8 / 57–58 tests assert. `openEditor(with:)`
/// is deliberately source-agnostic (a capture *or* an opened file (story 39) both arrive here).
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
    /// Surface a distinct, non-blank error message for an open-file failure other than cancel
    /// (story 39): an unreadable or unsupported file, routed analogously to `presentCaptureFailure`.
    func presentImageLoadFailure(_ error: ImageLoadError)
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
    private let imageSource: ImageSource
    private let imageSink: ImageSink
    private let settings: SettingsStore
    private let history: HistoryStore?
    private let sleep: (TimeInterval) async -> Void
    private unowned let ui: CaptureUI

    /// The most recent capture the user initiated, so `repeatLastCapture()` (story 9) can re-fire the
    /// same kind — including the chosen display for fullscreen. In-memory and set at the *start* of a
    /// capture (the mode the user picked), so a repeat re-offers that mode even if the last attempt
    /// was cancelled. `nil` until the first capture, which makes repeat a no-op with nothing to repeat.
    private enum LastCapture {
        case fullscreen(displayID: UInt32?)
        case area
        case window
    }
    private var lastCapture: LastCapture?

    public init(
        captureService: CaptureService,
        overlay: OverlayController,
        imageSource: ImageSource,
        imageSink: ImageSink,
        settings: SettingsStore,
        history: HistoryStore? = nil,
        sleep: @escaping (TimeInterval) async -> Void = { seconds in
            try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
        },
        ui: CaptureUI
    ) {
        self.captureService = captureService
        self.overlay = overlay
        self.imageSource = imageSource
        self.imageSink = imageSink
        self.settings = settings
        self.history = history
        self.sleep = sleep
        self.ui = ui
    }

    /// Fullscreen capture flow (story 8). Runs first-run permission onboarding (story 57), then
    /// skips the overlay — the display is the target — and routes the typed result: success opens
    /// the editor, `permissionDenied` goes to the
    /// System-Settings recovery path (never a blank editor), `userCancelled` is a silent no-op,
    /// and anything else surfaces a distinct failure message.
    ///
    /// `displayID` picks the display on a multi-monitor setup (story 8); `nil` is the primary
    /// display, used by the hotkey and the single-display menu item. The self-timer (story 10)
    /// runs just before the shot fires.
    public func captureFullscreen(displayID: UInt32? = nil) async {
        lastCapture = .fullscreen(displayID: displayID)
        guard await guideFirstRunAuthorizationIfNeeded() else { return }
        await applyCaptureDelay()
        switch await captureService.captureFullscreen(displayID: displayID) {
        case let .success(image):
            record(image, source: .fullscreen)
            ui.openEditor(with: image)
        case .failure(.permissionDenied):
            ui.presentPermissionDenied()
        case .failure(.userCancelled):
            break
        case let .failure(error):
            ui.presentCaptureFailure(error)
        }
    }

    /// Area capture flow (stories 1–5, 14). Runs first-run permission onboarding (story 57) up
    /// front so the prompt precedes the drag. Then ordering matters: the **overlay runs first** to
    /// resolve a `CaptureRegion` (drag a rect, Escape to cancel), *then* `CaptureService` captures
    /// it — the service needs a target. A cancelled overlay (`nil`) is a silent no-op with no
    /// capture. On success the capture opens in the editor (or the post-capture toolbar at the
    /// selection, per `openInEditor`); failures route exactly as fullscreen does —
    /// `permissionDenied` to recovery, `userCancelled` silent, the rest to a distinct message — so
    /// a capture never lands the user in a blank editor.
    public func captureArea() async {
        lastCapture = .area
        guard await guideFirstRunAuthorizationIfNeeded() else { return }
        guard let region = await overlay.selectRegion() else { return }
        // Self-timer (story 10) runs *after* the region is chosen but *before* the shot fires, so the
        // user can set up transient UI over the selection they just made.
        await applyCaptureDelay()
        switch await captureService.captureRegion(region) {
        case let .success(image):
            record(image, source: .area)
            presentCapture(image, at: region)
        case .failure(.permissionDenied):
            ui.presentPermissionDenied()
        case .failure(.userCancelled):
            break
        case let .failure(error):
            ui.presentCaptureFailure(error)
        }
    }

    /// Where a successful area/window capture lands (story 13, LIG-23): straight in the editor by
    /// default, or the post-capture toolbar at the selection when the user turned `openInEditor`
    /// off. Read live from settings, so a change takes effect on the next capture.
    private func presentCapture(_ image: CapturedImage, at region: CaptureRegion) {
        if settings.openInEditor {
            ui.openEditor(with: image)
        } else {
            ui.presentPostCaptureToolbar(for: image, at: region)
        }
    }

    /// First-run onboarding (story 57). The *very first* time the user captures, they have never
    /// been asked for Screen Recording permission (`authorizationStatus() == .notDetermined`), so
    /// trigger the system permission prompt up front — the user is guided to grant it instead of
    /// meeting a cryptic black/empty capture.
    ///
    /// Returns whether the capture should go ahead. The OS request does **not** wait for the user:
    /// on a first ask it raises the system prompt and returns un-authorized immediately (the grant
    /// then happens in System Settings). So an un-authorized first-run request means the system
    /// prompt is on screen *right now* — the flow stops there rather than covering it with the
    /// selection overlay or stacking our own recovery alert on top of it.
    ///
    /// Otherwise the check stays purely **advisory**: a standing grant (`.authorized`) and a
    /// standing denial (`.denied`) both proceed without prompting — a denial is handled by the
    /// capture call, not by re-prompting. That capture is authoritative: if permission is missing
    /// (or revoked after this check — the race), it returns `.permissionDenied` and routes to the
    /// recovery path (story 58).
    private func guideFirstRunAuthorizationIfNeeded() async -> Bool {
        guard await captureService.authorizationStatus() == .notDetermined else { return true }
        return await captureService.requestAuthorization() == .authorized
    }

    /// Window capture flow (stories 6–7). Runs first-run permission onboarding (story 57) up front,
    /// then is structurally identical to `captureArea()` — only the overlay mode differs:
    /// `selectWindow()` hover-highlights windows and resolves the clicked one to a `.window`
    /// `CaptureRegion`, which the **same** `CaptureService.captureRegion(_:)` then captures cleanly
    /// without its surroundings. Escape (`nil`) is a silent no-op with no capture; success records
    /// the capture in history and opens it in the editor (or the toolbar at the window, per
    /// `openInEditor`); failures route
    /// exactly as the other paths do — `permissionDenied` to recovery, `userCancelled` silent, the
    /// rest to a distinct message — so a capture never lands the user in a blank editor.
    public func captureWindow() async {
        lastCapture = .window
        guard await guideFirstRunAuthorizationIfNeeded() else { return }
        guard let region = await overlay.selectWindow() else { return }
        // Self-timer (story 10): delay after the window is picked, before it is captured.
        await applyCaptureDelay()
        switch await captureService.captureRegion(region) {
        case let .success(image):
            record(image, source: .window)
            presentCapture(image, at: region)
        case .failure(.permissionDenied):
            ui.presentPermissionDenied()
        case .failure(.userCancelled):
            break
        case let .failure(error):
            ui.presentCaptureFailure(error)
        }
    }

    /// Repeat-last-capture-mode (story 9): re-fire whichever of area/window/fullscreen the user ran
    /// most recently — including the display fullscreen last targeted — so repeated shots of the same
    /// kind are one shortcut away. A no-op when nothing has been captured yet (nothing to repeat).
    /// This re-runs the whole flow, so the overlay and the self-timer apply exactly as they did the
    /// first time.
    public func repeatLastCapture() async {
        switch lastCapture {
        case let .fullscreen(displayID):
            await captureFullscreen(displayID: displayID)
        case .area:
            await captureArea()
        case .window:
            await captureWindow()
        case nil:
            break
        }
    }

    /// The self-timer wait shared by every capture path (story 10): pause for the configured delay
    /// before the shot fires. Read live from settings, so a change takes effect on the next capture;
    /// `0` (the default) skips the wait entirely.
    private func applyCaptureDelay() async {
        let seconds = settings.captureDelay
        guard seconds > 0 else { return }
        await sleep(seconds)
    }

    /// Open-existing-file flow (story 39). A file picker (via `ImageSource`) yields the *same*
    /// `CapturedImage` a capture produces, so the result converges on the one `openEditor(with:)`
    /// entry — the editor never learns whether the pixels came from a capture or a file. The typed
    /// result routes exactly as the capture spine does: success opens the editor, `userCancelled`
    /// (the panel was dismissed) is a silent no-op, and an unreadable/unsupported file surfaces a
    /// distinct message — never a blank editor. Opening an existing file is not a capture, so it is
    /// not recorded in history (stories 50–54 are about captures).
    public func openFile() {
        switch imageSource.openDocument() {
        case let .success(image):
            ui.openEditor(with: image)
        case .failure(.userCancelled):
            break
        case let .failure(error):
            ui.presentImageLoadFailure(error)
        }
    }

    /// Record a fresh capture in the local history as it happens (story 50). Best-effort: a history
    /// write failure must never block the user from seeing their capture, so it is swallowed rather
    /// than surfaced. No-op when no store is wired.
    private func record(_ image: CapturedImage, source: CaptureSource) {
        _ = try? history?.add(image, source: source)
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
