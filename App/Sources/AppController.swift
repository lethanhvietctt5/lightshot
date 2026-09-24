import AppKit
import SwiftUI
import UniformTypeIdentifiers
import LightshotKit

/// A display the fullscreen menu can target (story 8): the window server's id plus a label to show.
/// `Identifiable` so the menu can list them.
struct DisplayInfo: Identifiable {
    let id: UInt32
    let name: String
}

/// The OS-side composition root and `CaptureUI`.
///
/// Owns the `AppCoordinator` (passing itself as the UI delegate) and turns the coordinator's
/// abstract outcomes into real AppKit surfaces: an editor window, a permission-recovery alert with
/// a System-Settings deep link, and a generic failure alert. The domain core stays framework-free;
/// all the AppKit lives here.
@MainActor
final class AppController: NSObject, CaptureUI {
    private var coordinator: AppCoordinator!
    private var editorWindow: NSWindow?
    private var historyWindow: NSWindow?
    private var onboardingWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private let postCaptureToolbar = PostCaptureToolbarController()
    /// The post-recording overlay (spec 0006, stories 32–34), the GIF progress popup (37–38) and
    /// the video editor window (35–36).
    private let postRecordingOverlay = PostRecordingOverlayController()
    private let gifConversion = GIFConversionController()
    /// The "preparing your recording" popup while a take is rendered for sharing (spec 0007, S8).
    private let recordingPreparation = GIFConversionController()
    private let videoEditor = VideoEditorController()
    private let hotkeyService = CarbonHotkeyService()
    private let pinBoard = PinBoardController()

    /// The ScreenCaptureKit service, held once so the same instance backs both the capture spine and
    /// the permission-onboarding checklist (LIG-21) — they share one view of the Screen Recording
    /// grant, including the "have we asked yet?" flag that tells `.notDetermined` from `.denied`.
    private let captureService = SCCaptureService(includeCursor: {
        // Read the cursor-inclusion preference live at capture time (story 12), off the main actor,
        // from the same defaults the settings window writes.
        UserDefaultsSettingsStore.storedIncludeCursor()
    })

    /// The ScreenCaptureKit stream → MP4 recorder (spec 0006, R2) and the one file sink every
    /// recording path (delivery, recovery, history copy) goes through.
    private let recordingService: SCRecordingService
    private let mediaSink = SystemMediaSink()
    /// The microphones the recorder toolbar lists (story 20).
    private let audioInputService = AVAudioInputService()
    /// The cameras it lists (story 27), and the preview bubble shared between the toolbar, the take
    /// and the recorder (stories 26–28).
    private let cameraService = AVCameraService()
    private let cameraBubble: CameraBubbleController
    /// The 3-2-1 before a take (story 10).
    private let countdown = CountdownOverlayController()
    /// The pause / stop / restart / discard pill (stories 12–15), and the red border and outside-the-
    /// frame dimming around the recording area (story 16, LIG-65).
    private let recordingControls = RecordingControlsController()
    private let recordingFrame = RecordingFrameController()
    private let textCaptureNotice = TextCaptureNoticeController()
    /// The previous recording state, so `presentRecordingState` can play the start / stop cues on
    /// the transitions that deserve them.
    private var lastRecordingState: RecordingSession.State = .idle

    /// Told on every recording transition, so the status item can show the stop glyph + timer
    /// (story 11). Set by `StatusMenuController`, which owns the status item.
    var recordingStateObserver: ((RecordingSession) -> Void)?

    override init() {
        // Tool names show the moment the pointer is over a button (spec 0004, story 10). The
        // editor's tools live in the window toolbar (LIG-46), where a hand-drawn tag would be
        // clipped, so the system tooltip itself is made near-instant — registered, not persisted.
        UserDefaults.standard.register(defaults: ["NSInitialToolTipDelay": 80])
        let cameraFeed = CameraFeed()
        recordingService = SCRecordingService(cameraFeed: cameraFeed)
        cameraBubble = CameraBubbleController(feed: cameraFeed)
        super.init()
        cameraBubble.onAnchorChanged = { [weak self] anchor in
            // Where the bubble was dragged becomes the default for next time (story 27).
            self?.settings.recordingDefaults.cameraBubble.anchor = anchor
        }
        coordinator = AppCoordinator(
            captureService: captureService,
            overlay: OverlaySelectionController(
                openSettings: { [weak self] in self?.showSettings() },
                permissionGate: { [weak self] toggle in await self?.ensurePermission(for: toggle) ?? false },
                permissionStatus: { [weak self] toggle in await self?.permissionStatus(for: toggle) ?? .authorized },
                audioInputs: { [audioInputService] in await audioInputService.availableInputs() },
                cameras: { [cameraService] in await cameraService.availableCameras() },
                cameraBubble: cameraBubble
            ),
            imageSource: FileImageSource(),
            imageSink: SystemImageSink(),
            settings: settings,
            history: history,
            recordingService: recordingService,
            mediaSink: mediaSink,
            gifEncoder: ImageIOGIFEncoder(),
            mediaMetadata: AVMediaMetadata(),
            scratchDirectory: Self.supportDirectory,
            studioProjects: StudioProjectStore(directory: Self.studioProjectsDirectory),
            studioFlattener: StudioFlattener(store: StudioProjectStore(directory: Self.studioProjectsDirectory)),
            textRecognizer: VisionTextRecognizer(),
            ui: self
        )
        // A studio project's export is filed like a finished recording (spec 0007, story 27).
        videoEditor.fileExport = { [weak self] file, name in await self?.coordinator.fileStudioExport(at: file, named: name) }
        videoEditor.ensureSpeechPermission = { [weak self] in await self?.ensurePermission(.speechRecognition) ?? false }
        // Enforce the persisted retention setting on the history store at launch (story 54): the
        // value lives in `SettingsStore` (LIG-15), the trimming lives here in the `HistoryStore` seam.
        applyRetention(settings.historyRetention)
    }

    private let settings = UserDefaultsSettingsStore()
    private let history = HistoryStore(directory: AppController.historyDirectory)

    /// The settings-window bridge. Editing hotkeys re-registers them through `applyHotkeys` (the OS's
    /// refusals flow back to be surfaced); editing history retention re-trims the store through
    /// `applyRetention`, so the setting the window persists is enforced immediately.
    lazy var settingsModel = SettingsModel(
        store: settings,
        applyHotkeys: { [weak self] bindings in self?.applyHotkeys(bindings) ?? [] },
        applyRetention: { [weak self] retention in self?.applyRetention(retention) },
        applyAppearance: { AppAppearance.apply($0) },
        permissionGate: { [weak self] toggle in await self?.ensurePermission(for: toggle) ?? false }
    )

    /// First-run permission onboarding (LIG-21). The checklist of every permission the app requires,
    /// driven through the pure `PermissionOnboardingModel`. v1 lists only **Screen Recording** — the
    /// Carbon global hotkeys need no Accessibility grant — but it is a list so a future requirement is
    /// one entry, not a rewrite. The source is the shared `captureService`, so the checklist and the
    /// capture spine agree on the grant.
    lazy var onboardingModel = PermissionOnboardingModel(requirements: [
        PermissionOnboardingModel.Requirement(
            kind: .screenRecording,
            title: PermissionKind.screenRecording.settingsTitle,
            rationale: "Required to capture your screen. Without it, screenshots come back black or empty.",
            source: captureService
        )
    ], openSettings: { [weak self] in self?.openSettings(for: $0) })

    /// Apply the configured history retention to the store (stories 50/54). `SettingsStore` owns the
    /// value (persisted by LIG-15); the store owns trimming to it — so this is where the two meet.
    func applyRetention(_ retention: Int) {
        try? history.setRetention(retention)
    }

    /// Register the persisted global hotkeys (story 56). Called once at launch and again whenever the
    /// settings window edits a binding; returns the actions the OS refused so the UI can flag them.
    @discardableResult
    func applyHotkeys(_ bindings: HotkeyBindings) -> [CaptureAction] {
        hotkeyService.register(bindings) { [weak self] action in
            self?.perform(action)
        }
    }

    /// Register the stored hotkeys at startup so the shortcuts work before the settings window is
    /// ever opened.
    func registerStoredHotkeys() {
        applyHotkeys(settings.hotkeys)
    }

    /// The persisted hotkey chords, so the menu-bar menu can show each capture row's current
    /// shortcut (spec 0005) without owning a second copy of the bindings.
    var hotkeys: HotkeyBindings { settings.hotkeys }

    /// Route a fired hotkey to its capture entry point.
    private func perform(_ action: CaptureAction) {
        switch action {
        case .area: captureArea()
        case .window: captureWindow()
        case .fullscreen: captureFullscreen()
        case .repeatLast: repeatLast()
        case .recordScreen: toggleRecording()
        case .captureText: captureText()
        case .pauseResumeRecording: pauseResumeRecording()
        case .restartRecording: restartRecording()
        }
    }

    /// The standard About panel (spec 0005): name, icon, and version from the bundle. Activated
    /// first, like every other window, so it doesn't open behind the frontmost app (LIG-23).
    func showAbout() {
        WindowPresenter.activateApp()
        NSApp.orderFrontStandardAboutPanel(nil)
    }

    /// Menu / hotkey entry point for the fullscreen capture spine. `displayID` targets a specific
    /// display on a multi-monitor setup (story 8); `nil` (the hotkey path) captures the primary one.
    func captureFullscreen(displayID: UInt32? = nil) {
        Task { await coordinator.captureFullscreen(displayID: displayID) }
    }

    /// Menu / hotkey / status-item entry point for Record Screen (spec 0006, stories 1–7): opens the
    /// recording overlay to pick a rect, window or display and starts the take, or stops the one in
    /// progress.
    func toggleRecording() {
        Task {
            await coordinator.toggleRecording()
            // The toolbar chose a take but it never started (onboarding declined, the session
            // refused): no state was presented, so the preview would otherwise linger.
            if coordinator.recordingSession.state == .idle { cameraBubble.hide() }
        }
    }

    /// Hotkey / pill entry points for the recording controls (stories 12–14).
    func pauseResumeRecording() {
        Task { await coordinator.pauseResumeRecording() }
    }

    func restartRecording() {
        Task { await coordinator.restartRecording() }
    }

    func discardRecording() {
        Task { await coordinator.discardRecording() }
    }

    /// Crash recovery at launch (story 18): finalise any take a previous session left behind in the
    /// scratch directory, file it into history like any finished take (story 39), deliver it
    /// through the same sink as a normal take (never overwriting — a name clash gets a numbered
    /// suffix), and surface it.
    func recoverOrphanedRecordings() {
        Task {
            let files = await RecordingRecovery.recover(in: coordinator.recordingScratchDirectory)
            let sink = mediaSink
            var recovered: [URL] = []
            for file in files {
                let recording = await coordinator.archiveRecoveredRecording(at: file)
                let destination = settings.recordingDestination(pathExtension: file.pathExtension).uniqueForFileSystem()
                do {
                    if recording.historyRecordID != nil {
                        try sink.copy(recording.file, to: destination)
                    } else {
                        try sink.save(recording.file, to: destination)
                    }
                    recovered.append(destination)
                } catch {
                    presentRecordingFailure(.systemFailure("A recovered recording could not be saved: \(error.localizedDescription)"))
                }
            }
            guard let first = recovered.first else { return }
            NSWorkspace.shared.activateFileViewerSelecting(recovered)
            let alert = NSAlert()
            alert.messageText = recovered.count == 1 ? "Your recording was recovered" : "Your recordings were recovered"
            alert.informativeText = recovered.count == 1
                ? "Lightshot quit before the recording finished. It was saved as \(first.lastPathComponent)."
                : "Lightshot quit before \(recovered.count) recordings finished. They were saved to \(first.deletingLastPathComponent().path)."
            alert.addButton(withTitle: "OK")
            WindowPresenter.activateApp()
            alert.runModal()
        }
    }

    /// Whether a take is active — the menu row and status item key off this.
    var isRecording: Bool { coordinator.isRecording }

    /// Seconds recorded so far, for the status-item timer.
    var recordingElapsed: TimeInterval { coordinator.recordingElapsed }

    /// Whether the status item shows the elapsed time beside the stop glyph (story 11, Settings).
    var showsRecordingTimeInMenuBar: Bool { settings.recordingDefaults.showRecordingTimeInMenuBar }

    /// Menu / hotkey entry point for re-firing the last capture mode (story 9).
    func repeatLast() {
        Task { await coordinator.repeatLastCapture() }
    }

    /// Menu / hotkey entry point for area capture: overlay → capture → post-capture toolbar.
    func captureArea() {
        Task { await coordinator.captureArea() }
    }

    /// Menu / hotkey entry point for OCR Text (spec 0010): overlay → capture → recognised text on
    /// the clipboard.
    func captureText() {
        Task { await coordinator.captureText() }
    }

    /// Menu / hotkey entry point for window capture: hover-highlight overlay → capture → toolbar.
    func captureWindow() {
        Task { await coordinator.captureWindow() }
    }

    /// The attached displays, so the menu can offer a per-display fullscreen choice on a multi-monitor
    /// setup (story 8). Maps each `NSScreen` to its `CGDirectDisplayID` — the same id `SCCaptureService`
    /// matches against `SCDisplay.displayID` — plus a human label. A screen with no resolvable id is
    /// dropped (it can't be targeted); the menu falls back to the plain, primary-display action when
    /// fewer than two remain.
    func availableDisplays() -> [DisplayInfo] {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        return NSScreen.screens.enumerated().compactMap { index, screen in
            guard let id = screen.deviceDescription[key] as? CGDirectDisplayID else { return nil }
            let name = screen.localizedName.isEmpty ? "Display \(index + 1)" : screen.localizedName
            return DisplayInfo(id: UInt32(id), name: name)
        }
    }

    /// Menu entry point for opening an existing image file (story 39): file picker → editor. The
    /// panel is modal (synchronous), so unlike the capture spine this needs no `Task`.
    func openFile() {
        coordinator.openFile()
    }

    /// Menu entry point for the capture history window (stories 50–54). Reuses a single window;
    /// the view refreshes its snapshot from the store whenever the window becomes key.
    func showHistory() {
        let window = historyWindow ?? makeHistoryWindow()
        if window.contentViewController == nil {
            let model = HistoryModel(
                store: history,
                // Opening an item hands over to its editor, so History gets out of the way.
                onReopen: { [weak self] in
                    self?.openEditor(with: $0)
                    self?.historyWindow?.close()
                },
                onCopy: { [weak self] in self?.coordinator.copyToClipboard(AnnotationDocument(baseImage: $0)) },
                onReopenRecording: { [weak self] in
                    self?.coordinator.reopenRecording($0)
                    self?.historyWindow?.close()
                },
                onCopyFile: { [mediaSink] in mediaSink.copyFile(at: $0) }
            )
            let hosting = NSHostingController(rootView: HistoryView(model: model))
            // The window keeps the size set here; the grid reflows to fill it.
            hosting.sizingOptions = []
            window.contentViewController = hosting
            window.setContentSize(Self.historyContentSize(on: window.screen ?? NSScreen.main))
            window.center()
        }
        historyWindow = window

        WindowPresenter.present(window)
    }

    /// Menu entry point for the settings window (story 60). A controller-owned window presented
    /// like history and onboarding, rather than SwiftUI's `Settings` scene: that scene opens with no
    /// activation at all, so in this `LSUIElement` app it landed behind the frontmost app (LIG-23).
    func showSettings() {
        let window = settingsWindow ?? makeSettingsWindow()
        if window.contentViewController == nil {
            let hosting = NSHostingController(rootView: SettingsView(model: settingsModel))
            // The pane's name becomes the window title, shown in the toolbar beside the sidebar.
            hosting.sceneBridgingOptions = [.title, .toolbars]
            // The window keeps the size set here; the panes scroll.
            hosting.sizingOptions = []
            window.contentViewController = hosting
            window.setContentSize(NSSize(width: 820, height: 640))
            window.center()
        }
        settingsWindow = window

        WindowPresenter.present(window)
    }

    // MARK: - Permission onboarding (LIG-21)

    /// Show first-run onboarding at launch *only* if a required permission is still missing. A
    /// set-up user (standing grant) is never nagged — the checklist is skipped once satisfied, and
    /// LIG-19 still covers a permission revoked later, mid-capture.
    func showPermissionOnboardingIfNeeded() {
        Task {
            await onboardingModel.refresh()
            if !onboardingModel.isSatisfied {
                showPermissionOnboarding()
            }
        }
    }

    /// Open the onboarding checklist. Used both at launch (when a permission is missing) and on
    /// demand from the menu's "Set Up Permissions…" item, so the user can revisit it any time.
    func showPermissionOnboarding() {
        let window = onboardingWindow ?? makeOnboardingWindow()
        if window.contentViewController == nil {
            let view = PermissionOnboardingView(
                model: onboardingModel,
                onClose: { [weak self] in self?.onboardingWindow?.close() }
            )
            window.contentViewController = NSHostingController(rootView: view)
        }
        onboardingWindow = window

        window.center()
        WindowPresenter.present(window)
    }

    /// Deep-link to the System Settings pane for a permission the user must grant by hand.
    private func openSettings(for kind: PermissionKind) {
        NSWorkspace.shared.open(kind.systemSettingsURL)
    }

    /// The OS source for each grant the recording features ask for lazily (story 41).
    private func permissionSource(for kind: PermissionKind) -> any PermissionAuthorizing {
        switch kind {
        case .screenRecording: return captureService
        case .microphone: return AVCapturePermission.microphone
        case .camera: return AVCapturePermission.camera
        case .inputMonitoring: return InputMonitoringPermission()
        case .speechRecognition: return SpeechRecognitionPermission()
        }
    }

    /// The recorder toolbar's gate: switching a toggle on asks for its grant right then through the
    /// shared `PermissionGate` policy — a standing grant passes, a prompt in progress keeps the
    /// toggle off for now, a decline (now or earlier) shows the recovery for **that** grant.
    /// Returns whether the toggle may go on.
    /// A toggle's standing grant, read without prompting — the toolbar badges the missing ones.
    func permissionStatus(for toggle: RecordingToggle) async -> CaptureAuthorizationStatus {
        guard let kind = toggle.requiredPermission else { return .authorized }
        return await permissionSource(for: kind).authorizationStatus()
    }

    func ensurePermission(for toggle: RecordingToggle) async -> Bool {
        guard let kind = toggle.requiredPermission else { return true }
        return await ensurePermission(kind)
    }

    /// Any grant, through the same gate — the Studio editor's Speech Recognition (spec 0007).
    func ensurePermission(_ kind: PermissionKind) async -> Bool {
        switch await PermissionGate.ensure(permissionSource(for: kind)) {
        case .granted:
            return true
        case .prompting:
            return false
        case .denied:
            presentPermissionDenied(kind)
            return false
        }
    }

    // MARK: - CaptureUI

    func presentPostCaptureToolbar(for image: CapturedImage, at region: CaptureRegion) {
        // Wire the toolbar's actions to capabilities that already exist: annotate opens the editor
        // (story 13's `openEditor(with:)`), copy flattens the un-annotated capture through the same
        // render → clipboard path the editor uses, discard just dismisses.
        postCaptureToolbar.present(
            at: region,
            annotate: { [weak self] in self?.openEditor(with: image) },
            copy: { [weak self] in self?.coordinator.copyToClipboard(AnnotationDocument(baseImage: image)) },
            pin: { [weak self] in self?.pin(AnnotationDocument(baseImage: image)) }
        )
    }

    func openEditor(with image: CapturedImage) {
        let document = AnnotationDocument(baseImage: image)
        let view = EditorView(
            document: document,
            onCopy: { [weak self] in self?.coordinator.copyToClipboard($0) },
            onDone: { [weak self] in
                self?.coordinator.copyToClipboard($0)
                self?.editorWindow?.close()
            },
            onSaveAs: { [weak self] in self?.saveAs($0) }
        )
        let window = editorWindow ?? makeEditorWindow()
        let hosting = NSHostingController(rootView: view)
        // The tools, options and actions are SwiftUI toolbar items in the window's toolbar.
        hosting.sceneBridgingOptions = [.toolbars]
        window.contentViewController = hosting
        window.setContentSize(Self.editorContentSize(on: window.screen ?? NSScreen.main))
        window.center()
        editorWindow = window

        // While the editor is open Lightshot is a regular app — Dock icon, ⌘-Tab entry, app menu —
        // so the window can be found and switched to like any other. `editorWindowWillClose`
        // returns it to a menu-bar-only accessory (unless the video editor is still open).
        WindowPresenter.present(window, asRegularApp: true)
    }

    @objc private func editorWindowWillClose(_ notification: Notification) {
        WindowPresenter.regularWindowClosed()
    }

    /// The editor's opening size: roomy by default, but never larger than the screen allows.
    private static func editorContentSize(on screen: NSScreen?) -> NSSize {
        let preferred = NSSize(width: 1180, height: 800)
        guard let visible = screen?.visibleFrame.size else { return preferred }
        return NSSize(
            width: min(preferred.width, visible.width * 0.9),
            height: min(preferred.height, visible.height * 0.85)
        )
    }

    func presentPermissionDenied(_ kind: PermissionKind) {
        let alert = NSAlert()
        alert.messageText = "\(kind.settingsTitle) permission needed"
        alert.informativeText = "\(kind.recoveryReason) Open System Settings, enable Lightshot under \(kind.settingsTitle), then try again."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")

        WindowPresenter.activateApp()
        if alert.runModal() == .alertFirstButtonReturn {
            openSettings(for: kind)
        }
    }

    func presentTextCaptureStatus(_ status: TextCaptureStatus) {
        textCaptureNotice.show(status)
    }

    func presentCaptureFailure(_ error: CaptureError) {
        let alert = NSAlert()
        alert.messageText = "Couldn’t take the screenshot"
        alert.informativeText = Self.message(for: error)
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")

        WindowPresenter.activateApp()
        alert.runModal()
    }

    func presentRecordingState(_ session: RecordingSession) {
        let sounds = settings.recordingDefaults.playSounds
        switch (lastRecordingState, session.state) {
        case (.recording, .recording), (.paused, .paused): break
        case (_, .recording): RecordingSounds.play(.start, enabled: sounds)   // start, and resume
        case (.recording, .paused): RecordingSounds.play(.pause, enabled: sounds)
        case (_, .stopping): RecordingSounds.play(.stop, enabled: sounds)
        case (.countdown, _): countdown.cancel()   // the hotkey stopped the take mid-countdown
        default: break
        }
        lastRecordingState = session.state
        recordingStateObserver?(session)
        updateRecordingSurfaces(session)
    }

    /// The pill, the red border and the dimming follow the session: shown while recording or paused
    /// (the pill and the dimming per Settings), gone otherwise — including during the countdown, when
    /// the user is still setting up.
    private func updateRecordingSurfaces(_ session: RecordingSession) {
        let defaults = settings.recordingDefaults
        switch session.state {
        case .recording, .paused:
            if defaults.showRecordingControls {
                let meter = recordingService.audioMeter
                let systemMeter = recordingService.systemAudioMeter
                recordingControls.show(
                    position: defaults.controlsPosition,
                    isPaused: session.state == .paused,
                    elapsed: { [weak self] in self?.recordingElapsed ?? 0 },
                    audioLevel: session.options?.microphone.isOn == true ? { meter.level } : nil,
                    systemAudioLevel: session.options?.computerAudio == true ? { systemMeter.level } : nil,
                    actions: RecordingControlsController.Actions(
                        pauseResume: { [weak self] in self?.pauseResumeRecording() },
                        stop: { [weak self] in self?.toggleRecording() },
                        restart: { [weak self] in self?.restartRecording() },
                        discard: { [weak self] in self?.discardRecording() }
                    )
                )
            }
            if let region = session.options?.region {
                recordingFrame.show(
                    around: region,
                    dimsOutside: defaults.dimScreenWhileRecording,
                    isPaused: session.state == .paused
                )
            }
        default:
            recordingControls.hide()
            recordingFrame.hide()
        }
        // The camera preview outlives the toolbar for the countdown and the take (the last frames
        // still composite it while stopping); it goes when the take does — finished, failed,
        // discarded, or cancelled mid-countdown.
        switch session.state {
        case .countdown, .recording, .paused: cameraBubble.setLive(true)
        case .stopping: break
        default: cameraBubble.hide()
        }
    }

    func resolveMicrophoneDisconnected() async -> Bool {
        let alert = NSAlert()
        alert.messageText = "Microphone disconnected"
        alert.informativeText = "The microphone stopped delivering audio. Continue recording without it, or stop now?"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Continue Without Audio")
        alert.addButton(withTitle: "Stop Recording")
        WindowPresenter.activateApp()
        return alert.runModal() == .alertFirstButtonReturn
    }

    func confirmRecordingRestart() async -> Bool {
        confirmDiscard(
            title: "Cancel this recording and start a new one?",
            message: "The take so far will be thrown away and the recording will start again.",
            button: "Start Over"
        )
    }

    func confirmRecordingDiscard() async -> Bool {
        confirmDiscard(
            title: "Delete this recording?",
            message: "The take so far will be deleted. This can't be undone.",
            button: "Delete"
        )
    }

    /// A modal confirmation with a "Don't ask again" box that clears `confirmBeforeDiscard`.
    private func confirmDiscard(title: String, message: String, button: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: "Cancel")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Don't ask again"
        WindowPresenter.activateApp()
        let confirmed = alert.runModal() == .alertFirstButtonReturn
        if confirmed, alert.suppressionButton?.state == .on {
            settings.recordingDefaults.confirmBeforeDiscard = false
        }
        return confirmed
    }

    func runRecordingCountdown(seconds: Int) async -> Bool {
        await countdown.run(seconds: seconds, playSounds: settings.recordingDefaults.playSounds)
    }

    /// "Save silently" (story 33): the file is where Settings says; nothing to show.
    func presentRecordingFinished(at url: URL) {}

    /// The post-recording overlay (story 32): its actions report back to the coordinator, which
    /// owns the pending take; Open Video Editor and Trim save it and open the editor.
    func presentPostRecordingOverlay(_ recording: PendingRecording) {
        postRecordingOverlay.present(recording, actions: PostRecordingOverlayController.Actions(
            copy: { [weak self] name in self?.coordinator.copyPendingRecordingFile(as: name) != nil },
            save: { [weak self] name in self?.coordinator.savePendingRecording(as: name) != nil },
            delete: { [weak self] in self?.coordinator.deletePendingRecording() ?? false },
            dismiss: { [weak self] name in self?.coordinator.dismissPendingRecording(as: name) },
            editor: { [weak self] name in self?.coordinator.openPendingRecordingInEditor(as: name) != nil }
        ))
    }

    /// The video editor (stories 35–36), on a saved recording.
    func openVideoEditor(at url: URL, input: URL?) {
        videoEditor.open(url, input: input)
    }

    /// A studio project in the Studio editor (spec 0007, stories 3–4).
    func openStudio(_ project: StudioProject) {
        videoEditor.open(project: project, store: StudioProjectStore(directory: Self.studioProjectsDirectory))
    }

    /// For the menu bar's Studio Projects submenu (story 4).
    func recentStudioProjects() -> [StudioProject] {
        coordinator.recentStudioProjects()
    }

    func openStudioProject(at url: URL) {
        coordinator.openStudioProject(at: url)
    }

    /// Draw in the stored appearance (spec 0008) before any window opens.
    func applyStoredAppearance() {
        AppAppearance.apply(settings.appearance)
    }

    #if DEBUG
    /// Development aid (spec 0008): open one surface without capturing or recording, so it can be
    /// looked at in Light and Dark. `file` is an image (editor, post-capture, pin) or a movie
    /// (post-recording); a generated sample image stands in when it is missing.
    func debugPreviewSurface(_ name: String, file: URL?) {
        let image = file.flatMap { try? FileImageSource().loadImage(from: $0).get() } ?? Self.debugSampleImage()
        switch name {
        case "editor": openEditor(with: image)
        case "settings": showSettings()
        case "history": showHistory()
        case "onboarding": showPermissionOnboarding()
        case "postCapture":
            presentPostCaptureToolbar(for: image, at: .rect(Rect(x: 200, y: 160, width: 640, height: 400)))
        case "pin": pin(AnnotationDocument(baseImage: image))
        case "postRecording":
            guard let file else { return }
            presentPostRecordingOverlay(PendingRecording(file: file, kind: .video, duration: 5, origin: .historyItem(id: UUID())))
        case "preparing": presentRecordingPreparation(cancel: {})
        case "frozenArea", "frozenWindow":
            // Freeze Screen (spec 0011): the selection overlay over `file` as the frozen still,
            // stretched to the main screen, so the backdrop can be looked at without the grant.
            let size = (NSScreen.main ?? NSScreen.screens[0]).frame.size
            let frozen = FrozenScreen(displayID: CGMainDisplayID(), frame: Rect(x: 0, y: 0, width: size.width, height: size.height), image: image)
            let overlay = OverlaySelectionController()
            Task { @MainActor in
                _ = name == "frozenArea" ? await overlay.selectRegion(over: frozen) : await overlay.selectWindow(over: frozen)
            }
        default: break
        }
    }

    /// A colourful 1280×800 stand-in screenshot.
    private static func debugSampleImage() -> CapturedImage {
        let width = 1280, height = 800
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        let colors = [CGColor(srgbRed: 0.2, green: 0.45, blue: 0.9, alpha: 1), CGColor(srgbRed: 0.95, green: 0.5, blue: 0.6, alpha: 1)] as CFArray
        let gradient = CGGradient(colorsSpace: context.colorSpace, colors: colors, locations: [0, 1])!
        context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: width, y: height), options: [])
        context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.9))
        context.fill(CGRect(x: 160, y: 160, width: 960, height: 480))
        let rep = NSBitmapImageRep(cgImage: context.makeImage()!)
        return CapturedImage(pixelWidth: width, pixelHeight: height, data: rep.representation(using: .png, properties: [:])!)
    }

    func debugShowRecordingControls() {
        recordingControls.show(
            position: .bottom, isPaused: false, elapsed: { 12 }, audioLevel: { 0.4 }, systemAudioLevel: nil,
            actions: .init(pauseResume: {}, stop: {}, restart: {}, discard: {})
        )
    }

    /// `-previewRecordingFrame x,y,w,h|display [-previewPaused YES] [-previewDim YES]`: the red
    /// border (LIG-65) around an area (screen points, top-left origin) or the main display.
    func debugShowRecordingFrame(_ spec: String, paused: Bool, dims: Bool) {
        let parts = spec.split(separator: ",").compactMap { Double($0) }
        let region: CaptureRegion = parts.count == 4
            ? .rect(Rect(x: parts[0], y: parts[1], width: parts[2], height: parts[3]))
            : .display(id: CGMainDisplayID())
        recordingFrame.show(around: region, dimsOutside: dims, isPaused: paused)
    }

    func debugShowTextNotice(_ name: String) {
        switch name {
        case "reading": presentTextCaptureStatus(.reading)
        case "none": presentTextCaptureStatus(.noText)
        case "failed": presentTextCaptureStatus(.failed("Text recognition failed: the request was cancelled."))
        default: presentTextCaptureStatus(.copied("The quick brown fox jumps over the lazy dog and keeps running past the fence\nsecond line"))
        }
    }

    func debugSeekStudio(to time: Double) { videoEditor.debugSeek(to: time) }
    func debugStudioPanel(_ name: String) { videoEditor.debugPanel(name) }
    #endif

    /// A take being rendered for sharing (spec 0007, S8): progress with Cancel (which opens the
    /// take's project in the Studio editor instead).
    func presentRecordingPreparation(cancel: @escaping () -> Void) {
        recordingPreparation.show(title: "Preparing your recording…", symbol: "film", cancel: cancel)
    }

    func updateRecordingPreparation(progress: Double) {
        recordingPreparation.update(progress: progress)
    }

    func dismissRecordingPreparation() {
        recordingPreparation.hide()
    }

    func presentGIFConversion(cancel: @escaping () -> Void) {
        gifConversion.show(cancel: cancel)
    }

    func updateGIFConversion(progress: Double) {
        gifConversion.update(progress: progress)
    }

    func dismissGIFConversion() {
        gifConversion.hide()
    }

    func resolveCancelledGIFConversion() async -> Bool {
        gifConversion.resolveCancelled()
    }

    /// Quitting with the overlay up keeps the take (story 32), like any other dismissal; the video
    /// editor drops its backup and cancels an export, as closing its window would.
    func keepPendingRecordingOnQuit() {
        coordinator.dismissPendingRecording()
        videoEditor.prepareForTermination()
    }

    func presentRecordingFailure(_ error: RecordingError) {
        let alert = NSAlert()
        alert.messageText = "Couldn’t record the screen"
        alert.informativeText = Self.message(for: error)
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")

        WindowPresenter.activateApp()
        alert.runModal()
    }

    func presentImageLoadFailure(_ error: ImageLoadError) {
        // The coordinator routes `userCancelled` to a silent no-op, so only the unreadable /
        // unsupported cases reach here — each gets a distinct message, never a blank editor.
        let alert = NSAlert()
        alert.messageText = "Couldn’t open the image"
        alert.informativeText = Self.message(for: error)
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")

        WindowPresenter.activateApp()
        alert.runModal()
    }

    // MARK: - Output (stories 41–45)

    /// Save the flattened document with the configured defaults — no dialog (story 43). On success
    /// the file is revealed in Finder so the user sees where it landed; a write failure surfaces a
    /// distinct alert rather than failing silently.
    private func save(_ document: AnnotationDocument) {
        do {
            let url = try coordinator.save(document)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            presentSaveFailure(error)
        }
    }

    /// Save-As (stories 41–42): an `NSSavePanel` that lets the user pick location, name, and format
    /// (PNG / JPEG). JPEG carries the configured default quality — the per-save override flows
    /// through the same `ImageFormat` value to the sink.
    private func saveAs(_ document: AnnotationDocument) {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.directoryURL = settings.saveLocation
        panel.nameFieldStringValue = FilenameFormatter(pattern: settings.filenamePattern).filename(at: Date())

        let picker = FormatPicker(default: settings.defaultFormat)
        panel.accessoryView = picker.view
        picker.onChange = { [weak panel] format in
            panel?.allowedContentTypes = [format == .png ? .png : .jpeg]
        }
        panel.allowedContentTypes = [settings.defaultFormat == .png ? .png : .jpeg]

        WindowPresenter.activateApp()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try coordinator.save(document, to: url, format: picker.format)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            presentSaveFailure(error)
        }
    }

    /// Pin the flattened document as an always-on-top floating window (stories 46–49). The document
    /// is rendered once for display; the pin's copy/save go back through the coordinator's `ImageSink`
    /// passthrough (`render` is deterministic, so they reproduce exactly what's pinned). Save uses the
    /// no-dialog default-location path and reveals the file in Finder, matching the editor's Save.
    private func pin(_ document: AnnotationDocument) {
        pinBoard.pin(
            render(document),
            copy: { [weak self] in self?.coordinator.copyToClipboard(document) },
            save: { [weak self] in self?.save(document) }
        )
    }

    private func presentSaveFailure(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Couldn’t save the image"
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        WindowPresenter.activateApp()
        alert.runModal()
    }

    // MARK: - Helpers

    private func makeEditorWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.editorContentSize(on: NSScreen.main)),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Lightshot"
        // One compact row (LIG-46): the toolbar sits beside the traffic lights, the title hidden.
        window.titleVisibility = .hidden
        window.toolbar = NSToolbar(identifier: "editor")
        window.toolbarStyle = .unified
        window.isReleasedWhenClosed = false
        NotificationCenter.default.addObserver(
            self, selector: #selector(editorWindowWillClose), name: NSWindow.willCloseNotification, object: window
        )
        return window
    }

    /// The onboarding window (LIG-21): a fixed-size, non-resizable panel — the checklist lays itself
    /// out at a set width. Reused across opens (kept alive after close) so its `PermissionOnboardingView`
    /// and its model survive a dismiss-and-reopen.
    private func makeOnboardingWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 320),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Welcome to Lightshot"
        window.isReleasedWhenClosed = false
        window.center()
        return window
    }

    /// The settings window, shaped like CleanShot's (LIG-44): the sidebar runs under a transparent
    /// title bar, and a unified toolbar carries the selected pane's name.
    private func makeSettingsWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 820, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Lightshot Settings"
        window.titlebarAppearsTransparent = true
        window.toolbar = NSToolbar(identifier: "settings")
        window.toolbarStyle = .unified
        window.isReleasedWhenClosed = false
        return window
    }

    /// Room for five or six columns of thumbnails: most of the screen, up to 1400 × 900.
    private static func historyContentSize(on screen: NSScreen?) -> NSSize {
        let visible = screen?.visibleFrame.size ?? NSSize(width: 1440, height: 900)
        return NSSize(width: min(1400, visible.width * 0.7), height: min(900, visible.height * 0.75))
    }

    private func makeHistoryWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 460),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Capture History"
        window.isReleasedWhenClosed = false
        window.center()
        return window
    }

    /// Lightshot's Application Support folder: per-user, out of the way, and it survives relaunches
    /// and the OS's temp-file purge — which is what in-progress recordings need so a crashed take
    /// is still there to recover days later (story 18).
    private static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        let bundleID = Bundle.main.bundleIdentifier ?? "dev.lightshot.app"
        return base.appendingPathComponent(bundleID, isDirectory: true)
    }

    /// Where the local history keeps its owned image copies + index. Local-only — a v1 guardrail
    /// (no cloud, no accounts).
    /// Where studio projects live (spec 0007): folders the Studio editor opens and autosaves.
    private static var studioProjectsDirectory: URL {
        supportDirectory.appendingPathComponent("Studio Projects", isDirectory: true)
    }

    private static var historyDirectory: URL {
        supportDirectory.appendingPathComponent("History", isDirectory: true)
    }

    private static func message(for error: CaptureError) -> String {
        // Only `presentCaptureFailure` calls this, and the coordinator routes `permissionDenied`
        // and `userCancelled` elsewhere — so those fall through to the generic default.
        switch error {
        case .noDisplayAvailable:
            return "No display was available to capture."
        case .systemFailure(let description):
            return description
        default:
            return "The capture could not be completed."
        }
    }

    private static func message(for error: RecordingError) -> String {
        // `permissionDenied` and `userCancelled` are routed elsewhere by the coordinator.
        switch error {
        case .noDisplayAvailable:
            return "No display was available to record."
        case .diskFull:
            return "The disk is full. Free up some space and try again."
        case let .systemFailure(description):
            return description
        default:
            return "The recording could not be completed."
        }
    }

    private static func message(for error: ImageLoadError) -> String {
        // `userCancelled` is routed to a silent no-op by the coordinator and never reaches here.
        switch error {
        case .unreadable:
            return "The file couldn’t be read."
        case .unsupportedFormat:
            return "That file isn’t an image Lightshot can open."
        case .userCancelled:
            return "Opening the image was cancelled."
        }
    }
}

/// The PNG / JPEG chooser shown as the Save-As panel's accessory view.
///
/// A one-row popup that maps the selection back to an `ImageFormat`. JPEG keeps the quality carried
/// by the `default` format (from settings), so the per-save format still flows through as one value.
@MainActor
private final class FormatPicker {
    let view = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 30))
    var onChange: ((ImageFormat) -> Void)?

    /// JPEG quality to carry through if the user picks JPEG (the settings default, or a fallback).
    private let jpegQuality: Double
    private let popup = NSPopUpButton(frame: NSRect(x: 80, y: 2, width: 150, height: 25), pullsDown: false)

    init(default format: ImageFormat) {
        if case let .jpeg(quality) = format {
            jpegQuality = quality
        } else {
            jpegQuality = 0.9
        }

        let label = NSTextField(labelWithString: "Format:")
        label.frame = NSRect(x: 8, y: 5, width: 68, height: 20)
        label.alignment = .right
        popup.addItems(withTitles: ["PNG", "JPEG"])
        popup.selectItem(at: format == .png ? 0 : 1)
        popup.target = self
        popup.action = #selector(changed)
        view.addSubview(label)
        view.addSubview(popup)
    }

    /// The format the user has selected.
    var format: ImageFormat {
        popup.indexOfSelectedItem == 0 ? .png : .jpeg(clamping: jpegQuality)
    }

    @objc private func changed() { onChange?(format) }
}
