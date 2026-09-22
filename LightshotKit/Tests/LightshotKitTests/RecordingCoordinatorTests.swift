import Testing
import Foundation
import CoreGraphics
import ImageIO
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
    /// The event callback of the most recent `start`, so a test can simulate the stream dying or the
    /// microphone vanishing.
    private(set) var onEvent: (@Sendable (RecordingEvent) -> Void)?
    /// When set, `start` suspends here until the test resumes it — for the in-flight-start race.
    var startGate: CheckedContinuation<Void, Never>?
    var holdStart = false
    /// When set, `cancel` suspends here until the test resumes it — for the restart race.
    var cancelGate: CheckedContinuation<Void, Never>?
    var holdCancel = false
    private(set) var stopCount = 0
    private(set) var cancelCount = 0
    private(set) var pauseCount = 0
    private(set) var resumeCount = 0
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
        onEvent: @escaping @Sendable (RecordingEvent) -> Void
    ) async -> Result<Void, RecordingError> {
        starts.append((options, url))
        self.onEvent = onEvent
        if holdStart {
            await withCheckedContinuation { startGate = $0 }
        }
        return startResult
    }
    func pause() async { pauseCount += 1 }
    func resume() async { resumeCount += 1 }
    func stop() async -> Result<URL, RecordingError> { stopCount += 1; return stopResult }
    func cancel() async {
        cancelCount += 1
        if holdCancel { await withCheckedContinuation { cancelGate = $0 } }
    }
}

private final class SpyMediaSink: MediaSink {
    struct Failure: Error {}
    var saveFails = false
    var trashFails = false
    private(set) var copied: [URL] = []
    private(set) var saves: [(from: URL, to: URL)] = []
    private(set) var trashed: [URL] = []
    func copyFile(at url: URL) { copied.append(url) }
    func save(_ url: URL, to destination: URL) throws {
        if saveFails { throw Failure() }
        saves.append((url, destination))
    }
    func trash(_ url: URL) throws {
        if trashFails { throw Failure() }
        trashed.append(url)
    }
    private(set) var deleted: [URL] = []
    func delete(_ url: URL) throws { deleted.append(url) }
    private(set) var copies: [(from: URL, to: URL)] = []
    func copy(_ url: URL, to destination: URL) throws {
        if saveFails { throw Failure() }
        copies.append((url, destination))
    }
}

/// Canned video metadata, as the app's AVFoundation source would read it.
private struct FakeMetadata: MediaMetadataSource {
    var result: VideoMetadata? = VideoMetadata(pixelWidth: 1280, pixelHeight: 720, duration: 30, thumbnailPNG: Data([1, 2, 3]))
    func videoMetadata(for url: URL) async -> VideoMetadata? { result }
}

/// A GIF encoder the test steers: it can wait at a gate (to be cancelled mid-way), report
/// progress, or fail. Main-actor so the gate and the records are never touched off it.
@MainActor
private final class FakeGIFEncoder: GIFEncoding {
    struct Failure: Error {}
    var fails = false
    var holds = false
    private(set) var encodes: [(video: URL, output: URL, settings: GIFSettings)] = []
    private var gate: CheckedContinuation<Void, Never>?

    func encode(video: URL, to output: URL, settings: GIFSettings, progress: @escaping @Sendable (Double) -> Void) async throws {
        encodes.append((video, output, settings))
        progress(0.5)
        if holds {
            await withTaskCancellationHandler {
                await withCheckedContinuation { gate = $0 }
            } onCancel: {
                Task { @MainActor [self] in self.release() }
            }
            try Task.checkCancellation()
        }
        if fails { throw Failure() }
        progress(1)
    }

    func release() {
        gate?.resume()
        gate = nil
    }
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
    var confirmResult = true
    private(set) var restartConfirmations = 0
    private(set) var discardConfirmations = 0
    var continueWithoutAudio = true
    private(set) var microphoneLostPrompts = 0
    private(set) var finished: [URL] = []
    private(set) var overlays: [PendingRecording] = []
    private(set) var editors: [URL] = []
    private(set) var gifPopups = 0
    private(set) var gifDismissals = 0
    private(set) var gifProgress: [Double] = []
    var gifCancel: (() -> Void)?
    var keepVideoOnCancel = true
    private(set) var cancelResolutions = 0
    private(set) var recordingFailures: [RecordingError] = []
    private(set) var permissionDeniedCount = 0

    func openEditor(with image: CapturedImage) {}
    func presentPostCaptureToolbar(for image: CapturedImage, at region: CaptureRegion) {}
    private(set) var deniedKinds: [PermissionKind] = []
    func presentPermissionDenied(_ kind: PermissionKind) { permissionDeniedCount += 1; deniedKinds.append(kind) }
    func presentCaptureFailure(_ error: CaptureError) {}
    func presentImageLoadFailure(_ error: ImageLoadError) {}
    func presentRecordingState(_ session: RecordingSession) { states.append(session.state) }
    func runRecordingCountdown(seconds: Int) async -> Bool {
        countdowns.append(seconds)
        if holdCountdown { await withCheckedContinuation { countdownGate = $0 } }
        return countdownResult
    }
    func confirmRecordingRestart() async -> Bool { restartConfirmations += 1; return confirmResult }
    func confirmRecordingDiscard() async -> Bool { discardConfirmations += 1; return confirmResult }
    func resolveMicrophoneDisconnected() async -> Bool { microphoneLostPrompts += 1; return continueWithoutAudio }
    func presentRecordingFinished(at url: URL) { finished.append(url) }
    func presentPostRecordingOverlay(_ recording: PendingRecording) { overlays.append(recording) }
    func openVideoEditor(at url: URL) { editors.append(url) }
    func presentGIFConversion(cancel: @escaping () -> Void) { gifPopups += 1; gifCancel = cancel }
    func updateGIFConversion(progress: Double) { gifProgress.append(progress) }
    func dismissGIFConversion() { gifDismissals += 1 }
    func resolveCancelledGIFConversion() async -> Bool { cancelResolutions += 1; return keepVideoOnCancel }
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
    // Silent save by default so the take-level tests see the file land at once; the after-recording
    // tests set the overlay path explicitly.
    var recordingDefaults = RecordingDefaults(countdownEnabled: false, afterRecording: .saveSilently)
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
    let gif = FakeGIFEncoder()
    let ui = SpyUI()
    /// Real history in a temp directory when a test wants the archive path (story 39).
    let history: HistoryStore?
    let historyDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("coordinator-history-\(UUID().uuidString)")
    let settings = StubSettings()
    let clock = ManualClock()
    let overlay = StubOverlay()
    let coordinator: AppCoordinator

    var now: TimeInterval {
        get { clock.now }
        set { clock.now = newValue }
    }
    var waits: [TimeInterval] { clock.waits }

    init(service: FakeRecordingService = FakeRecordingService(), withHistory: Bool = false, metadata: VideoMetadata? = FakeMetadata().result) {
        self.service = service
        let clock = self.clock
        history = withHistory ? HistoryStore(directory: historyDirectory) : nil
        coordinator = AppCoordinator(
            captureService: IdleCaptureService(),
            overlay: overlay,
            imageSource: IdleImageSource(),
            imageSink: IdleImageSink(),
            settings: settings,
            history: history,
            recordingService: service,
            mediaSink: sink,
            gifEncoder: gif,
            mediaMetadata: withHistory ? FakeMetadata(result: metadata) : nil,
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
    h.settings.recordingDefaults.afterRecording = .saveSilently
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
    #expect(h.ui.overlays.isEmpty && h.ui.editors.isEmpty)
    #expect(h.ui.states == [.recording, .stopping, .finished(URL(fileURLWithPath: "/tmp/scratch/take.mp4"))])
}

// MARK: - After recording (stories 32–34)

private let take = URL(fileURLWithPath: "/tmp/scratch/take.mp4")

@MainActor private func finishedTake(_ h: Harness, after: AfterRecordingAction) async {
    h.settings.recordingDefaults.afterRecording = after
    await h.coordinator.toggleRecording()
    h.now = 130
    await h.coordinator.toggleRecording()
}

@Test @MainActor func theDefaultShowsTheOverlayAndKeepsTheTakeInScratchUntilItDecides() async {
    let h = Harness()
    await finishedTake(h, after: .showOverlay)
    #expect(h.sink.saves.isEmpty)                                  // nothing moved yet
    #expect(h.ui.finished.isEmpty)
    #expect(h.ui.overlays == [PendingRecording(file: take, kind: .video, duration: 30)])
    #expect(h.coordinator.pendingRecording?.file == take)
}

@Test @MainActor func openEditorSavesFirstThenOpensTheEditor() async {
    let h = Harness()
    await finishedTake(h, after: .openEditor)
    #expect(h.sink.saves.count == 1)
    #expect(h.ui.editors == h.sink.saves.map(\.to))
    #expect(h.ui.overlays.isEmpty && h.ui.finished.isEmpty)
    #expect(h.coordinator.pendingRecording == nil)
}

@Test @MainActor func theOverlaysActionsCopySaveRenameAndDismiss() async {
    let h = Harness()
    await finishedTake(h, after: .showOverlay)

    // Copy file saves first and copies the saved file's reference, never the scratch one.
    let copied = h.coordinator.copyPendingRecordingFile(as: "clip")
    #expect(copied?.path == "/tmp/movies/clip.mp4")
    #expect(h.sink.copied == [URL(fileURLWithPath: "/tmp/movies/clip.mp4")])
    #expect(h.coordinator.pendingRecording == nil)

    // Rename then Save: the name replaces the pattern, the extension stays the file's own;
    // separators cannot escape the save folder.
    await finishedTake(h, after: .showOverlay)
    let saved = h.coordinator.savePendingRecording(as: "../demo:take/1")
    #expect(saved?.path == "/tmp/movies/-demo-take-1.mp4")
    #expect(h.sink.saves.map(\.from) == [take, take])
    #expect(h.coordinator.pendingRecording == nil)

    // A dismissal keeps the file — under the pattern, or the name typed so far.
    await finishedTake(h, after: .showOverlay)
    h.coordinator.dismissPendingRecording()
    #expect(h.sink.saves.last?.to.lastPathComponent.hasPrefix("Recording ") == true)
    await finishedTake(h, after: .showOverlay)
    h.coordinator.dismissPendingRecording(as: "typed")
    #expect(h.sink.saves.last?.to.lastPathComponent == "typed.mp4")
    #expect(h.coordinator.pendingRecording == nil)

    // Nothing pending: the actions are no-ops.
    #expect(h.coordinator.copyPendingRecordingFile() == nil)
    h.coordinator.dismissPendingRecording()
    #expect(h.sink.copied.count == 1 && h.sink.saves.count == 4)
}

// MARK: - GIF conversion (stories 37–38)

@MainActor private func finishedGIFTake(_ h: Harness) async {
    h.settings.recordingDefaults.afterRecording = .showOverlay
    await h.coordinator.startRecording(region: display, output: .gif)
    h.now = 130
    await h.coordinator.stopRecording()
}

@Test @MainActor func aGIFTakeIsConvertedThenRoutedAsAGIFAndTheVideoIsDeleted() async {
    let h = Harness()
    h.settings.recordingDefaults.gif = GIFSettings(fps: 10, quality: 0.5, maxWidth: 320, optimize: false)
    await finishedGIFTake(h)
    #expect(h.gif.encodes.count == 1)
    #expect(h.gif.encodes.first?.video == take)
    #expect(h.gif.encodes.first?.output == URL(fileURLWithPath: "/tmp/scratch/take.gif"))
    #expect(h.gif.encodes.first?.settings == h.settings.recordingDefaults.gif)
    #expect(h.ui.gifPopups == 1 && h.ui.gifDismissals == 1)
    #expect(h.sink.deleted == [take])                                // the intermediate video
    #expect(h.ui.overlays == [PendingRecording(file: URL(fileURLWithPath: "/tmp/scratch/take.gif"), kind: .gif, duration: 30)])
    #expect(h.ui.recordingFailures.isEmpty)
}

@Test @MainActor func progressReachesThePopupOnTheMainActor() async {
    let h = Harness()
    await finishedGIFTake(h)
    await Task.yield()
    #expect(h.ui.gifProgress.contains(0.5))
}

@Test(.timeLimit(.minutes(1))) @MainActor func cancellingOffersTheVideoInsteadOrDeletesTheTake() async {
    let h = Harness()
    h.gif.holds = true
    let take1 = Task { await finishedGIFTake(h) }
    await Task.yield()
    while h.ui.gifCancel == nil { await Task.yield() }
    // Mid-conversion the recorder is busy: a new take is refused.
    await h.coordinator.startRecording(region: display)
    #expect(h.service.starts.count == 1)
    h.ui.gifCancel?()                                                // Cancel in the popup
    await take1.value
    #expect(h.ui.cancelResolutions == 1)
    #expect(h.ui.overlays.last?.kind == .video)                       // "Keep the video instead"
    #expect(h.sink.deleted.isEmpty)

    h.ui.keepVideoOnCancel = false
    h.ui.gifCancel = nil
    let take2 = Task { await finishedGIFTake(h) }
    while h.ui.gifCancel == nil { await Task.yield() }
    h.ui.gifCancel?()
    await take2.value
    #expect(h.ui.overlays.count == 1)                                 // nothing routed
    #expect(h.sink.deleted == [take])                                 // the take is gone
    #expect(h.ui.gifDismissals == 2)
}

@Test @MainActor func aFailedConversionSurfacesAndFallsBackToTheVideo() async {
    let h = Harness()
    h.gif.fails = true
    await finishedGIFTake(h)
    #expect(h.ui.recordingFailures.count == 1)
    #expect(h.ui.overlays.last == PendingRecording(file: take, kind: .video, duration: 30))
    #expect(h.sink.deleted.isEmpty)
}

@Test @MainActor func aGIFNeverGoesToTheVideoEditor() async {
    let h = Harness()
    h.settings.recordingDefaults.afterRecording = .openEditor
    await h.coordinator.startRecording(region: display, output: .gif)
    await h.coordinator.stopRecording()
    #expect(h.ui.editors.isEmpty)
    #expect(h.ui.finished.count == 1 && h.ui.finished[0].pathExtension == "gif")
}

@Test @MainActor func aVideoTakeNeverTouchesTheEncoder() async {
    let h = Harness()
    await finishedTake(h, after: .showOverlay)
    #expect(h.gif.encodes.isEmpty && h.ui.gifPopups == 0)
}

@Test @MainActor func openEditorFromTheOverlaySavesThenOpensTheEditor() async {
    let h = Harness()
    await finishedTake(h, after: .showOverlay)
    let saved = h.coordinator.openPendingRecordingInEditor(as: "cut me")
    #expect(saved?.lastPathComponent == "cut me.mp4")
    #expect(h.ui.editors == [saved])
    #expect(h.coordinator.pendingRecording == nil)
    #expect(h.coordinator.openPendingRecordingInEditor() == nil)   // nothing pending
}

// MARK: - Recordings in history (story 39)

/// A take that exists on disk (history moves it), unique per test since tests run in parallel.
private func materialisedTake() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("take-\(UUID().uuidString).mp4")
    try Data([9, 9, 9]).write(to: url)
    return url
}

@Test @MainActor func aFinishedVideoJoinsHistoryAndTheOverlayGetsHistorysFile() async throws {
    let take = try materialisedTake()
    let h = Harness(service: FakeRecordingService(stopResult: .success(take)), withHistory: true)
    defer { try? FileManager.default.removeItem(at: h.historyDirectory) }
    await finishedTake(h, after: .showOverlay)

    let records = h.history!.all()
    #expect(records.count == 1)
    let record = records[0]
    #expect(record.kind == .video && record.source == .recording && record.duration == 30)
    #expect(record.pixelWidth == 1280 && record.pixelHeight == 720)          // from the asset, not the thumbnail
    #expect(try Data(contentsOf: record.thumbnailURL) == Data([1, 2, 3]))
    #expect(!FileManager.default.fileExists(atPath: take.path))              // moved into history
    #expect(h.ui.overlays.last?.file == record.fileURL && h.ui.overlays.last?.origin == .freshInHistory(id: record.id))
    #expect(h.ui.overlays.last?.suggestedName?.hasPrefix("Recording ") == true)   // the pattern's name, not the id

    // Save copies history's file out — history keeps the original.
    let saved = h.coordinator.savePendingRecording(as: "kept")
    #expect(saved?.lastPathComponent == "kept.mp4")
    #expect(h.sink.copies.map(\.from) == [record.fileURL] && h.sink.saves.isEmpty)
    #expect(h.history!.record(id: record.id) != nil)
}

@Test @MainActor func unreadableMetadataLeavesTheTakeInScratchAndRoutesItAnyway() async throws {
    let take = try materialisedTake()
    let h = Harness(service: FakeRecordingService(stopResult: .success(take)), withHistory: true, metadata: nil)
    defer { try? FileManager.default.removeItem(at: h.historyDirectory) }
    await finishedTake(h, after: .showOverlay)
    #expect(h.history!.all().isEmpty)
    #expect(h.ui.overlays.last?.file == take && h.ui.overlays.last?.origin == .scratch)
    #expect(FileManager.default.fileExists(atPath: take.path))
    try? FileManager.default.removeItem(at: take)
}

@Test @MainActor func deletingAHistoryOwnedTakeRemovesItsRecord() async throws {
    let take = try materialisedTake()
    let h = Harness(service: FakeRecordingService(stopResult: .success(take)), withHistory: true)
    defer { try? FileManager.default.removeItem(at: h.historyDirectory) }
    await finishedTake(h, after: .showOverlay)
    let record = h.history!.all()[0]
    #expect(h.coordinator.deletePendingRecording())
    #expect(h.history!.all().isEmpty && !FileManager.default.fileExists(atPath: record.fileURL.path))
    #expect(h.sink.trashed.isEmpty)                                          // history's file, not the Trash
}

@Test @MainActor func reopeningFromHistoryRoutesByKindAndADismissedGIFStaysPut() async throws {
    let h = Harness(withHistory: true)
    defer { try? FileManager.default.removeItem(at: h.historyDirectory) }
    let video = CaptureRecord(id: UUID(), timestamp: Date(), source: .recording, kind: .video, pixelWidth: 1, pixelHeight: 1, duration: 3,
                              fileURL: URL(fileURLWithPath: "/tmp/h/v.mp4"), thumbnailURL: URL(fileURLWithPath: "/tmp/h/v.png"))
    h.coordinator.reopenRecording(video)
    // A video is copied out first; the editor gets the copy, never history's file.
    #expect(h.sink.copies.map(\.from) == [video.fileURL])
    #expect(h.ui.editors == h.sink.copies.map(\.to) && h.ui.editors.first?.pathExtension == "mp4")
    #expect(h.coordinator.pendingRecording == nil)

    let gif = CaptureRecord(id: UUID(), timestamp: Date(), source: .recording, kind: .gif, pixelWidth: 1, pixelHeight: 1, duration: 2,
                            fileURL: URL(fileURLWithPath: "/tmp/h/g.gif"), thumbnailURL: URL(fileURLWithPath: "/tmp/h/g.png"))
    h.coordinator.reopenRecording(gif)
    #expect(h.ui.overlays.last?.origin == .historyItem(id: gif.id) && h.ui.overlays.last?.isNew == false)
    h.coordinator.dismissPendingRecording()
    #expect(h.sink.copies.count == 1 && h.sink.saves.isEmpty && h.coordinator.pendingRecording == nil)   // already kept
    h.coordinator.reopenRecording(gif)
    #expect(h.coordinator.savePendingRecording(as: "again")?.lastPathComponent == "again.gif")
    #expect(h.sink.copies.count == 2)                                        // Save copies it out

    let shot = CaptureRecord(id: UUID(), timestamp: Date(), source: .area, pixelWidth: 1, pixelHeight: 1,
                             fileURL: URL(fileURLWithPath: "/tmp/h/s.png"), thumbnailURL: URL(fileURLWithPath: "/tmp/h/s.png"))
    h.coordinator.reopenRecording(shot)
    #expect(h.ui.overlays.count == 2 && h.ui.editors.count == 1)             // not the coordinator's job
}

@Test @MainActor func aFinishedGIFJoinsHistoryAndSilentSaveCopiesItOut() async throws {
    let gifFile = FileManager.default.temporaryDirectory.appendingPathComponent("take-\(UUID().uuidString).gif")
    // The fake encoder writes nothing, so put a real GIF where the conversion would.
    let take = try materialisedTake()
    let destination = CGImageDestinationCreateWithURL(take.deletingPathExtension().appendingPathExtension("gif") as CFURL, "com.compuserve.gif" as CFString, 1, nil)!
    let context = CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    CGImageDestinationAddImage(destination, context.makeImage()!, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.2]] as CFDictionary)
    CGImageDestinationFinalize(destination)
    _ = gifFile
    let h = Harness(service: FakeRecordingService(stopResult: .success(take)), withHistory: true)
    defer { try? FileManager.default.removeItem(at: h.historyDirectory) }
    h.settings.recordingDefaults.afterRecording = .saveSilently
    await h.coordinator.startRecording(region: display, output: .gif)
    await h.coordinator.stopRecording()

    let record = h.history!.all().first
    #expect(record?.kind == .gif && record?.pixelWidth == 4 && abs((record?.duration ?? 0) - 0.2) < 0.001)
    #expect(h.sink.copies.count == 1 && h.sink.copies[0].from == record?.fileURL)   // copied, history keeps it
    #expect(h.sink.saves.isEmpty && h.ui.finished.count == 1)
}

@Test @MainActor func aRecoveredTakeJoinsHistoryToo() async throws {
    let take = try materialisedTake()
    let h = Harness(withHistory: true)
    defer { try? FileManager.default.removeItem(at: h.historyDirectory) }
    let recovered = await h.coordinator.archiveRecoveredRecording(at: take)
    #expect(recovered.kind == .video && recovered.duration == 30)
    #expect(h.history!.all().count == 1 && recovered.origin == .freshInHistory(id: h.history!.all()[0].id))
    #expect(!FileManager.default.fileExists(atPath: take.path))
}

@Test @MainActor func reopeningAGIFKeepsAFreshTakeFirst() async throws {
    let take = try materialisedTake()
    let h = Harness(service: FakeRecordingService(stopResult: .success(take)), withHistory: true)
    defer { try? FileManager.default.removeItem(at: h.historyDirectory) }
    await finishedTake(h, after: .showOverlay)
    let gif = CaptureRecord(id: UUID(), timestamp: Date(), source: .recording, kind: .gif, pixelWidth: 1, pixelHeight: 1, duration: 2,
                            fileURL: URL(fileURLWithPath: "/tmp/h/g.gif"), thumbnailURL: URL(fileURLWithPath: "/tmp/h/g.png"))
    h.coordinator.reopenRecording(gif)
    #expect(h.sink.copies.count == 1)                                        // the fresh take was saved, not dropped
    #expect(h.coordinator.pendingRecording?.origin == .historyItem(id: gif.id))
}

@Test @MainActor func aNewTakeKeepsThePendingOneBeforeItStarts() async {
    let h = Harness()
    await finishedTake(h, after: .showOverlay)
    #expect(h.sink.saves.isEmpty)
    await h.coordinator.toggleRecording()                          // the app moves on
    #expect(h.sink.saves.count == 1 && h.sink.saves[0].from == take)
    #expect(h.coordinator.isRecording)
    #expect(h.coordinator.pendingRecording == nil)
}

@Test @MainActor func deleteTrashesTheTakeAndAFailureKeepsItPending() async {
    let h = Harness()
    await finishedTake(h, after: .showOverlay)
    h.sink.trashFails = true
    #expect(!h.coordinator.deletePendingRecording())
    #expect(h.sink.trashed.isEmpty && h.coordinator.pendingRecording != nil)
    #expect(h.ui.recordingFailures.count == 1)

    h.sink.trashFails = false
    #expect(h.coordinator.deletePendingRecording())
    #expect(h.sink.trashed == [take] && h.coordinator.pendingRecording == nil)
    #expect(h.sink.saves.isEmpty)
}

@Test @MainActor func aFailedSaveFromTheOverlayKeepsTheTakePending() async {
    let h = Harness()
    await finishedTake(h, after: .showOverlay)
    h.sink.saveFails = true
    #expect(h.coordinator.savePendingRecording() == nil)
    #expect(h.coordinator.pendingRecording != nil)
    #expect(h.ui.recordingFailures.count == 1)
    h.sink.saveFails = false
    #expect(h.coordinator.savePendingRecording() != nil)
}

@Test @MainActor func anEmptyOrDottedRenameFallsBackToThePattern() {
    let s = StubSettings()
    #expect(s.recordingDestination(named: "   ", pathExtension: "mp4").lastPathComponent.hasPrefix("Recording "))
    #expect(s.recordingDestination(named: "...", pathExtension: "mp4").lastPathComponent.hasPrefix("Recording "))
    #expect(s.recordingDestination(named: ".hidden", pathExtension: "mov").lastPathComponent == "hidden.mov")
    #expect(s.recordingDestination(named: "name.", pathExtension: "mp4").lastPathComponent == "name.mp4")
    #expect(FilenameFormatter.sanitized("a/b:c") == "a-b-c")
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
    #expect(h.coordinator.recordingSession.state == .idle)
    #expect(h.ui.states.last == .idle)
}

@Test @MainActor func aStreamDyingMidTakeFailsTheSessionDeletesThePartialAndRestoresTheStatusItem() async {
    let h = Harness()
    await h.coordinator.startRecording(region: display)
    h.service.onEvent?(.failed(.systemFailure("display disconnected")))
    await Task.yield()
    while h.coordinator.isRecording { await Task.yield() }

    #expect(h.coordinator.recordingSession.state == .failed(.systemFailure("display disconnected")))
    #expect(h.ui.recordingFailures == [.systemFailure("display disconnected")])
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
    #expect(h.settings.recordingDefaults == RecordingDefaults(countdownEnabled: false, afterRecording: .saveSilently))   // not written back

    // A GIF take is converted (R13) and the GIF is what gets saved.
    await h.coordinator.stopRecording()
    #expect(h.sink.saves.first?.to.pathExtension == "gif")
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

// MARK: - Microphone (stories 20, 24, 25)

@Test @MainActor func aLostMicrophoneAsksAndContinuesOrStops() async {
    let h = Harness()
    await h.coordinator.startRecording(region: display)
    h.service.onEvent?(.audioInputLost)
    while h.ui.microphoneLostPrompts == 0 { await Task.yield() }
    await Task.yield()
    #expect(h.coordinator.isRecording)                    // "Continue Without Audio"
    #expect(h.service.stopCount == 0)

    h.ui.continueWithoutAudio = false
    h.service.onEvent?(.audioInputLost)
    while h.coordinator.isRecording { await Task.yield() }
    #expect(h.ui.microphoneLostPrompts == 2)
    #expect(h.service.stopCount == 1)                     // "Stop": the take is finished and saved
    #expect(h.sink.saves.count == 1)
}

@Test @MainActor func theToolbarsMicrophoneChoiceBecomesTheDefaultAndReachesTheOptions() async {
    let h = Harness()
    h.settings.recordingDefaults = RecordingDefaults(microphoneVolume: 1.5, monoAudio: true, countdownEnabled: false)
    h.overlay.choice = RecordingChoice(
        region: display, output: .video, overrides: RecordingOverrides(microphone: true), microphoneDeviceID: "usb-mic"
    )
    await h.coordinator.recordScreen()

    #expect(h.settings.recordingDefaults.microphoneDeviceID == "usb-mic")
    let options = h.service.starts.first?.options
    #expect(options?.microphone == .device(id: "usb-mic"))
    #expect(options?.microphoneVolume == 1.5)
    #expect(options?.monoAudio == true)

    // A take with the microphone off never overwrites the remembered device.
    await h.coordinator.stopRecording()
    h.overlay.choice = RecordingChoice(region: display, output: .video, overrides: RecordingOverrides(microphone: false), microphoneDeviceID: nil)
    await h.coordinator.recordScreen()
    #expect(h.settings.recordingDefaults.microphoneDeviceID == "usb-mic")
}

@Test @MainActor func theToolbarsCameraChoiceBecomesTheDefaultAndReachesTheOptions() async {
    let h = Harness()
    h.settings.recordingDefaults = RecordingDefaults(cameraBubble: CameraBubbleSettings(size: .large), countdownEnabled: false)
    h.overlay.choice = RecordingChoice(
        region: display, output: .video, overrides: RecordingOverrides(camera: true), cameraDeviceID: "usb-cam"
    )
    await h.coordinator.recordScreen()

    #expect(h.settings.recordingDefaults.cameraDeviceID == "usb-cam")
    let options = h.service.starts.first?.options
    #expect(options?.camera == .device(id: "usb-cam"))
    #expect(options?.cameraBubble.size == .large)

    // A take with the camera off never overwrites the remembered device.
    await h.coordinator.stopRecording()
    h.overlay.choice = RecordingChoice(region: display, output: .video, overrides: RecordingOverrides(camera: false), cameraDeviceID: nil)
    await h.coordinator.recordScreen()
    #expect(h.settings.recordingDefaults.cameraDeviceID == "usb-cam")
}

// MARK: - Controls: pause / resume, restart, discard (stories 12–14)

@Test @MainActor func pauseFreezesTheTimerAndResumeContinuesThroughTheService() async {
    let h = Harness()
    await h.coordinator.startRecording(region: display)
    h.now = 110
    await h.coordinator.pauseResumeRecording()
    #expect(h.coordinator.recordingSession.state == .paused)
    #expect(h.service.pauseCount == 1)
    h.now = 150
    #expect(h.coordinator.recordingElapsed == 10)        // frozen while paused
    await h.coordinator.pauseResumeRecording()
    #expect(h.coordinator.recordingSession.state == .recording)
    #expect(h.service.resumeCount == 1)
    h.now = 155
    #expect(h.coordinator.recordingElapsed == 15)
    #expect(h.ui.states.suffix(2) == [.paused, .recording])

    await h.coordinator.stopRecording()
    await h.coordinator.pauseResumeRecording()           // nothing to pause once the take ended
    #expect(h.service.pauseCount == 1)
}

@Test @MainActor func restartThrowsTheTakeAwayAndStartsAgainWithTheSameOptions() async {
    let h = Harness()
    h.settings.recordingDefaults = RecordingDefaults(countdownEnabled: false, confirmBeforeDiscard: true)
    await h.coordinator.startRecording(region: display)
    h.now = 120
    await h.coordinator.restartRecording()

    #expect(h.ui.restartConfirmations == 1)
    #expect(h.service.cancelCount == 1)                  // the old stream (and its file) torn down …
    #expect(h.service.starts.count == 2)                 // … and a new one started
    #expect(h.service.starts.map(\.options).allSatisfy { $0 == h.service.starts.first?.options })
    #expect(h.service.starts.map(\.url).allSatisfy { $0 == h.service.starts.first?.url })   // same scratch URL
    #expect(h.coordinator.recordingSession.state == .recording)
    #expect(h.coordinator.recordingElapsed == 0)         // the clock restarted
    #expect(h.ui.countdowns.isEmpty)
}

@Test @MainActor func restartGoesBackThroughTheCountdownWhenOneIsConfigured() async {
    let h = Harness()
    h.settings.recordingDefaults = RecordingDefaults(countdownEnabled: true, countdownSeconds: 3, confirmBeforeDiscard: false)
    await h.coordinator.startRecording(region: display)
    await h.coordinator.restartRecording()

    #expect(h.ui.restartConfirmations == 0)              // confirmation turned off in Settings
    #expect(h.ui.countdowns == [3, 3])
    #expect(h.service.starts.count == 2)
    #expect(h.coordinator.recordingSession.state == .recording)
}

@Test @MainActor func aDeclinedConfirmationLeavesTheTakeRunning() async {
    let h = Harness()
    h.ui.confirmResult = false
    await h.coordinator.startRecording(region: display)
    await h.coordinator.restartRecording()
    await h.coordinator.discardRecording()

    #expect(h.ui.restartConfirmations == 1 && h.ui.discardConfirmations == 1)
    #expect(h.service.cancelCount == 0)
    #expect(h.service.starts.count == 1)
    #expect(h.coordinator.recordingSession.state == .recording)
}

@Test @MainActor func discardDeletesThePartialAndEndsInIdleWithNoSave() async {
    let h = Harness()
    await h.coordinator.startRecording(region: display)
    await h.coordinator.pauseResumeRecording()
    await h.coordinator.discardRecording()

    #expect(h.ui.discardConfirmations == 1)
    #expect(h.service.cancelCount == 1)                  // the service deletes the partial file
    #expect(h.sink.saves.isEmpty)
    #expect(h.coordinator.recordingSession.state == .idle)
    #expect(h.ui.states.last == .idle)
}

@Test @MainActor func aStopDuringRestartsTeardownWaitsForTheNewStream() async {
    // The old stream is being cancelled when the hotkey fires: the stop must not run against a
    // service with no stream (which would fail the session) — it is ignored, and the new stream starts.
    let h = Harness()
    h.settings.recordingDefaults = RecordingDefaults(countdownEnabled: false, confirmBeforeDiscard: false)
    await h.coordinator.startRecording(region: display)
    h.service.holdCancel = true
    let restarting = Task { await h.coordinator.restartRecording() }
    while h.service.cancelGate == nil { await Task.yield() }

    await h.coordinator.stopRecording()                  // arrives mid-teardown
    #expect(h.service.stopCount == 0)

    h.service.cancelGate?.resume()
    await restarting.value
    #expect(h.service.starts.count == 2)
    #expect(h.coordinator.recordingSession.state == .recording)
    #expect(h.ui.recordingFailures.isEmpty)
}

@Test @MainActor func discardIsLegalDuringTheCountdownAndRestartIsNot() async {
    let h = Harness()
    h.settings.recordingDefaults = RecordingDefaults(countdownEnabled: true, countdownSeconds: 3, confirmBeforeDiscard: false)
    h.ui.holdCountdown = true
    let starting = Task { await h.coordinator.startRecording(region: display) }
    while h.ui.countdownGate == nil { await Task.yield() }

    await h.coordinator.restartRecording()               // no footage yet: nothing to restart
    #expect(h.coordinator.recordingSession.state == .countdown)
    await h.coordinator.discardRecording()
    #expect(h.coordinator.recordingSession.state == .idle)

    h.ui.countdownGate?.resume()
    await starting.value
    #expect(h.service.starts.isEmpty)
}

@Test @MainActor func restartAndDiscardAreNoOpsWhenNothingIsRecording() async {
    let h = Harness()
    await h.coordinator.restartRecording()
    await h.coordinator.discardRecording()
    #expect(h.ui.restartConfirmations == 0 && h.ui.discardConfirmations == 0)
    #expect(h.service.cancelCount == 0)
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
    #expect(h.coordinator.recordingSession.state == .idle)
    #expect(h.ui.states == [.countdown, .idle])
}

// MARK: - Error routing (stories 57–58)

@Test @MainActor func permissionDeniedOnStartRoutesToRecoveryAndFailsTheSession() async {
    let h = Harness()
    h.service.startResult = .failure(.permissionDenied(.screenRecording))
    await h.coordinator.startRecording(region: display)

    #expect(h.ui.permissionDeniedCount == 1)
    #expect(h.ui.deniedKinds == [.screenRecording])
    #expect(h.ui.recordingFailures.isEmpty)
    #expect(h.coordinator.recordingSession.state == .failed(.permissionDenied(.screenRecording)))
    #expect(!h.coordinator.isRecording)
    #expect(h.sink.saves.isEmpty)
    #expect(h.ui.states.last == .failed(.permissionDenied(.screenRecording)))   // status item reverts
}

@Test @MainActor func aMissingMicrophoneGrantRoutesToTheMicrophoneRecoveryNotScreenRecording() async {
    let h = Harness()
    h.service.startResult = .failure(.permissionDenied(.microphone))
    await h.coordinator.startRecording(region: display)
    #expect(h.ui.deniedKinds == [.microphone])
    #expect(h.ui.recordingFailures.isEmpty)
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
