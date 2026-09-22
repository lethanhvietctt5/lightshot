import Testing
import Foundation
@testable import LightshotKit

// Coordinator routing for the recording spine (spec 0006, R2: stories 1, 2, 6, 11, 17, 57–58).
// Fakes stand in for the recorder, the media sink and the UI, so the sequencing — session first,
// then the service; save on finish; recovery on permission denial — runs with no display or TCC.

// MARK: - Fakes

private final class FakeRecordingService: RecordingService, @unchecked Sendable {
    var startResult: Result<Void, RecordingError> = .success(())
    var stopResult: Result<URL, RecordingError>
    var status: CaptureAuthorizationStatus = .authorized
    var requestResult: CaptureAuthorizationStatus = .authorized

    private(set) var starts: [(options: RecordingOptions, url: URL)] = []
    /// The failure callback of the most recent `start`, so a test can simulate the stream dying.
    private(set) var onFailure: (@Sendable (RecordingError) -> Void)?
    /// When set, `start` suspends here until the test resumes it — for the in-flight-start race.
    var startGate: CheckedContinuation<Void, Never>?
    var holdStart = false
    private(set) var stopCount = 0
    private(set) var cancelCount = 0
    private(set) var requestAuthorizationCount = 0

    init(stopResult: Result<URL, RecordingError> = .success(URL(fileURLWithPath: "/tmp/scratch/take.mp4"))) {
        self.stopResult = stopResult
    }

    func authorizationStatus() async -> CaptureAuthorizationStatus { status }
    @discardableResult
    func requestAuthorization() async -> CaptureAuthorizationStatus {
        requestAuthorizationCount += 1
        status = requestResult
        return requestResult
    }
    func start(
        _ options: RecordingOptions, writingTo url: URL,
        onFailure: @escaping @Sendable (RecordingError) -> Void
    ) async -> Result<Void, RecordingError> {
        starts.append((options, url))
        self.onFailure = onFailure
        if holdStart {
            await withCheckedContinuation { startGate = $0 }
        }
        return startResult
    }
    func pause() async {}
    func resume() async {}
    func stop() async -> Result<URL, RecordingError> { stopCount += 1; return stopResult }
    func cancel() async { cancelCount += 1 }
}

private final class SpyMediaSink: MediaSink {
    struct Failure: Error {}
    var saveFails = false
    private(set) var copied: [URL] = []
    private(set) var saves: [(from: URL, to: URL)] = []
    private(set) var removed: [URL] = []
    func copyFile(at url: URL) { copied.append(url) }
    func save(_ url: URL, to destination: URL) throws {
        if saveFails { throw Failure() }
        saves.append((url, destination))
    }
    func removeFile(at url: URL) { removed.append(url) }
}

@MainActor
private final class SpyUI: CaptureUI {
    private(set) var states: [RecordingSession.State] = []
    /// What the countdown UI reports: `true` ran to zero, `false` the user pressed Escape.
    var countdownResult = true
    /// When set, the countdown suspends here until the test resumes it — to act mid-countdown.
    var holdCountdown = false
    var countdownGate: CheckedContinuation<Void, Never>?
    private(set) var countdowns: [Int] = []
    private(set) var finished: [URL] = []
    private(set) var recordingFailures: [RecordingError] = []
    private(set) var permissionDeniedCount = 0

    func openEditor(with image: CapturedImage) {}
    func presentPostCaptureToolbar(for image: CapturedImage, at region: CaptureRegion) {}
    func presentPermissionDenied() { permissionDeniedCount += 1 }
    func presentCaptureFailure(_ error: CaptureError) {}
    func presentImageLoadFailure(_ error: ImageLoadError) {}
    func presentRecordingState(_ session: RecordingSession) { states.append(session.state) }
    func runRecordingCountdown(seconds: Int) async -> Bool {
        countdowns.append(seconds)
        if holdCountdown { await withCheckedContinuation { countdownGate = $0 } }
        return countdownResult
    }
    func presentRecordingFinished(at url: URL) { finished.append(url) }
    func presentRecordingFailure(_ error: RecordingError) { recordingFailures.append(error) }
}

// The capture-side seams are irrelevant here; minimal stubs keep the coordinator constructible.
private final class IdleCaptureService: CaptureService, @unchecked Sendable {
    func authorizationStatus() async -> CaptureAuthorizationStatus { .authorized }
    func requestAuthorization() async -> CaptureAuthorizationStatus { .authorized }
    func captureFullscreen(displayID: UInt32?) async -> Result<CapturedImage, CaptureError> { .failure(.userCancelled) }
    func captureRegion(_ region: CaptureRegion) async -> Result<CapturedImage, CaptureError> { .failure(.userCancelled) }
}
/// Hands back a canned recording choice and records what it was asked to pre-fill / seed with.
@MainActor
private final class StubOverlay: OverlayController {
    var choice: RecordingChoice? = RecordingChoice(region: .display(id: 7), output: .video)
    private(set) var initials: [CaptureRegion?] = []
    private(set) var seededDefaults: [RecordingDefaults] = []
    func selectRegion() async -> CaptureRegion? { nil }
    func selectWindow() async -> CaptureRegion? { nil }
    func selectRecording(initial: CaptureRegion?, defaults: RecordingDefaults) async -> RecordingChoice? {
        initials.append(initial)
        seededDefaults.append(defaults)
        return choice
    }
}
@MainActor
private final class IdleImageSource: ImageSource {
    func loadImage(from url: URL) -> Result<CapturedImage, ImageLoadError> { .failure(.userCancelled) }
    func openDocument() -> Result<CapturedImage, ImageLoadError> { .failure(.userCancelled) }
}
private final class IdleImageSink: ImageSink {
    func copyToClipboard(_ image: RenderedImage) {}
    func write(_ image: RenderedImage, to url: URL, format: ImageFormat) throws {}
}
@MainActor
private final class StubSettings: SettingsStore {
    var defaultFormat: ImageFormat = .png
    var saveLocation = URL(fileURLWithPath: "/tmp/movies", isDirectory: true)
    var filenamePattern = "Recording %Y"
    var hotkeys = HotkeyBindings.defaults
    var openInEditor = true
    var includeCursor = false
    var captureDelay: TimeInterval = 0
    var historyRetention = 50
    var launchAtLogin = false
    var recordingDefaults = RecordingDefaults(countdownEnabled: false)
    var rememberLastRecordingArea = false
    var lastRecordingRegion: CaptureRegion?
}

/// A manual clock and a sleep spy, so countdown and elapsed time are deterministic.
@MainActor
private final class ManualClock {
    var now: TimeInterval = 100
    private(set) var waits: [TimeInterval] = []
    /// When set, a sleep suspends here until the test resumes it — to act mid-countdown.
    var holdSleeps = false
    var sleepGate: CheckedContinuation<Void, Never>?
    func sleep(_ seconds: TimeInterval) async {
        waits.append(seconds)
        if holdSleeps { await withCheckedContinuation { sleepGate = $0 } }
        now += seconds
    }
}

@MainActor
private final class Harness {
    let service: FakeRecordingService
    let sink = SpyMediaSink()
    let ui = SpyUI()
    let settings = StubSettings()
    let clock = ManualClock()
    let overlay = StubOverlay()
    let coordinator: AppCoordinator

    var now: TimeInterval {
        get { clock.now }
        set { clock.now = newValue }
    }
    var waits: [TimeInterval] { clock.waits }

    init(service: FakeRecordingService = FakeRecordingService()) {
        self.service = service
        let clock = self.clock
        coordinator = AppCoordinator(
            captureService: IdleCaptureService(),
            overlay: overlay,
            imageSource: IdleImageSource(),
            imageSink: IdleImageSink(),
            settings: settings,
            recordingService: service,
            mediaSink: sink,
            scratchDirectory: URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true),
            sleep: { seconds in await clock.sleep(seconds) },
            clock: { clock.now },
            ui: ui
        )
    }
}

private let display = CaptureRegion.display(id: 7)

// MARK: - Start / stop (stories 1, 2, 6)

@Test @MainActor func toggleStartsAVideoRecordingOfTheDisplayAndReportsTheState() async {
    let h = Harness()
    await h.coordinator.toggleRecording()

    #expect(h.coordinator.isRecording)
    #expect(h.service.starts.count == 1)
    #expect(h.service.starts.first?.options.region == display)
    #expect(h.service.starts.first?.options.output.kind == .video)
    #expect(h.service.starts.first?.url.pathExtension == "mp4")
    #expect(h.ui.states == [.recording])
    #expect(h.waits.isEmpty)   // no countdown configured
}

@Test @MainActor func toggleAgainStopsFinishesAndSavesToTheDefaultDestination() async {
    let h = Harness()
    await h.coordinator.toggleRecording()
    h.now = 130
    await h.coordinator.toggleRecording()

    #expect(!h.coordinator.isRecording)
    #expect(h.service.stopCount == 1)
    #expect(h.coordinator.recordingSession.state == .finished(URL(fileURLWithPath: "/tmp/scratch/take.mp4")))
    #expect(h.coordinator.recordingElapsed == 30)
    #expect(h.sink.saves.count == 1)
    #expect(h.sink.saves.first?.from == URL(fileURLWithPath: "/tmp/scratch/take.mp4"))
    // Configured save location + filename pattern + the container's extension.
    #expect(h.sink.saves.first?.to.deletingLastPathComponent().path == "/tmp/movies")
    #expect(h.sink.saves.first?.to.pathExtension == "mp4")
    #expect(h.sink.saves.first?.to.lastPathComponent.hasPrefix("Recording ") == true)
    #expect(h.ui.finished == h.sink.saves.map(\.to))
    #expect(h.ui.states == [.recording, .stopping, .finished(URL(fileURLWithPath: "/tmp/scratch/take.mp4"))])
}

@Test @MainActor func aSecondStartWhileActiveAndAStopWhileIdleAreNoOps() async {
    let h = Harness()
    await h.coordinator.stopRecording()
    #expect(h.service.stopCount == 0)

    await h.coordinator.startRecording(region: display)
    await h.coordinator.startRecording(region: display)
    #expect(h.service.starts.count == 1)
}

@Test @MainActor func elapsedTimeFollowsTheClockWhileRecording() async {
    let h = Harness()
    await h.coordinator.startRecording(region: display)
    h.now = 112.5
    #expect(h.coordinator.recordingElapsed == 12.5)
}

@Test @MainActor func aStopWhileStartIsStillInFlightIsIgnored() async {
    // The hotkey can fire again before the service has handed the stream back; that press must
    // not stop a stream the service hasn't returned yet (nor fail the session).
    let h = Harness()
    h.service.holdStart = true
    let starting = Task { await h.coordinator.startRecording(region: display) }
    while h.service.startGate == nil { await Task.yield() }

    await h.coordinator.toggleRecording()                  // arrives mid-start
    #expect(h.service.stopCount == 0)
    #expect(h.coordinator.isRecording)

    h.service.startGate?.resume()
    await starting.value
    #expect(h.coordinator.recordingSession.state == .recording)

    await h.coordinator.stopRecording()                     // a normal stop still works afterwards
    #expect(h.service.stopCount == 1)
}

@Test @MainActor func aStopDuringTheCountdownDiscardsAndDeletesTheScratchFile() async {
    let h = Harness()
    h.settings.recordingDefaults = RecordingDefaults(countdownEnabled: true, countdownSeconds: 3)
    h.ui.holdCountdown = true
    let starting = Task { await h.coordinator.startRecording(region: display) }
    while h.ui.countdownGate == nil { await Task.yield() }
    #expect(h.coordinator.recordingSession.state == .countdown)

    await h.coordinator.stopRecording()      // the hotkey during the countdown
    h.ui.countdownGate?.resume()
    await starting.value

    #expect(h.service.cancelCount == 1)
    #expect(h.service.stopCount == 0)
    #expect(h.service.starts.isEmpty)                 // the stream never started
    #expect(h.sink.removed.count == 1)
    #expect(h.sink.removed.first?.pathExtension == "mp4")
    #expect(h.coordinator.recordingSession.state == .idle)
    #expect(h.ui.states.last == .idle)
}

@Test @MainActor func aStreamDyingMidTakeFailsTheSessionDeletesThePartialAndRestoresTheStatusItem() async {
    let h = Harness()
    await h.coordinator.startRecording(region: display)
    h.service.onFailure?(.systemFailure("display disconnected"))
    await Task.yield()
    while h.coordinator.isRecording { await Task.yield() }

    #expect(h.coordinator.recordingSession.state == .failed(.systemFailure("display disconnected")))
    #expect(h.ui.recordingFailures == [.systemFailure("display disconnected")])
    #expect(h.sink.removed == h.service.starts.map(\.url))
    #expect(h.ui.states.last == .failed(.systemFailure("display disconnected")))
    #expect(h.service.stopCount == 0)
}

// MARK: - Recording overlay (stories 3–7)

@Test @MainActor func recordScreenRunsTheOverlayFirstAndStartsOnItsRegion() async {
    let h = Harness()
    let rect = CaptureRegion.rect(Rect(x: 10, y: 20, width: 640, height: 360))
    h.overlay.choice = RecordingChoice(region: rect, output: .video)
    await h.coordinator.recordScreen()

    #expect(h.overlay.initials == [nil])                 // nothing to remember yet
    #expect(h.overlay.seededDefaults == [h.settings.recordingDefaults])   // toggles seed from Settings
    #expect(h.service.starts.first?.options.region == rect)
    #expect(h.coordinator.isRecording)
}

@Test @MainActor func theToolbarsOutputAndTogglesReachTheServiceWithoutTouchingSettings() async {
    let h = Harness()
    h.overlay.choice = RecordingChoice(
        region: display, output: .gif, overrides: RecordingOverrides(microphone: true, highlightClicks: true)
    )
    await h.coordinator.recordScreen()

    let options = h.service.starts.first?.options
    #expect(options?.output.kind == .gif)
    #expect(options?.microphone == .device(id: nil))
    #expect(options?.highlightClicks == true)
    #expect(options?.computerAudio == false)              // untouched toggles keep the default
    #expect(h.settings.recordingDefaults == RecordingDefaults(countdownEnabled: false))   // not written back

    // Until R13 converts it, a GIF take is delivered as the MP4 the writer produced.
    await h.coordinator.stopRecording()
    #expect(h.sink.saves.first?.to.pathExtension == "mp4")
}

@Test @MainActor func escapeInTheOverlayIsASilentNoOp() async {
    let h = Harness()
    h.overlay.choice = nil
    await h.coordinator.recordScreen()
    #expect(h.service.starts.isEmpty)
    #expect(!h.coordinator.isRecording)
    #expect(h.ui.states.isEmpty)
    #expect(h.settings.lastRecordingRegion == nil)
}

@Test @MainActor func theChosenRegionIsRememberedAndPreFilledOnlyWhenTheSettingIsOn() async {
    let h = Harness()
    let window = CaptureRegion.window(id: 42, frame: Rect(x: 0, y: 0, width: 800, height: 600))
    h.overlay.choice = RecordingChoice(region: window, output: .video)
    await h.coordinator.recordScreen()
    #expect(h.settings.lastRecordingRegion == window)   // always kept …
    await h.coordinator.stopRecording()

    await h.coordinator.recordScreen()
    #expect(h.overlay.initials == [nil, nil])           // … but only offered when the setting is on
    await h.coordinator.stopRecording()

    h.settings.rememberLastRecordingArea = true
    await h.coordinator.recordScreen()
    #expect(h.overlay.initials.last == window)
}

// MARK: - Countdown (story 10)

@Test @MainActor func aConfiguredCountdownRunsInTheUIThenBeginsRecording() async {
    let h = Harness()
    h.settings.recordingDefaults = RecordingDefaults(countdownEnabled: true, countdownSeconds: 3)
    await h.coordinator.startRecording(region: display)

    #expect(h.ui.countdowns == [3])
    #expect(h.ui.states == [.countdown, .recording])
    #expect(h.service.starts.count == 1)
    #expect(h.service.starts.first?.options.countdownSeconds == 3)
    #expect(h.coordinator.recordingElapsed == 0)   // the countdown itself is not footage
}

@Test @MainActor func escapeDuringTheCountdownDiscardsBeforeAnythingIsRecorded() async {
    let h = Harness()
    h.settings.recordingDefaults = RecordingDefaults(countdownEnabled: true, countdownSeconds: 3)
    h.ui.countdownResult = false
    await h.coordinator.startRecording(region: display)

    #expect(h.service.starts.isEmpty)
    #expect(h.service.cancelCount == 0)                  // nothing was ever started
    #expect(h.sink.removed.count == 1)
    #expect(h.coordinator.recordingSession.state == .idle)
    #expect(h.ui.states == [.countdown, .idle])
}

// MARK: - Error routing (stories 57–58)

@Test @MainActor func permissionDeniedOnStartRoutesToRecoveryAndFailsTheSession() async {
    let h = Harness()
    h.service.startResult = .failure(.permissionDenied(.screenRecording))
    await h.coordinator.startRecording(region: display)

    #expect(h.ui.permissionDeniedCount == 1)
    #expect(h.ui.recordingFailures.isEmpty)
    #expect(h.coordinator.recordingSession.state == .failed(.permissionDenied(.screenRecording)))
    #expect(!h.coordinator.isRecording)
    #expect(h.sink.saves.isEmpty)
    #expect(h.sink.removed.count == 1)                              // no scratch file left behind
    #expect(h.ui.states.last == .failed(.permissionDenied(.screenRecording)))   // status item reverts
}

@Test @MainActor func userCancelledIsSilentAndOtherFailuresGetADistinctMessage() async {
    let cancelled = Harness()
    cancelled.service.startResult = .failure(.userCancelled)
    await cancelled.coordinator.startRecording(region: display)
    #expect(cancelled.ui.recordingFailures.isEmpty)
    #expect(cancelled.ui.permissionDeniedCount == 0)

    let broken = Harness()
    broken.service.startResult = .failure(.noDisplayAvailable)
    await broken.coordinator.startRecording(region: display)
    #expect(broken.ui.recordingFailures == [.noDisplayAvailable])
    #expect(broken.coordinator.recordingSession.state == .failed(.noDisplayAvailable))
}

@Test @MainActor func aStopFailureFailsTheSessionWithAMessageAndSavesNothing() async {
    let h = Harness(service: FakeRecordingService(stopResult: .failure(.diskFull)))
    await h.coordinator.startRecording(region: display)
    await h.coordinator.stopRecording()

    #expect(h.ui.recordingFailures == [.diskFull])
    #expect(h.coordinator.recordingSession.state == .failed(.diskFull))
    #expect(h.sink.saves.isEmpty)
    #expect(h.ui.finished.isEmpty)
}

@Test @MainActor func aSaveFailureIsSurfacedAndTheTakeStaysFinished() async {
    let h = Harness()
    h.sink.saveFails = true
    await h.coordinator.startRecording(region: display)
    await h.coordinator.stopRecording()

    #expect(h.ui.finished.isEmpty)
    #expect(h.ui.recordingFailures.count == 1)
    if case .systemFailure = h.ui.recordingFailures.first {} else {
        Issue.record("expected a systemFailure describing the save error")
    }
    if case .finished = h.coordinator.recordingSession.state {} else {
        Issue.record("the file exists; the session should still be finished")
    }
}

// MARK: - First-run onboarding (story 57)

@Test @MainActor func firstRunPromptsThroughTheRecorderBeforeStarting() async {
    let h = Harness()
    h.service.status = .notDetermined
    h.service.requestResult = .denied   // the OS prompt is on screen; the grant happens later
    await h.coordinator.startRecording(region: display)

    #expect(h.service.requestAuthorizationCount == 1)
    #expect(h.service.starts.isEmpty)
    #expect(!h.coordinator.isRecording)
}

@Test @MainActor func aStandingGrantOrDenialNeverRePrompts() async {
    for status in [CaptureAuthorizationStatus.authorized, .denied] {
        let h = Harness()
        h.service.status = status
        await h.coordinator.startRecording(region: display)
        #expect(h.service.requestAuthorizationCount == 0)
        #expect(h.service.starts.count == 1)
    }
}

// MARK: - Settings destination

@Test @MainActor func recordingDestinationUsesTheSaveLocationPatternAndContainerExtension() {
    let settings = StubSettings()
    let date = Calendar.current.date(from: DateComponents(year: 2026, month: 9, day: 22))!
    #expect(settings.recordingDestination(kind: .video, at: date).path == "/tmp/movies/Recording 2026.mp4")
    #expect(settings.recordingDestination(kind: .gif, at: date).path == "/tmp/movies/Recording 2026.gif")
}
