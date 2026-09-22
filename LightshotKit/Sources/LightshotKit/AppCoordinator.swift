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
    /// Show the permission recovery path for `kind`: a message naming the grant plus a deep link to
    /// its System Settings pane. Screenshots always pass `.screenRecording`; recording passes
    /// whichever grant its feature lacked (spec 0006, story 41).
    func presentPermissionDenied(_ kind: PermissionKind)
    /// Surface a distinct, non-blank error message for a failure other than permission/cancel.
    func presentCaptureFailure(_ error: CaptureError)
    /// Surface a distinct, non-blank error message for an open-file failure other than cancel
    /// (story 39): an unreadable or unsupported file, routed analogously to `presentCaptureFailure`.
    func presentImageLoadFailure(_ error: ImageLoadError)

    /// The recording session changed state (spec 0006, story 11): the menu-bar item mirrors it —
    /// a stop glyph plus the elapsed time while active, the normal icon otherwise. Called on every
    /// transition, including the ones that end a take.
    func presentRecordingState(_ session: RecordingSession)
    /// Show the 3-2-1 countdown (story 10) and return once it reaches zero — or `false` if the user
    /// pressed Escape, in which case the take is discarded before anything is recorded.
    func runRecordingCountdown(seconds: Int) async -> Bool
    /// Ask before throwing the current take away for a fresh one (story 14). The app's alert offers
    /// "don't ask again", which clears `RecordingDefaults.confirmBeforeDiscard`.
    func confirmRecordingRestart() async -> Bool
    /// Ask before deleting the current take (story 14); same "don't ask again" contract.
    func confirmRecordingDiscard() async -> Bool
    /// The microphone vanished mid-take (story 24): `true` to keep recording without audio, `false`
    /// to stop now.
    func resolveMicrophoneDisconnected() async -> Bool
    /// A recording was saved at `url` without an overlay ("save silently", story 33).
    func presentRecordingFinished(at url: URL)
    /// Show the post-recording overlay for a take still in scratch (story 32). The overlay drives
    /// the outcome through `copyPendingRecordingFile`, `savePendingRecording(as:)`,
    /// `deletePendingRecording` and `dismissPendingRecording`.
    func presentPostRecordingOverlay(_ recording: PendingRecording)
    /// Open the saved recording in the video editor (story 33; the editor itself is R14).
    func openVideoEditor(at url: URL)
    /// Surface a distinct, non-blank message for a recording failure other than permission/cancel.
    func presentRecordingFailure(_ error: RecordingError)
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
    private let recordingService: RecordingService?
    private let mediaSink: MediaSink?
    private let scratchDirectory: URL
    private let sleep: (TimeInterval) async -> Void
    private let clock: () -> TimeInterval
    private unowned let ui: CaptureUI

    /// The one recording session (spec 0006). A value type driven only from here: every command
    /// moves the session first, then the `RecordingService` does the matching OS work, so an
    /// illegal command never reaches the encoder. Read by the app shell for the menu-bar timer.
    public private(set) var recordingSession = RecordingSession()
    /// True while `startRecording` is awaiting the service's `start`, so a hotkey press in that
    /// window is ignored rather than stopping a stream that hasn't been handed back yet. The
    /// countdown is *not* covered: stopping during it is a legitimate discard.
    private var isStartingRecording = false

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
        recordingService: RecordingService? = nil,
        mediaSink: MediaSink? = nil,
        scratchDirectory: URL = FileManager.default.temporaryDirectory,
        sleep: @escaping (TimeInterval) async -> Void = { seconds in
            try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
        },
        clock: @escaping () -> TimeInterval = { Date().timeIntervalSinceReferenceDate },
        ui: CaptureUI
    ) {
        self.captureService = captureService
        self.overlay = overlay
        self.imageSource = imageSource
        self.imageSink = imageSink
        self.settings = settings
        self.history = history
        self.recordingService = recordingService
        self.mediaSink = mediaSink
        self.scratchDirectory = scratchDirectory
        self.sleep = sleep
        self.clock = clock
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
            ui.presentPermissionDenied(.screenRecording)
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
            ui.presentPermissionDenied(.screenRecording)
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
        await guideFirstRunAuthorizationIfNeeded(for: captureService)
    }

    /// The same gate against any permission source — the recorder has its own view of the grant.
    private func guideFirstRunAuthorizationIfNeeded(for service: PermissionAuthorizing) async -> Bool {
        guard await service.authorizationStatus() == .notDetermined else { return true }
        return await service.requestAuthorization() == .authorized
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
            ui.presentPermissionDenied(.screenRecording)
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

    // MARK: - Recording (spec 0006)

    /// True from the start of a take until it ends — what the menu-bar item and the Record Screen
    /// row key off.
    public var isRecording: Bool { recordingSession.isActive }

    /// Seconds of footage so far, excluding pauses (story 11's timer).
    public var recordingElapsed: TimeInterval { recordingSession.elapsed(at: clock()) }

    /// The `recordScreen` hotkey / menu row (stories 1–2): one chord opens the recording overlay
    /// when idle, and stops the take in progress otherwise.
    public func toggleRecording() async {
        if isRecording {
            await stopRecording()
        } else {
            await recordScreen()
        }
    }

    /// Record Screen from idle (stories 3–9): the recording overlay runs **first** to resolve a
    /// `RecordingChoice` — a rect, a window or a display (pre-filled with the last one when
    /// "remember last recording area" is on), which Start button was pressed, and the toolbar's
    /// per-recording toggles — and then the take starts on it. Escape (`nil`) is a silent no-op.
    /// The chosen region is remembered for next time.
    public func recordScreen() async {
        guard recordingService != nil, !isRecording, !isStartingRecording else { return }
        let initial = settings.rememberLastRecordingArea ? settings.lastRecordingRegion : nil
        guard let choice = await overlay.selectRecording(initial: initial, defaults: settings.recordingDefaults) else {
            return
        }
        settings.lastRecordingRegion = choice.region
        let microphoneOn = choice.overrides.microphone ?? settings.recordingDefaults.recordMicrophone
        if microphoneOn, settings.recordingDefaults.microphoneDeviceID != choice.microphoneDeviceID {
            // The device picked in the toolbar becomes the default for next time (story 20) — only
            // when the take actually records it, so a mic-off take never forgets the preference.
            settings.recordingDefaults.microphoneDeviceID = choice.microphoneDeviceID
        }
        let cameraOn = choice.overrides.camera ?? settings.recordingDefaults.recordCamera
        if cameraOn, settings.recordingDefaults.cameraDeviceID != choice.cameraDeviceID {
            // Same rule for the camera (story 27).
            settings.recordingDefaults.cameraDeviceID = choice.cameraDeviceID
        }
        await startRecording(region: choice.region, output: choice.output, overrides: choice.overrides)
    }

    /// Start a recording of `region` (stories 1, 6, 8–10). First-run onboarding gates it exactly as
    /// capture does; the Settings defaults plus the toolbar's overrides resolve into this take's
    /// `RecordingOptions`; the session moves first (countdown when configured, else straight to
    /// recording), then the service starts the stream. The countdown is a UI step the user can
    /// Escape out of, which discards the take before anything is recorded. A failure fails the
    /// session and routes like capture: `permissionDenied` to the recovery path, `userCancelled`
    /// silent, the rest to a distinct message. A no-op while a take is already active or when no
    /// recorder is wired.
    public func startRecording(
        region: CaptureRegion, output: RecordingOutputKind = .video, overrides: RecordingOverrides = .none
    ) async {
        guard let recordingService, !isRecording, !isStartingRecording else { return }
        guard await guideFirstRunAuthorizationIfNeeded(for: recordingService) else { return }
        // A take still waiting in the overlay is kept (saved under the pattern) before a new one
        // can replace it — the app moving on is a dismissal (story 32).
        dismissPendingRecording()

        let options = RecordingOptions.resolve(
            region: region, output: output, defaults: settings.recordingDefaults, overrides: overrides
        )
        let url = scratchURL(for: options.output.kind)
        guard (try? recordingSession.start(options, writingTo: url, at: clock())) != nil else { return }
        ui.presentRecordingState(recordingSession)

        guard await runCountdownIfNeeded(options) else { return }
        await startStream(options, writingTo: url)
    }

    /// The countdown step shared by a fresh take and a restart: when the session is counting down,
    /// run the UI countdown and begin recording at zero. Returns whether the stream should start —
    /// `false` when the user escaped (the take is discarded here) or a stop already ended it.
    private func runCountdownIfNeeded(_ options: RecordingOptions) async -> Bool {
        guard recordingSession.state == .countdown else { return recordingSession.state == .recording }
        let completed = await ui.runRecordingCountdown(seconds: options.countdownSeconds)
        // A stop during the countdown already discarded the take (see `stopRecording`).
        guard recordingSession.state == .countdown else { return false }
        guard completed, (try? recordingSession.beginRecording(at: clock())) != nil else {
            _ = try? recordingSession.discard()   // nothing was written: no file to delete
            ui.presentRecordingState(recordingSession)
            return false
        }
        ui.presentRecordingState(recordingSession)
        return true
    }

    /// Ask the service to start streaming — the last step of a fresh take and of a restart. Guarded
    /// so a hotkey press while the service is still handing the stream back is ignored.
    private func startStream(_ options: RecordingOptions, writingTo url: URL) async {
        guard let recordingService else { return }
        isStartingRecording = true
        let outcome = await recordingService.start(options, writingTo: url) { [weak self] event in
            Task { @MainActor in await self?.recordingDidReport(event) }
        }
        isStartingRecording = false
        if case let .failure(error) = outcome {
            failRecording(with: error)
        }
    }

    /// The `pauseResumeRecording` hotkey / pill button (story 13): pause a running take (the timer
    /// freezes, the service stops feeding the writer) or resume a paused one. A no-op otherwise.
    public func pauseResumeRecording() async {
        guard let recordingService, !isStartingRecording else { return }
        switch recordingSession.state {
        case .recording:
            guard (try? recordingSession.pause(at: clock())) != nil else { return }
            await recordingService.pause()
        case .paused:
            guard (try? recordingSession.resume(at: clock())) != nil else { return }
            await recordingService.resume()
        default:
            return
        }
        ui.presentRecordingState(recordingSession)
    }

    /// The `restartRecording` hotkey / pill button (story 14): throw the take away and begin again
    /// with the same options — back through the countdown when one is configured. Legal while
    /// recording or paused; confirmed first unless the user turned the confirmation off.
    public func restartRecording() async {
        guard let recordingService, !isStartingRecording,
              recordingSession.state == .recording || recordingSession.state == .paused
        else { return }
        if settings.recordingDefaults.confirmBeforeDiscard {
            guard await ui.confirmRecordingRestart() else { return }
            guard recordingSession.state == .recording || recordingSession.state == .paused else { return }
        }
        guard (try? recordingSession.restart(at: clock())) != nil, let options = recordingSession.options,
              let url = recordingSession.outputURL
        else { return }
        // The old stream is torn down (and its partial file deleted) by the service. A hotkey stop
        // arriving during that teardown would find no stream, so it is held off until the new one
        // is up — the countdown, if any, stays stoppable as usual.
        isStartingRecording = true
        await recordingService.cancel()
        isStartingRecording = false
        ui.presentRecordingState(recordingSession)

        guard await runCountdownIfNeeded(options) else { return }
        await startStream(options, writingTo: url)
    }

    /// The pill's Discard button (story 14): delete the take and end the session — no history entry,
    /// no overlay. Legal from countdown, recording and paused; confirmed first unless turned off.
    public func discardRecording() async {
        guard let recordingService, !isStartingRecording, isRecording, recordingSession.state != .stopping else { return }
        if settings.recordingDefaults.confirmBeforeDiscard {
            guard await ui.confirmRecordingDiscard() else { return }
            guard isRecording, recordingSession.state != .stopping else { return }
        }
        guard (try? recordingSession.discard()) != nil else { return }
        await recordingService.cancel()   // deletes the partial file
        ui.presentRecordingState(recordingSession)
    }

    /// Something happened mid-take. A dead stream (the display went away, permission was revoked):
    /// the service has torn itself down, so fail the session and route like any failure. A lost
    /// microphone (story 24): the video keeps going while the user decides — continue without
    /// audio, or stop now.
    private func recordingDidReport(_ event: RecordingEvent) async {
        guard isRecording else { return }
        switch event {
        case let .failed(error):
            failRecording(with: error)
        case .audioInputLost:
            let keepGoing = await ui.resolveMicrophoneDisconnected()
            if !keepGoing, isRecording { await stopRecording() }
        }
    }

    /// Stop the take in progress (story 2). The session enters `stopping`, the service finalises
    /// the file, the session finishes with it, and the file moves to the configured save location
    /// (`recordingDestination`). A stop during the countdown discards instead — nothing was written.
    public func stopRecording() async {
        guard let recordingService, isRecording, !isStartingRecording else { return }
        guard let outcome = try? recordingSession.stop(at: clock()) else { return }
        switch outcome {
        case .discarded:
            await recordingService.cancel()   // nothing was written; the service tears down
            ui.presentRecordingState(recordingSession)
        case .stopping:
            ui.presentRecordingState(recordingSession)
            switch await recordingService.stop() {
            case let .success(file):
                try? recordingSession.finish(file)
                ui.presentRecordingState(recordingSession)
                // A GIF take is converted by R13; until then it is delivered as the video the
                // writer produced, under that file's own container extension.
                finished(file)
            case let .failure(error):
                failRecording(with: error)
            }
        }
    }

    /// The take waiting in the post-recording overlay, if one is up (stories 32–34).
    public private(set) var pendingRecording: PendingRecording?

    /// A take finished: route it by the after-recording setting (story 33). The overlay path keeps
    /// the file in scratch until the overlay decides; the other two save at once.
    private func finished(_ file: URL) {
        let kind = recordingSession.options?.output.kind ?? .video
        let recording = PendingRecording(file: file, kind: kind, duration: recordingSession.elapsed(at: clock()))
        switch settings.recordingDefaults.afterRecording {
        case .showOverlay:
            pendingRecording = recording
            ui.presentPostRecordingOverlay(recording)
        case .saveSilently:
            if let saved = deliver(file, as: nil) { ui.presentRecordingFinished(at: saved) }
        case .openEditor:
            if let saved = deliver(file, as: nil) { ui.openVideoEditor(at: saved) }
        }
    }

    /// Move the finished file to its destination — the save location + filename pattern, or the
    /// name the overlay's Rename gave it — and return where it landed. A save failure is a
    /// recording failure with a distinct message; the file stays in the scratch directory rather
    /// than vanishing.
    @discardableResult
    private func deliver(_ file: URL, as name: String?) -> URL? {
        guard let mediaSink else { return nil }
        let destination = name.map { settings.recordingDestination(named: $0, pathExtension: file.pathExtension) }
            ?? settings.recordingDestination(pathExtension: file.pathExtension)
        do {
            try mediaSink.save(file, to: destination)
            return destination
        } catch {
            ui.presentRecordingFailure(.systemFailure(error.localizedDescription))
            return nil
        }
    }

    // MARK: - Post-recording overlay (stories 32–34)

    /// Copy file: the take is saved first (under `name`, or the pattern) and the saved file's
    /// reference goes on the pasteboard — a reference to the scratch file would dangle once the
    /// overlay went and moved it. Returns where it landed; `nil` on a failed save (still pending).
    @discardableResult
    public func copyPendingRecordingFile(as name: String? = nil) -> URL? {
        guard let saved = savePendingRecording(as: name) else { return nil }
        mediaSink?.copyFile(at: saved)
        return saved
    }

    /// Save (or a dismissal, which keeps the file): move to the default location under the pattern,
    /// or under `name` when the overlay's Rename changed it. Returns where it landed, `nil` on a
    /// failure (the take stays pending so nothing is lost).
    @discardableResult
    public func savePendingRecording(as name: String? = nil) -> URL? {
        guard let pendingRecording else { return nil }
        guard let saved = deliver(pendingRecording.file, as: name) else { return nil }
        self.pendingRecording = nil
        return saved
    }

    /// The overlay went away without a decision (Escape, timeout, the app moving on): the file is
    /// kept, under the name typed so far or the pattern (story 32).
    public func dismissPendingRecording(as name: String? = nil) {
        savePendingRecording(as: name)
    }

    /// Delete: the take is thrown away. Returns whether it is gone; a failure to trash it surfaces
    /// and leaves it pending.
    @discardableResult
    public func deletePendingRecording() -> Bool {
        guard let pendingRecording, let mediaSink else { return false }
        do {
            try mediaSink.trash(pendingRecording.file)
            self.pendingRecording = nil
            return true
        } catch {
            ui.presentRecordingFailure(.systemFailure(error.localizedDescription))
            return false
        }
    }

    /// Fail the session (keeping its elapsed time for diagnostics) and route the error the way
    /// capture does: recovery for a missing permission, silence for a cancel, a message otherwise.
    /// The service has already deleted its partial file on every failure path.
    private func failRecording(with error: RecordingError) {
        try? recordingSession.fail(error, at: clock())
        ui.presentRecordingState(recordingSession)
        switch error {
        case let .permissionDenied(kind):
            ui.presentPermissionDenied(kind)
        case .userCancelled:
            break
        default:
            ui.presentRecordingFailure(error)
        }
    }

    /// Where in-progress takes live: the finished one is moved out by `deliver`, a discarded or
    /// failed one is deleted by the service, and anything left over at launch is a crashed take
    /// for the app's recovery to pick up (story 18). Callers should pass a durable
    /// `scratchDirectory` (Application Support, not a temp dir the OS purges).
    public var recordingScratchDirectory: URL {
        scratchDirectory.appendingPathComponent("Lightshot Recordings", isDirectory: true)
    }

    /// A fresh file for the writer under the scratch directory. The directory itself is created
    /// here (Foundation, like `HistoryStore`).
    private func scratchURL(for kind: RecordingOutputKind) -> URL {
        let directory = recordingScratchDirectory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
            .appendingPathComponent("Recording-\(UUID().uuidString)")
            .appendingPathExtension("mp4")
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
