import Testing
import Foundation
import CoreGraphics
import ImageIO
@testable import LightshotKit

// Coordinator routing for the capture spine (stories 1–5, 8, 14, 40, 44, 57–58).
// These run with **no AppKit / ScreenCaptureKit imports** — fakes stand in for the OS seams,
// which is the whole point of fronting capture/overlay/clipboard/UI as protocols.

// MARK: - Fakes

// One canned result feeds both capture paths — each test exercises a single path — while the
// region path also records what it was asked to capture. `@unchecked Sendable` is safe here: the
// stub is only ever driven from the `@MainActor` tests, single-threaded.
private final class StubCaptureService: CaptureService, @unchecked Sendable {
    let result: Result<CapturedImage, CaptureError>
    private(set) var capturedRegions: [CaptureRegion] = []
    /// The `displayID` each fullscreen capture was asked for — `nil` is the primary display (story 8).
    private(set) var capturedDisplays: [UInt32?] = []

    // Authorization surface (LIG-19). `status` defaults to `.authorized` so the pre-existing
    // routing tests never trip onboarding; the onboarding tests set it explicitly and read the
    // call counts back. `requestAuthorization()` flips the reported status to `requestResult`,
    // mimicking the real prompt updating the world.
    var status: CaptureAuthorizationStatus
    let requestResult: CaptureAuthorizationStatus
    private(set) var authorizationStatusCount = 0
    private(set) var requestAuthorizationCount = 0

    /// The frozen screen handed back by `freezeScreen()` (spec 0011). Defaults to mirroring
    /// `result`: a successful capture freezes `sampleFrozenScreen()`, a failing one fails the
    /// freeze the same way — so the failure-routing tests hold for the frozen paths too.
    var freezeResult: Result<FrozenScreen, CaptureError>
    private(set) var freezeCount = 0
    /// The windows' own images handed back by `freezeWindowImages()` — the sample window's, by default.
    var windowImages: [UInt32: CapturedImage] = [4242: sampleWindowImage()]
    private(set) var windowImagesRequestCount = 0

    init(
        _ result: Result<CapturedImage, CaptureError>,
        status: CaptureAuthorizationStatus = .authorized,
        requestResult: CaptureAuthorizationStatus = .authorized,
        freeze: Result<FrozenScreen, CaptureError>? = nil
    ) {
        self.result = result
        self.status = status
        self.requestResult = requestResult
        self.freezeResult = freeze ?? result.map { _ in sampleFrozenScreen() }
    }

    func authorizationStatus() async -> CaptureAuthorizationStatus {
        authorizationStatusCount += 1
        return status
    }

    @discardableResult
    func requestAuthorization() async -> CaptureAuthorizationStatus {
        requestAuthorizationCount += 1
        status = requestResult
        return requestResult
    }

    func captureFullscreen(displayID: UInt32?) async -> Result<CapturedImage, CaptureError> {
        capturedDisplays.append(displayID)
        return result
    }
    func captureRegion(_ region: CaptureRegion) async -> Result<CapturedImage, CaptureError> {
        capturedRegions.append(region)
        return result
    }
    func freezeScreen() async -> Result<FrozenScreen, CaptureError> {
        freezeCount += 1
        return freezeResult
    }
    func freezeWindowImages() async -> [UInt32: CapturedImage] {
        windowImagesRequestCount += 1
        return windowImages
    }
}

// Canned regions for each overlay mode, plus per-mode call counts so a test can assert that the
// window path consults `selectWindow()` (not `selectRegion()`) and vice versa.
@MainActor
private final class StubOverlay: OverlayController {
    let region: CaptureRegion?
    let windowRegion: CaptureRegion?
    private(set) var callCount = 0
    private(set) var windowCallCount = 0
    /// The backdrop each selection was shown over — `nil` is the live screen (spec 0011).
    private(set) var backdrops: [FrozenScreen?] = []
    init(region: CaptureRegion?, windowRegion: CaptureRegion? = nil) {
        self.region = region
        self.windowRegion = windowRegion
    }
    func selectRegion(over frozen: FrozenScreen?) async -> CaptureRegion? {
        callCount += 1
        backdrops.append(frozen)
        return region
    }
    func selectWindow(over frozen: FrozenScreen?) async -> CaptureRegion? {
        windowCallCount += 1
        backdrops.append(frozen)
        return windowRegion
    }
    func selectRecording(initial: CaptureRegion?, defaults: RecordingDefaults) async -> RecordingChoice? { nil }
}

// Feeds a canned open-file result and records how often the panel was opened. `loadImage(from:)`
// isn't exercised by the coordinator (it goes through `openDocument()`), so it echoes the same
// canned result. Only ever driven from the `@MainActor` tests.
@MainActor
private final class StubImageSource: ImageSource {
    let result: Result<CapturedImage, ImageLoadError>
    private(set) var openCount = 0
    init(_ result: Result<CapturedImage, ImageLoadError>) { self.result = result }
    func loadImage(from url: URL) -> Result<CapturedImage, ImageLoadError> { result }
    func openDocument() -> Result<CapturedImage, ImageLoadError> { openCount += 1; return result }
}

private final class SpyImageSink: ImageSink {
    private(set) var copied: [RenderedImage] = []
    private(set) var written: [(image: RenderedImage, url: URL, format: ImageFormat)] = []
    private(set) var copiedText: [String] = []
    func copyToClipboard(_ image: RenderedImage) { copied.append(image) }
    func copyText(_ text: String) { copiedText.append(text) }
    func write(_ image: RenderedImage, to url: URL, format: ImageFormat) throws {
        written.append((image, url, format))
    }
}

@MainActor
private final class StubSettings: SettingsStore {
    var defaultFormat: ImageFormat = .png
    var saveLocation = URL(fileURLWithPath: "/tmp/shots", isDirectory: true)
    var filenamePattern = "shot-%Y"
    var hotkeys = HotkeyBindings.defaults
    var openInEditor = true
    var includeCursor = false
    var captureDelay: TimeInterval = 0
    var historyRetention = 50
    var launchAtLogin = false
    var recordingDefaults = RecordingDefaults(countdownEnabled: false)
    var rememberLastRecordingArea = false
    var lastRecordingRegion: CaptureRegion?
    var appearance = AppearancePreference.system
}

/// Records the self-timer waits the coordinator asked for, standing in for a real sleep so the
/// tests never wait real seconds. `@MainActor` like the tests that drive it.
@MainActor
private final class DelaySpy {
    private(set) var waits: [TimeInterval] = []
    func sleep(_ seconds: TimeInterval) async { waits.append(seconds) }
}

@MainActor
private final class SpyUI: CaptureUI {
    private(set) var openedImages: [CapturedImage] = []
    private(set) var toolbars: [(image: CapturedImage, region: CaptureRegion)] = []
    private(set) var permissionDeniedCount = 0
    private(set) var failures: [CaptureError] = []
    private(set) var imageLoadFailures: [ImageLoadError] = []

    func openEditor(with image: CapturedImage) { openedImages.append(image) }
    func presentPostCaptureToolbar(for image: CapturedImage, at region: CaptureRegion) {
        toolbars.append((image, region))
    }
    private(set) var deniedKinds: [PermissionKind] = []
    func presentPermissionDenied(_ kind: PermissionKind) { permissionDeniedCount += 1; deniedKinds.append(kind) }
    func presentCaptureFailure(_ error: CaptureError) { failures.append(error) }
    func presentImageLoadFailure(_ error: ImageLoadError) { imageLoadFailures.append(error) }
    func presentRecordingState(_ session: RecordingSession) {}
    func runRecordingCountdown(seconds: Int) async -> Bool { true }
    func confirmRecordingRestart() async -> Bool { true }
    func confirmRecordingDiscard() async -> Bool { true }
    func resolveMicrophoneDisconnected() async -> Bool { true }
    func presentRecordingFinished(at url: URL) {}
    func presentPostRecordingOverlay(_ recording: PendingRecording) {}
    func openVideoEditor(at url: URL, input: URL?) {}
    func openStudio(_ project: StudioProject) {}
    func presentRecordingPreparation(cancel: @escaping () -> Void) {}
    func updateRecordingPreparation(progress: Double) {}
    func dismissRecordingPreparation() {}
    func presentGIFConversion(cancel: @escaping () -> Void) {}
    func updateGIFConversion(progress: Double) {}
    func dismissGIFConversion() {}
    func resolveCancelledGIFConversion() async -> Bool { true }
    func presentRecordingFailure(_ error: RecordingError) {}
    private(set) var textResults: [TextCaptureStatus] = []
    func presentTextCaptureStatus(_ status: TextCaptureStatus) { textResults.append(status) }
}

/// Hands back canned recognised lines (or a failure) and records which images it was asked to read.
@MainActor
private final class SpyTextRecognizer: TextRecognizer {
    var result: Result<[RecognizedLine], TextRecognitionError>
    private(set) var recognized: [CapturedImage] = []
    init(_ result: Result<[RecognizedLine], TextRecognitionError>) { self.result = result }
    func recognizeText(in image: CapturedImage) async -> Result<[RecognizedLine], TextRecognitionError> {
        recognized.append(image)
        return result
    }
}

private func sampleImage() -> CapturedImage {
    CapturedImage(pixelWidth: 2560, pixelHeight: 1440, data: Data([0x89, 0x50, 0x4E, 0x47]))
}

/// A solid-colour PNG of `width` × `height` px — real bytes, so the coordinator's crop of it works.
private func solidPNG(width: Int, height: Int) -> CapturedImage {
    let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let data = NSMutableData()
    let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, context.makeImage()!, nil)
    CGImageDestinationFinalize(destination)
    return CapturedImage(pixelWidth: width, pixelHeight: height, data: data as Data)
}

/// A 1000 × 800 pt main display frozen at 2x, with the sample window (id 4242) as a picker
/// candidate — its own image comes separately, from `freezeWindowImages()`. Built once: every
/// frozen-path test shares the same stills.
private let frozenStill = FrozenScreen(
    displays: [FrozenDisplay(
        displayID: 1,
        frame: Rect(x: 0, y: 0, width: 1000, height: 800),
        image: solidPNG(width: 2000, height: 1600)
    )],
    windows: [FrozenWindow(id: 4242, frame: Rect(x: 200, y: 140, width: 800, height: 600), image: nil)]
)

/// The sample window's own image at the freeze: 800 × 600 pt at 2x.
private let frozenWindowStill = solidPNG(width: 1600, height: 1200)
private func sampleWindowImage() -> CapturedImage { frozenWindowStill }

/// What Capture Window should hand on for the sample window: its frozen image, as a PNG capture.
private func frozenSampleWindowCapture() -> CapturedImage? {
    var frozen = sampleFrozenScreen()
    frozen.windows[0].image = sampleWindowImage()
    return frozen.image(of: sampleWindowRegion())
}

private func sampleFrozenScreen() -> FrozenScreen { frozenStill }

private func sampleRegion() -> CaptureRegion {
    .rect(Rect(x: 120, y: 80, width: 640, height: 480))
}

private func sampleWindowRegion() -> CaptureRegion {
    .window(id: 4242, frame: Rect(x: 200, y: 140, width: 800, height: 600))
}

/// An overlay that is never expected to be consulted (the fullscreen path skips it).
@MainActor private func unusedOverlay() -> StubOverlay { StubOverlay(region: nil) }

/// An image source that is never expected to be consulted (only the open-file path uses it).
@MainActor private func unusedImageSource() -> StubImageSource {
    StubImageSource(.failure(.userCancelled))
}

// MARK: - Capture routing

@MainActor
@Test func successfulCaptureReachesEditorWithTheImage() async {
    let image = sampleImage()
    let ui = SpyUI()
    let coordinator = AppCoordinator(
        captureService: StubCaptureService(.success(image)),
        overlay: unusedOverlay(),
        imageSource: unusedImageSource(),
        imageSink: SpyImageSink(),
        settings: StubSettings(),
        ui: ui
    )

    await coordinator.captureFullscreen()

    #expect(ui.openedImages == [image])
    #expect(ui.permissionDeniedCount == 0)
    #expect(ui.failures.isEmpty)
}

@MainActor
@Test func permissionDeniedRoutesToRecoveryNeverABlankEditor() async {
    let ui = SpyUI()
    let coordinator = AppCoordinator(
        captureService: StubCaptureService(.failure(.permissionDenied)),
        overlay: unusedOverlay(),
        imageSource: unusedImageSource(),
        imageSink: SpyImageSink(),
        settings: StubSettings(),
        ui: ui
    )

    await coordinator.captureFullscreen()

    #expect(ui.permissionDeniedCount == 1)
    #expect(ui.deniedKinds == [.screenRecording])   // screenshots always name Screen Recording
    #expect(ui.openedImages.isEmpty)          // the editor is never opened blank/black
    #expect(ui.failures.isEmpty)
}

@MainActor
@Test func userCancelledIsASilentNoOp() async {
    let ui = SpyUI()
    let coordinator = AppCoordinator(
        captureService: StubCaptureService(.failure(.userCancelled)),
        overlay: unusedOverlay(),
        imageSource: unusedImageSource(),
        imageSink: SpyImageSink(),
        settings: StubSettings(),
        ui: ui
    )

    await coordinator.captureFullscreen()

    #expect(ui.openedImages.isEmpty)
    #expect(ui.permissionDeniedCount == 0)
    #expect(ui.failures.isEmpty)
}

@MainActor
@Test func otherFailuresSurfaceADistinctMessage() async {
    let ui = SpyUI()
    let coordinator = AppCoordinator(
        captureService: StubCaptureService(.failure(.noDisplayAvailable)),
        overlay: unusedOverlay(),
        imageSource: unusedImageSource(),
        imageSink: SpyImageSink(),
        settings: StubSettings(),
        ui: ui
    )

    await coordinator.captureFullscreen()

    #expect(ui.failures == [.noDisplayAvailable])
    #expect(ui.openedImages.isEmpty)
    #expect(ui.permissionDeniedCount == 0)
}

// MARK: - Permission onboarding & recovery (stories 57–58, LIG-19)

@MainActor
@Test func firstRunPromptsForAuthorizationBeforeCapturing() async {
    // .notDetermined == a true first run: the coordinator triggers the system prompt up front so
    // the user is guided to grant permission, rather than meeting a cryptic black capture.
    let image = sampleImage()
    let ui = SpyUI()
    let capture = StubCaptureService(.success(image), status: .notDetermined, requestResult: .authorized)
    let coordinator = AppCoordinator(
        captureService: capture,
        overlay: unusedOverlay(),
        imageSource: unusedImageSource(),
        imageSink: SpyImageSink(),
        settings: StubSettings(),
        ui: ui
    )

    await coordinator.captureFullscreen()

    #expect(capture.requestAuthorizationCount == 1)   // first run prompts once
    #expect(ui.openedImages == [image])               // …then capture proceeds to the editor
    #expect(ui.permissionDeniedCount == 0)
}

@MainActor
@Test func alreadyAuthorizedNeverRePrompts() async {
    // A standing grant skips the prompt entirely — onboarding is a first-run-only affordance.
    let ui = SpyUI()
    let capture = StubCaptureService(.success(sampleImage()), status: .authorized)
    let coordinator = AppCoordinator(
        captureService: capture,
        overlay: unusedOverlay(),
        imageSource: unusedImageSource(),
        imageSink: SpyImageSink(),
        settings: StubSettings(),
        ui: ui
    )

    await coordinator.captureFullscreen()

    #expect(capture.requestAuthorizationCount == 0)   // no re-prompt when already authorized
    #expect(ui.openedImages.count == 1)
}

@MainActor
@Test func standingDenialDoesNotRePromptAndTheCaptureRoutesToRecovery() async {
    // .denied is not re-prompted (the OS prompts at most once); the authoritative capture call is
    // what surfaces the recovery path, never a blank editor.
    let ui = SpyUI()
    let capture = StubCaptureService(.failure(.permissionDenied), status: .denied)
    let coordinator = AppCoordinator(
        captureService: capture,
        overlay: unusedOverlay(),
        imageSource: unusedImageSource(),
        imageSink: SpyImageSink(),
        settings: StubSettings(),
        ui: ui
    )

    await coordinator.captureFullscreen()

    #expect(capture.requestAuthorizationCount == 0)   // no re-prompt on a standing denial
    #expect(ui.permissionDeniedCount == 1)            // recovery, driven by the capture result
    #expect(ui.deniedKinds == [.screenRecording])
    #expect(ui.openedImages.isEmpty)
}

@MainActor
@Test func permissionRevokedAfterTheAdvisoryCheckStillRoutesToRecovery() async {
    // The revoked-after-check race: the pre-capture status reads .authorized (so no prompt), but
    // permission is revoked before the capture, which authoritatively returns .permissionDenied.
    // The capture result — not the stale status — decides, so recovery still fires.
    let ui = SpyUI()
    let capture = StubCaptureService(.failure(.permissionDenied), status: .authorized)
    let coordinator = AppCoordinator(
        captureService: capture,
        overlay: unusedOverlay(),
        imageSource: unusedImageSource(),
        imageSink: SpyImageSink(),
        settings: StubSettings(),
        ui: ui
    )

    await coordinator.captureFullscreen()

    #expect(capture.requestAuthorizationCount == 0)   // advisory check said authorized: no prompt
    #expect(ui.permissionDeniedCount == 1)            // …but the authoritative capture routes recovery
    #expect(ui.openedImages.isEmpty)                  // never a blank editor
}

@MainActor
@Test func areaCaptureFirstRunPromptsThenRunsTheOverlay() async {
    // Onboarding fronts the area flow too, so a first-run user meets the permission prompt before
    // being asked to drag a selection.
    let ui = SpyUI()
    let capture = StubCaptureService(.success(sampleImage()), status: .notDetermined, requestResult: .authorized)
    let overlay = StubOverlay(region: sampleRegion())
    let coordinator = AppCoordinator(
        captureService: capture,
        overlay: overlay,
        imageSource: unusedImageSource(),
        imageSink: SpyImageSink(),
        settings: StubSettings(),
        ui: ui
    )

    await coordinator.captureArea()

    #expect(capture.requestAuthorizationCount == 1)   // first run prompts
    #expect(overlay.callCount == 1)                   // …and the overlay still resolves a region
    #expect(ui.openedImages.count == 1)               // success reaches the editor
}

// The real `CGRequestScreenCaptureAccess()` does not wait for the user: on a first ask it puts the
// system prompt on screen and returns `false` within milliseconds (measured: 6 ms). The grant then
// happens in System Settings. So a first-run request that comes back un-authorized means "the system
// prompt is up right now" — the flow must stop there, not pile an overlay or our own alert on top.

@MainActor
@Test func firstRunFullscreenStopsAtTheSystemPromptInsteadOfStackingTheRecoveryAlert() async {
    let ui = SpyUI()
    let capture = StubCaptureService(.failure(.permissionDenied), status: .notDetermined, requestResult: .denied)
    let coordinator = AppCoordinator(
        captureService: capture,
        overlay: unusedOverlay(),
        imageSource: unusedImageSource(),
        imageSink: SpyImageSink(),
        settings: StubSettings(),
        ui: ui
    )

    await coordinator.captureFullscreen()

    #expect(capture.requestAuthorizationCount == 1)   // the system prompt was raised…
    #expect(capture.capturedDisplays.isEmpty)         // …so no doomed capture runs behind it
    #expect(ui.permissionDeniedCount == 0)            // …and no second dialog stacks on the prompt
}

@MainActor
@Test func firstRunAreaStopsAtTheSystemPromptInsteadOfCoveringItWithTheOverlay() async {
    let ui = SpyUI()
    let capture = StubCaptureService(.failure(.permissionDenied), status: .notDetermined, requestResult: .denied)
    let overlay = StubOverlay(region: sampleRegion())
    let coordinator = AppCoordinator(
        captureService: capture,
        overlay: overlay,
        imageSource: unusedImageSource(),
        imageSink: SpyImageSink(),
        settings: StubSettings(),
        ui: ui
    )

    await coordinator.captureArea()

    #expect(capture.requestAuthorizationCount == 1)
    #expect(overlay.callCount == 0)                   // the full-screen overlay never covers the prompt
    #expect(capture.capturedRegions.isEmpty)
    #expect(ui.permissionDeniedCount == 0)
}

@MainActor
@Test func firstRunWindowStopsAtTheSystemPromptInsteadOfCoveringItWithTheOverlay() async {
    let ui = SpyUI()
    let capture = StubCaptureService(.failure(.permissionDenied), status: .notDetermined, requestResult: .denied)
    let overlay = StubOverlay(region: nil, windowRegion: sampleWindowRegion())
    let coordinator = AppCoordinator(
        captureService: capture,
        overlay: overlay,
        imageSource: unusedImageSource(),
        imageSink: SpyImageSink(),
        settings: StubSettings(),
        ui: ui
    )

    await coordinator.captureWindow()

    #expect(capture.requestAuthorizationCount == 1)
    #expect(overlay.windowCallCount == 0)
    #expect(capture.capturedRegions.isEmpty)
    #expect(ui.permissionDeniedCount == 0)
}

// MARK: - Output

@MainActor
@Test func copyPlacesTheRenderedImageOnTheClipboard() async {
    let document = AnnotationDocument(baseImage: sampleImage())
    let sink = SpyImageSink()
    let coordinator = AppCoordinator(
        captureService: StubCaptureService(.success(document.baseImage)),
        overlay: unusedOverlay(),
        imageSource: unusedImageSource(),
        imageSink: sink,
        settings: StubSettings(),
        ui: SpyUI()
    )

    coordinator.copyToClipboard(document)

    #expect(sink.copied == [render(document)])   // the flattened document, not the raw capture
    #expect(sink.written.isEmpty)                // copying never produces a file (LIG-23)
}

// MARK: - Area capture routing (stories 1–5, 14)

@MainActor
@Test func areaCaptureResolvesRegionThenCapturesItAndOpensTheEditor() async {
    let image = sampleImage()
    let region = sampleRegion()
    let ui = SpyUI()
    let capture = StubCaptureService(.success(image))
    let overlay = StubOverlay(region: region)
    let coordinator = AppCoordinator(
        captureService: capture,
        overlay: overlay,
        imageSource: unusedImageSource(),
        imageSink: SpyImageSink(),
        settings: StubSettings(),
        ui: ui
    )

    await coordinator.captureArea()

    #expect(overlay.callCount == 1)                 // the overlay runs first, once
    #expect(capture.capturedRegions.isEmpty)        // …and the selection is cut from the frozen still
    #expect(ui.openedImages == [sampleFrozenScreen().image(of: region)!])   // straight to the editor (LIG-23)
    #expect(ui.toolbars.isEmpty)                    // …with no toolbar step in between
    #expect(ui.failures.isEmpty)
}

@MainActor
@Test func areaCaptureShowsTheToolbarWhenOpenInEditorIsOff() async {
    let image = sampleImage()
    let region = sampleRegion()
    let ui = SpyUI()
    let settings = StubSettings()
    settings.openInEditor = false
    let coordinator = AppCoordinator(
        captureService: StubCaptureService(.success(image)),
        overlay: StubOverlay(region: region),
        imageSource: unusedImageSource(),
        imageSink: SpyImageSink(),
        settings: settings,
        ui: ui
    )

    await coordinator.captureArea()

    #expect(ui.toolbars.count == 1)                 // the setting off brings the toolbar back
    #expect(ui.toolbars.first?.image == sampleFrozenScreen().image(of: region))
    #expect(ui.toolbars.first?.region == region)    // positioned at the selection
    #expect(ui.openedImages.isEmpty)                // the toolbar, not the editor, is the surface
}

@MainActor
@Test func openInEditorIsReadAtCaptureTimeSoAChangeAppliesToTheNextCapture() async {
    let ui = SpyUI()
    let settings = StubSettings()
    let coordinator = AppCoordinator(
        captureService: StubCaptureService(.success(sampleImage())),
        overlay: StubOverlay(region: sampleRegion()),
        imageSource: unusedImageSource(),
        imageSink: SpyImageSink(),
        settings: settings,
        ui: ui
    )

    await coordinator.captureArea()
    settings.openInEditor = false
    await coordinator.captureArea()

    #expect(ui.openedImages.count == 1)             // first capture: editor
    #expect(ui.toolbars.count == 1)                 // second capture: toolbar, no restart needed
}

@MainActor
@Test func fullscreenAndOpenFileOpenTheEditorEvenWhenOpenInEditorIsOff() async {
    // Neither path has a selection to anchor a toolbar to, so the setting doesn't apply to them.
    let image = sampleImage()
    let ui = SpyUI()
    let settings = StubSettings()
    settings.openInEditor = false
    let coordinator = AppCoordinator(
        captureService: StubCaptureService(.success(image)),
        overlay: unusedOverlay(),
        imageSource: StubImageSource(.success(image)),
        imageSink: SpyImageSink(),
        settings: settings,
        ui: ui
    )

    await coordinator.captureFullscreen()
    coordinator.openFile()

    #expect(ui.openedImages == [image, image])
    #expect(ui.toolbars.isEmpty)
}

@MainActor
@Test func escapeInTheOverlayCancelsWithNoCapture() async {
    let ui = SpyUI()
    let capture = StubCaptureService(.success(sampleImage()))
    let coordinator = AppCoordinator(
        captureService: capture,
        overlay: StubOverlay(region: nil),          // nil == user pressed Escape
        imageSource: unusedImageSource(),
        imageSink: SpyImageSink(),
        settings: StubSettings(),
        ui: ui
    )

    await coordinator.captureArea()

    #expect(capture.capturedRegions.isEmpty)        // Escape captures nothing
    #expect(ui.toolbars.isEmpty)
    #expect(ui.openedImages.isEmpty)
    #expect(ui.permissionDeniedCount == 0)
    #expect(ui.failures.isEmpty)
}

@MainActor
@Test func areaCapturePermissionDeniedRoutesToRecoveryNotAToolbar() async {
    let ui = SpyUI()
    let coordinator = AppCoordinator(
        captureService: StubCaptureService(.failure(.permissionDenied)),
        overlay: StubOverlay(region: sampleRegion()),
        imageSource: unusedImageSource(),
        imageSink: SpyImageSink(),
        settings: StubSettings(),
        ui: ui
    )

    await coordinator.captureArea()

    #expect(ui.permissionDeniedCount == 1)
    #expect(ui.toolbars.isEmpty)
    #expect(ui.openedImages.isEmpty)
    #expect(ui.failures.isEmpty)
}

@MainActor
@Test func areaCaptureUserCancelledIsASilentNoOp() async {
    let ui = SpyUI()
    let coordinator = AppCoordinator(
        captureService: StubCaptureService(.failure(.userCancelled)),
        overlay: StubOverlay(region: sampleRegion()),
        imageSource: unusedImageSource(),
        imageSink: SpyImageSink(),
        settings: StubSettings(),
        ui: ui
    )

    await coordinator.captureArea()

    #expect(ui.toolbars.isEmpty)
    #expect(ui.openedImages.isEmpty)
    #expect(ui.permissionDeniedCount == 0)
    #expect(ui.failures.isEmpty)
}

@MainActor
@Test func areaCaptureOtherFailureSurfacesADistinctMessage() async {
    let ui = SpyUI()
    let coordinator = AppCoordinator(
        captureService: StubCaptureService(.failure(.noDisplayAvailable)),
        overlay: StubOverlay(region: sampleRegion()),
        imageSource: unusedImageSource(),
        imageSink: SpyImageSink(),
        settings: StubSettings(),
        ui: ui
    )

    await coordinator.captureArea()

    #expect(ui.failures == [.noDisplayAvailable])
    #expect(ui.toolbars.isEmpty)
    #expect(ui.openedImages.isEmpty)
    #expect(ui.permissionDeniedCount == 0)
}

// MARK: - Window capture routing (stories 6–7)

@MainActor
@Test func windowCaptureResolvesWindowThenCapturesItAndOpensTheEditor() async {
    let image = sampleImage()
    let region = sampleWindowRegion()
    let ui = SpyUI()
    let capture = StubCaptureService(.success(image))
    let overlay = StubOverlay(region: nil, windowRegion: region)
    let coordinator = AppCoordinator(
        captureService: capture,
        overlay: overlay,
        imageSource: unusedImageSource(),
        imageSink: SpyImageSink(),
        settings: StubSettings(),
        ui: ui
    )

    await coordinator.captureWindow()

    #expect(overlay.windowCallCount == 1)           // window mode consults selectWindow()…
    #expect(overlay.callCount == 0)                 // …not the drag-a-rect path
    #expect(capture.capturedRegions.isEmpty)        // …and the window comes from the freeze
    #expect(ui.openedImages == [frozenSampleWindowCapture()!])   // straight to the editor (LIG-23)
    #expect(ui.toolbars.isEmpty)                    // …with no toolbar step in between
    #expect(ui.failures.isEmpty)
}

@MainActor
@Test func windowCaptureShowsTheToolbarWhenOpenInEditorIsOff() async {
    let image = sampleImage()
    let region = sampleWindowRegion()
    let ui = SpyUI()
    let settings = StubSettings()
    settings.openInEditor = false
    let coordinator = AppCoordinator(
        captureService: StubCaptureService(.success(image)),
        overlay: StubOverlay(region: nil, windowRegion: region),
        imageSource: unusedImageSource(),
        imageSink: SpyImageSink(),
        settings: settings,
        ui: ui
    )

    await coordinator.captureWindow()

    #expect(ui.toolbars.count == 1)                 // the setting off brings the toolbar back
    #expect(ui.toolbars.first?.image == frozenSampleWindowCapture())
    #expect(ui.toolbars.first?.region == region)    // positioned at the window
    #expect(ui.openedImages.isEmpty)                // the toolbar, not the editor, is the surface
}

@MainActor
@Test func windowCaptureFirstRunPromptsThenRunsTheOverlay() async {
    // First-run onboarding (story 57) fronts the window path too, so a first-run user meets the
    // permission prompt before hover-picking a window.
    let ui = SpyUI()
    let capture = StubCaptureService(.success(sampleImage()), status: .notDetermined, requestResult: .authorized)
    let overlay = StubOverlay(region: nil, windowRegion: sampleWindowRegion())
    let coordinator = AppCoordinator(
        captureService: capture,
        overlay: overlay,
        imageSource: unusedImageSource(),
        imageSink: SpyImageSink(),
        settings: StubSettings(),
        ui: ui
    )

    await coordinator.captureWindow()

    #expect(capture.requestAuthorizationCount == 1)   // first run prompts
    #expect(overlay.windowCallCount == 1)             // …and the window overlay still resolves a target
    #expect(ui.openedImages.count == 1)               // success reaches the editor
}

@MainActor
@Test func escapeInWindowModeCancelsWithNoCapture() async {
    let ui = SpyUI()
    let capture = StubCaptureService(.success(sampleImage()))
    let coordinator = AppCoordinator(
        captureService: capture,
        overlay: StubOverlay(region: nil, windowRegion: nil),   // nil == user pressed Escape
        imageSource: unusedImageSource(),
        imageSink: SpyImageSink(),
        settings: StubSettings(),
        ui: ui
    )

    await coordinator.captureWindow()

    #expect(capture.capturedRegions.isEmpty)        // Escape captures nothing
    #expect(ui.toolbars.isEmpty)
    #expect(ui.openedImages.isEmpty)
    #expect(ui.permissionDeniedCount == 0)
    #expect(ui.failures.isEmpty)
}

@MainActor
@Test func windowCapturePermissionDeniedRoutesToRecoveryNotAToolbar() async {
    let ui = SpyUI()
    let coordinator = AppCoordinator(
        captureService: StubCaptureService(.failure(.permissionDenied)),
        overlay: StubOverlay(region: nil, windowRegion: sampleWindowRegion()),
        imageSource: unusedImageSource(),
        imageSink: SpyImageSink(),
        settings: StubSettings(),
        ui: ui
    )

    await coordinator.captureWindow()

    #expect(ui.permissionDeniedCount == 1)
    #expect(ui.toolbars.isEmpty)
    #expect(ui.openedImages.isEmpty)
    #expect(ui.failures.isEmpty)
}

@MainActor
@Test func windowCaptureUserCancelledIsASilentNoOp() async {
    let ui = SpyUI()
    let coordinator = AppCoordinator(
        captureService: StubCaptureService(.failure(.userCancelled)),
        overlay: StubOverlay(region: nil, windowRegion: sampleWindowRegion()),
        imageSource: unusedImageSource(),
        imageSink: SpyImageSink(),
        settings: StubSettings(),
        ui: ui
    )

    await coordinator.captureWindow()

    #expect(ui.toolbars.isEmpty)
    #expect(ui.openedImages.isEmpty)
    #expect(ui.permissionDeniedCount == 0)
    #expect(ui.failures.isEmpty)
}

@MainActor
@Test func windowCaptureOtherFailureSurfacesADistinctMessage() async {
    let ui = SpyUI()
    let coordinator = AppCoordinator(
        captureService: StubCaptureService(.failure(.noDisplayAvailable)),
        overlay: StubOverlay(region: nil, windowRegion: sampleWindowRegion()),
        imageSource: unusedImageSource(),
        imageSink: SpyImageSink(),
        settings: StubSettings(),
        ui: ui
    )

    await coordinator.captureWindow()

    #expect(ui.failures == [.noDisplayAvailable])
    #expect(ui.toolbars.isEmpty)
    #expect(ui.openedImages.isEmpty)
    #expect(ui.permissionDeniedCount == 0)
}

// MARK: - Open existing file routing (story 39)

@MainActor
@Test func openFileLoadsTheImageIntoTheEditorViaOpenEditor() async {
    // The loaded value is the *same* CapturedImage type a capture produces, and it reaches the
    // one shared editor entry — the editor never learns the pixels came from a file, not a capture.
    let image = sampleImage()
    let ui = SpyUI()
    let source = StubImageSource(.success(image))
    let coordinator = AppCoordinator(
        captureService: StubCaptureService(.failure(.noDisplayAvailable)),  // capture path unused here
        overlay: unusedOverlay(),
        imageSource: source,
        imageSink: SpyImageSink(),
        settings: StubSettings(),
        ui: ui
    )

    coordinator.openFile()

    #expect(source.openCount == 1)             // the picker is consulted once
    #expect(ui.openedImages == [image])        // …and the same CapturedImage reaches openEditor
    #expect(ui.imageLoadFailures.isEmpty)
    #expect(ui.permissionDeniedCount == 0)
}

@MainActor
@Test func openFileCancelledPanelIsASilentNoOp() async {
    let ui = SpyUI()
    let coordinator = AppCoordinator(
        captureService: StubCaptureService(.success(sampleImage())),
        overlay: unusedOverlay(),
        imageSource: StubImageSource(.failure(.userCancelled)),
        imageSink: SpyImageSink(),
        settings: StubSettings(),
        ui: ui
    )

    coordinator.openFile()

    #expect(ui.openedImages.isEmpty)           // a dismissed panel opens nothing…
    #expect(ui.imageLoadFailures.isEmpty)      // …and surfaces no error
    #expect(ui.permissionDeniedCount == 0)
}

@MainActor
@Test func openFileUnreadableSurfacesADistinctFailureNotABlankEditor() async {
    let ui = SpyUI()
    let coordinator = AppCoordinator(
        captureService: StubCaptureService(.success(sampleImage())),
        overlay: unusedOverlay(),
        imageSource: StubImageSource(.failure(.unreadable)),
        imageSink: SpyImageSink(),
        settings: StubSettings(),
        ui: ui
    )

    coordinator.openFile()

    #expect(ui.imageLoadFailures == [.unreadable])
    #expect(ui.openedImages.isEmpty)           // never a blank editor
}

@MainActor
@Test func openFileUnsupportedFormatSurfacesADistinctFailure() async {
    let ui = SpyUI()
    let coordinator = AppCoordinator(
        captureService: StubCaptureService(.success(sampleImage())),
        overlay: unusedOverlay(),
        imageSource: StubImageSource(.failure(.unsupportedFormat)),
        imageSink: SpyImageSink(),
        settings: StubSettings(),
        ui: ui
    )

    coordinator.openFile()

    #expect(ui.imageLoadFailures == [.unsupportedFormat])
    #expect(ui.openedImages.isEmpty)
}

// MARK: - Output (save & drag, stories 41–45)

@MainActor
@Test func saveWritesTheRenderedImageWithTheExactFormat() throws {
    let document = AnnotationDocument(baseImage: sampleImage())
    let sink = SpyImageSink()
    let coordinator = AppCoordinator(
        captureService: StubCaptureService(.success(document.baseImage)),
        overlay: unusedOverlay(),
        imageSource: unusedImageSource(),
        imageSink: sink,
        settings: StubSettings(),
        ui: SpyUI()
    )
    let url = URL(fileURLWithPath: "/tmp/out.jpg")

    try coordinator.save(document, to: url, format: .jpeg(quality: 0.42))

    #expect(sink.written.count == 1)
    #expect(sink.written.first?.image == render(document))   // flattened, not raw capture
    #expect(sink.written.first?.url == url)
    #expect(sink.written.first?.format == .jpeg(quality: 0.42))  // exact quality reaches the sink
}

@MainActor
@Test func defaultSaveUsesTheConfiguredLocationPatternAndFormat() throws {
    let document = AnnotationDocument(baseImage: sampleImage())
    let sink = SpyImageSink()
    let settings = StubSettings()
    settings.defaultFormat = .jpeg(quality: 0.8)
    settings.saveLocation = URL(fileURLWithPath: "/tmp/shots", isDirectory: true)
    settings.filenamePattern = "shot-%Y"
    let coordinator = AppCoordinator(
        captureService: StubCaptureService(.success(document.baseImage)),
        overlay: unusedOverlay(),
        imageSource: unusedImageSource(),
        imageSink: sink,
        settings: settings,
        ui: SpyUI()
    )
    // A fixed instant so the expanded name is deterministic (UTC 2026 → "shot-2026").
    var utc = Calendar(identifier: .gregorian)
    utc.timeZone = TimeZone(identifier: "UTC")!
    let date = utc.date(from: DateComponents(year: 2026, month: 6, day: 1))!

    let written = try coordinator.save(document, at: date)

    #expect(written.lastPathComponent == "shot-2026.jpg")
    #expect(written.deletingLastPathComponent().path == "/tmp/shots")
    #expect(sink.written.first?.format == .jpeg(quality: 0.8))  // the default is used with no override
}

@MainActor
@Test func dragItemCarriesTheRenderedBytesInTheDefaultFormat() {
    let document = AnnotationDocument(baseImage: sampleImage())
    let settings = StubSettings()
    settings.defaultFormat = .png
    settings.filenamePattern = "drag-%Y"
    let coordinator = AppCoordinator(
        captureService: StubCaptureService(.success(document.baseImage)),
        overlay: unusedOverlay(),
        imageSource: unusedImageSource(),
        imageSink: SpyImageSink(),
        settings: settings,
        ui: SpyUI()
    )
    var utc = Calendar(identifier: .gregorian)
    utc.timeZone = TimeZone(identifier: "UTC")!
    let date = utc.date(from: DateComponents(year: 2026, month: 6, day: 1))!

    let item = coordinator.dragItem(for: document, at: date)

    #expect(item.format == .png)
    #expect(item.suggestedName == "drag-2026")            // base name; the UTI supplies the extension
    #expect(item.data == encode(render(document), as: .png))
}

// MARK: - History recording (story 50)

/// A fresh history store in a throwaway temp directory, cleaned up by the caller.
@MainActor private func tempHistory() -> (store: HistoryStore, dir: URL) {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("coord-history-\(UUID().uuidString)")
    return (HistoryStore(directory: dir), dir)
}

@MainActor
@Test func fullscreenCaptureIsRecordedInHistory() async throws {
    let image = sampleImage()
    let ui = SpyUI()
    let (history, dir) = tempHistory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let coordinator = AppCoordinator(
        captureService: StubCaptureService(.success(image)),
        overlay: unusedOverlay(),
        imageSource: unusedImageSource(),
        imageSink: SpyImageSink(),
        settings: StubSettings(),
        history: history,
        ui: ui
    )

    await coordinator.captureFullscreen()

    let records = history.all()
    #expect(records.count == 1)
    #expect(records.first?.source == .fullscreen)
    #expect(history.capturedImage(for: records[0]) == image)   // the recorded bytes round-trip
}

@MainActor
@Test func areaCaptureIsRecordedInHistory() async throws {
    let ui = SpyUI()
    let (history, dir) = tempHistory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let coordinator = AppCoordinator(
        captureService: StubCaptureService(.success(sampleImage())),
        overlay: StubOverlay(region: sampleRegion()),
        imageSource: unusedImageSource(),
        imageSink: SpyImageSink(),
        settings: StubSettings(),
        history: history,
        ui: ui
    )

    await coordinator.captureArea()

    #expect(history.all().map(\.source) == [.area])
}

@MainActor
@Test func windowCaptureIsRecordedInHistory() async throws {
    let ui = SpyUI()
    let (history, dir) = tempHistory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let coordinator = AppCoordinator(
        captureService: StubCaptureService(.success(sampleImage())),
        overlay: StubOverlay(region: nil, windowRegion: sampleWindowRegion()),
        imageSource: unusedImageSource(),
        imageSink: SpyImageSink(),
        settings: StubSettings(),
        history: history,
        ui: ui
    )

    await coordinator.captureWindow()

    #expect(history.all().map(\.source) == [.window])
}

@MainActor
@Test func openingAFileIsNotRecordedInHistory() async throws {
    let ui = SpyUI()
    let (history, dir) = tempHistory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let coordinator = AppCoordinator(
        captureService: StubCaptureService(.failure(.userCancelled)),
        overlay: unusedOverlay(),
        imageSource: StubImageSource(.success(sampleImage())),
        imageSink: SpyImageSink(),
        settings: StubSettings(),
        history: history,
        ui: ui
    )

    coordinator.openFile()

    #expect(ui.openedImages == [sampleImage()])   // it reaches the editor …
    #expect(history.all().isEmpty)                // … but an opened file is not a capture
}

@MainActor
@Test func aFailedCaptureRecordsNothing() async throws {
    let ui = SpyUI()
    let (history, dir) = tempHistory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let coordinator = AppCoordinator(
        captureService: StubCaptureService(.failure(.permissionDenied)),
        overlay: unusedOverlay(),
        imageSource: unusedImageSource(),
        imageSink: SpyImageSink(),
        settings: StubSettings(),
        history: history,
        ui: ui
    )

    await coordinator.captureFullscreen()

    #expect(history.all().isEmpty)   // a permission failure never lands in history
}

// MARK: - Self-timer / delayed capture (story 10)

@MainActor
@Test func fullscreenWaitsTheConfiguredSelfTimerBeforeCapturing() async {
    let settings = StubSettings()
    settings.captureDelay = 3
    let capture = StubCaptureService(.success(sampleImage()))
    let delay = DelaySpy()
    let ui = SpyUI()
    let coordinator = AppCoordinator(
        captureService: capture, overlay: unusedOverlay(), imageSource: unusedImageSource(),
        imageSink: SpyImageSink(), settings: settings, sleep: { await delay.sleep($0) }, ui: ui
    )

    await coordinator.captureFullscreen()

    #expect(delay.waits == [3])                 // the timer fired once, for the configured interval
    #expect(capture.capturedDisplays.count == 1) // …and the capture still happened after it
}

@MainActor
@Test func areaWaitsTheSelfTimerAfterResolvingTheRegion() async {
    let settings = StubSettings()
    settings.captureDelay = 5
    let capture = StubCaptureService(.success(sampleImage()))
    let overlay = StubOverlay(region: sampleRegion())
    let delay = DelaySpy()
    let ui = SpyUI()
    let coordinator = AppCoordinator(
        captureService: capture, overlay: overlay, imageSource: unusedImageSource(),
        imageSink: SpyImageSink(), settings: settings, sleep: { await delay.sleep($0) }, ui: ui
    )

    await coordinator.captureArea()

    #expect(overlay.callCount == 1)             // the region is resolved first…
    #expect(delay.waits == [5])                 // …then the timer waits…
    #expect(capture.capturedRegions == [sampleRegion()])  // …then the shot fires
}

@MainActor
@Test func windowWaitsTheSelfTimerAfterPickingTheWindow() async {
    let settings = StubSettings()
    settings.captureDelay = 2
    let capture = StubCaptureService(.success(sampleImage()))
    let overlay = StubOverlay(region: nil, windowRegion: sampleWindowRegion())
    let delay = DelaySpy()
    let ui = SpyUI()
    let coordinator = AppCoordinator(
        captureService: capture, overlay: overlay, imageSource: unusedImageSource(),
        imageSink: SpyImageSink(), settings: settings, sleep: { await delay.sleep($0) }, ui: ui
    )

    await coordinator.captureWindow()

    #expect(delay.waits == [2])
    #expect(capture.capturedRegions == [sampleWindowRegion()])
}

@MainActor
@Test func aZeroSelfTimerSkipsTheWaitEntirely() async {
    let settings = StubSettings()
    settings.captureDelay = 0
    let capture = StubCaptureService(.success(sampleImage()))
    let delay = DelaySpy()
    let ui = SpyUI()
    let coordinator = AppCoordinator(
        captureService: capture, overlay: unusedOverlay(), imageSource: unusedImageSource(),
        imageSink: SpyImageSink(), settings: settings, sleep: { await delay.sleep($0) }, ui: ui
    )

    await coordinator.captureFullscreen()

    #expect(delay.waits.isEmpty)                // no delay when the timer is off
    #expect(capture.capturedDisplays.count == 1)
}

// MARK: - Display selection (story 8)

@MainActor
@Test func fullscreenTargetsTheChosenDisplay() async {
    let capture = StubCaptureService(.success(sampleImage()))
    let ui = SpyUI()
    let coordinator = AppCoordinator(
        captureService: capture,
        overlay: unusedOverlay(),
        imageSource: unusedImageSource(),
        imageSink: SpyImageSink(),
        settings: StubSettings(),
        ui: ui
    )

    await coordinator.captureFullscreen(displayID: 42)

    #expect(capture.capturedDisplays == [42])   // the chosen display id reaches the service
}

@MainActor
@Test func fullscreenDefaultsToThePrimaryDisplay() async {
    let capture = StubCaptureService(.success(sampleImage()))
    let ui = SpyUI()
    let coordinator = AppCoordinator(
        captureService: capture,
        overlay: unusedOverlay(),
        imageSource: unusedImageSource(),
        imageSink: SpyImageSink(),
        settings: StubSettings(),
        ui: ui
    )

    await coordinator.captureFullscreen()

    #expect(capture.capturedDisplays == [nil])  // no explicit choice == the primary display
}

// MARK: - Repeat last capture mode (story 9)

@MainActor
@Test func repeatWithNoPriorCaptureIsASilentNoOp() async {
    let capture = StubCaptureService(.success(sampleImage()))
    let ui = SpyUI()
    let coordinator = AppCoordinator(
        captureService: capture,
        overlay: unusedOverlay(),
        imageSource: unusedImageSource(),
        imageSink: SpyImageSink(),
        settings: StubSettings(),
        ui: ui
    )

    await coordinator.repeatLastCapture()

    #expect(capture.capturedDisplays.isEmpty)   // nothing has been captured, so nothing to repeat
    #expect(capture.capturedRegions.isEmpty)
    #expect(ui.openedImages.isEmpty)
}

@MainActor
@Test func repeatReplaysFullscreenIncludingTheChosenDisplay() async {
    let capture = StubCaptureService(.success(sampleImage()))
    let ui = SpyUI()
    let coordinator = AppCoordinator(
        captureService: capture,
        overlay: unusedOverlay(),
        imageSource: unusedImageSource(),
        imageSink: SpyImageSink(),
        settings: StubSettings(),
        ui: ui
    )

    await coordinator.captureFullscreen(displayID: 7)
    await coordinator.repeatLastCapture()

    #expect(capture.capturedDisplays == [7, 7])  // the repeat re-targets the same display
}

@MainActor
@Test func repeatReplaysAreaThroughTheOverlayAgain() async {
    let capture = StubCaptureService(.success(sampleImage()))
    let overlay = StubOverlay(region: sampleRegion())
    let ui = SpyUI()
    let coordinator = AppCoordinator(
        captureService: capture,
        overlay: overlay,
        imageSource: unusedImageSource(),
        imageSink: SpyImageSink(),
        settings: StubSettings(),
        ui: ui
    )

    await coordinator.captureArea()
    await coordinator.repeatLastCapture()

    #expect(overlay.callCount == 2)             // repeat re-runs the whole area flow, overlay included
    #expect(capture.freezeCount == 2)           // …freezing afresh each time
}

@MainActor
@Test func repeatUsesTheMostRecentModeNotAnEarlierOne() async {
    let capture = StubCaptureService(.success(sampleImage()))
    let overlay = StubOverlay(region: nil, windowRegion: sampleWindowRegion())
    let ui = SpyUI()
    let coordinator = AppCoordinator(
        captureService: capture,
        overlay: overlay,
        imageSource: unusedImageSource(),
        imageSink: SpyImageSink(),
        settings: StubSettings(),
        ui: ui
    )

    await coordinator.captureFullscreen()       // most-recent is fullscreen…
    await coordinator.captureWindow()           // …then window becomes most-recent
    await coordinator.repeatLastCapture()

    #expect(overlay.windowCallCount == 2)       // repeat replays window, the latest mode
    #expect(capture.capturedDisplays == [nil])  // …and does not re-fire the earlier fullscreen
}

// MARK: - OCR Text (spec 0010)

private func recognizedLine(_ text: String, y: Double) -> RecognizedLine {
    RecognizedLine(
        text: text,
        words: [RecognizedWord(range: 0..<text.utf16.count, box: Rect(x: 0, y: y, width: 100, height: 20))]
    )
}

@MainActor
private struct TextCaptureHarness {
    let capture: StubCaptureService
    let overlay: StubOverlay
    let recognizer: SpyTextRecognizer
    let sink = SpyImageSink()
    let settings = StubSettings()
    let ui = SpyUI()
    let delays = DelaySpy()
    let coordinator: AppCoordinator

    init(
        capture: Result<CapturedImage, CaptureError> = .success(sampleImage()),
        status: CaptureAuthorizationStatus = .authorized,
        requestResult: CaptureAuthorizationStatus = .authorized,
        region: CaptureRegion? = sampleRegion(),
        recognition: Result<[RecognizedLine], TextRecognitionError> = .success([])
    ) {
        self.capture = StubCaptureService(capture, status: status, requestResult: requestResult)
        overlay = StubOverlay(region: region)
        recognizer = SpyTextRecognizer(recognition)
        let delays = self.delays
        coordinator = AppCoordinator(
            captureService: self.capture,
            overlay: overlay,
            imageSource: unusedImageSource(),
            imageSink: sink,
            settings: settings,
            textRecognizer: recognizer,
            sleep: { await delays.sleep($0) },
            ui: ui
        )
    }
}

@MainActor
@Test func captureTextCopiesTheRecognisedTextOfTheSelectedArea() async {
    let h = TextCaptureHarness(recognition: .success([
        recognizedLine("second line", y: 40),
        recognizedLine("first line", y: 0),
    ]))

    await h.coordinator.captureText()

    #expect(h.overlay.callCount == 1)
    #expect(h.capture.capturedRegions.isEmpty)               // read from the frozen still…
    #expect(h.recognizer.recognized == [sampleFrozenScreen().image(of: sampleRegion())!])   // …cut to the selection
    #expect(h.sink.copiedText == ["first line\nsecond line"])
    #expect(h.ui.textResults == [.reading, .copied("first line\nsecond line")])
    #expect(h.ui.openedImages.isEmpty)                         // no editor
    #expect(h.ui.toolbars.isEmpty)                             // no post-capture toolbar
    #expect(h.sink.copied.isEmpty)                             // no image on the clipboard
}

@MainActor
@Test func captureTextCancelledOverlayDoesNothing() async {
    let h = TextCaptureHarness(region: nil)

    await h.coordinator.captureText()

    #expect(h.capture.capturedRegions.isEmpty)
    #expect(h.recognizer.recognized.isEmpty)
    #expect(h.sink.copiedText.isEmpty)
    #expect(h.ui.textResults.isEmpty)
}

@MainActor
@Test func captureTextWithNothingReadableLeavesTheClipboardAlone() async {
    for lines in [[], [recognizedLine("   ", y: 0)]] {
        let h = TextCaptureHarness(recognition: .success(lines))

        await h.coordinator.captureText()

        #expect(h.sink.copiedText.isEmpty)
        #expect(h.ui.textResults == [.reading, .noText])
    }
}

@MainActor
@Test func captureTextRecognitionFailureIsReportedAndCopiesNothing() async {
    let h = TextCaptureHarness(recognition: .failure(TextRecognitionError("Vision gave up")))

    await h.coordinator.captureText()

    #expect(h.sink.copiedText.isEmpty)
    #expect(h.ui.textResults == [.reading, .failed("Vision gave up")])
}

@MainActor
@Test func captureTextRoutesCaptureFailuresLikeAreaCapture() async {
    let denied = TextCaptureHarness(capture: .failure(.permissionDenied))
    await denied.coordinator.captureText()
    #expect(denied.ui.deniedKinds == [.screenRecording])
    #expect(denied.recognizer.recognized.isEmpty)
    #expect(denied.ui.textResults.isEmpty)

    let failed = TextCaptureHarness(capture: .failure(.systemFailure("boom")))
    await failed.coordinator.captureText()
    #expect(failed.ui.failures == [.systemFailure("boom")])
    #expect(failed.ui.textResults.isEmpty)

    let cancelled = TextCaptureHarness(capture: .failure(.userCancelled))
    await cancelled.coordinator.captureText()
    #expect(cancelled.ui.failures.isEmpty && cancelled.ui.textResults.isEmpty)
    #expect(cancelled.ui.permissionDeniedCount == 0)
}

@MainActor
@Test func captureTextRunsFirstRunOnboardingBeforeTheOverlay() async {
    // First ever capture: the system prompt goes up and returns un-authorized straight away.
    let h = TextCaptureHarness(status: .notDetermined, requestResult: .notDetermined)

    await h.coordinator.captureText()

    #expect(h.capture.requestAuthorizationCount == 1)
    #expect(h.overlay.callCount == 0)   // the system prompt is on screen, not our overlay
}

@MainActor
@Test func captureTextIgnoresTheSelfTimer() async {
    let h = TextCaptureHarness(recognition: .success([recognizedLine("hi", y: 0)]))
    h.settings.captureDelay = 3

    await h.coordinator.captureText()

    #expect(h.delays.waits.isEmpty)
    #expect(h.sink.copiedText == ["hi"])
}

@MainActor
@Test func captureTextLeavesRepeatLastCaptureOnTheLastScreenshot() async {
    let h = TextCaptureHarness()
    await h.coordinator.captureArea()
    await h.coordinator.captureText()
    await h.coordinator.repeatLastCapture()

    // area, OCR Text, then repeat → area again: three overlay runs, and the last one was an image
    // capture that reached the editor rather than another text capture.
    #expect(h.overlay.callCount == 3)
    #expect(h.ui.openedImages.count == 2)
    #expect(h.recognizer.recognized.count == 1)
}

@MainActor
@Test func captureTextWithoutARecognizerIsANoOp() async {
    let overlay = StubOverlay(region: sampleRegion())
    let ui = SpyUI()
    let coordinator = AppCoordinator(
        captureService: StubCaptureService(.success(sampleImage())),
        overlay: overlay,
        imageSource: unusedImageSource(),
        imageSink: SpyImageSink(),
        settings: StubSettings(),
        ui: ui
    )

    await coordinator.captureText()

    #expect(overlay.callCount == 0)
}

@MainActor
@Test func captureTextAddsNothingToHistory() async {
    let (history, dir) = tempHistory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let ui = SpyUI()
    let coordinator = AppCoordinator(
        captureService: StubCaptureService(.success(sampleImage())),
        overlay: StubOverlay(region: sampleRegion()),
        imageSource: unusedImageSource(),
        imageSink: SpyImageSink(),
        settings: StubSettings(),
        history: history,
        textRecognizer: SpyTextRecognizer(.success([recognizedLine("hi", y: 0)])),
        ui: ui
    )

    await coordinator.captureText()

    #expect(history.all().isEmpty)
}

// MARK: - Freeze Screen (spec 0011)

@MainActor
private func frozenCoordinator(
    capture: StubCaptureService,
    overlay: StubOverlay,
    settings: StubSettings = StubSettings(),
    history: HistoryStore? = nil,
    recognizer: SpyTextRecognizer? = nil,
    sink: SpyImageSink = SpyImageSink(),
    delays: DelaySpy = DelaySpy(),
    ui: SpyUI
) -> AppCoordinator {
    AppCoordinator(
        captureService: capture,
        overlay: overlay,
        imageSource: unusedImageSource(),
        imageSink: sink,
        settings: settings,
        history: history,
        textRecognizer: recognizer,
        sleep: { await delays.sleep($0) },
        ui: ui
    )
}

@MainActor
@Test func areaCaptureSelectsOverTheFrozenScreenAndOpensItsCrop() async throws {
    let capture = StubCaptureService(.success(sampleImage()))
    let overlay = StubOverlay(region: sampleRegion())
    let ui = SpyUI()
    let coordinator = frozenCoordinator(capture: capture, overlay: overlay, ui: ui)

    await coordinator.captureArea()

    #expect(capture.freezeCount == 1)
    #expect(overlay.backdrops == [sampleFrozenScreen()])      // the overlay sits on the still
    #expect(capture.capturedRegions.isEmpty)                  // no second, live capture
    let opened = try #require(ui.openedImages.first)
    #expect(opened == sampleFrozenScreen().image(of: sampleRegion()))
    #expect(opened.pixelWidth == 1280)                        // 640 × 480 pt at 2x
    #expect(opened.pixelHeight == 960)
}

@MainActor
@Test func areaCaptureOfTheFrozenScreenShowsTheToolbarAndIsRecordedInHistory() async throws {
    let settings = StubSettings()
    settings.openInEditor = false
    let (history, dir) = tempHistory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let overlay = StubOverlay(region: sampleRegion())
    let ui = SpyUI()
    let coordinator = frozenCoordinator(
        capture: StubCaptureService(.success(sampleImage())),
        overlay: overlay, settings: settings, history: history, ui: ui
    )

    await coordinator.captureArea()

    let crop = sampleFrozenScreen().image(of: sampleRegion())
    #expect(ui.toolbars.first?.image == crop)
    #expect(ui.toolbars.first?.region == sampleRegion())
    let records = history.all()
    #expect(records.map(\.pixelWidth) == [1280])
    #expect(history.capturedImage(for: records[0]) == crop)
}

@MainActor
@Test func aFailedFreezeRoutesLikeACaptureFailureAndNeverShowsTheOverlay() async {
    for (error, expectDenied, expectFailure) in [
        (CaptureError.permissionDenied, true, false),
        (CaptureError.systemFailure("boom"), false, true),
        (CaptureError.userCancelled, false, false),
    ] {
        let overlay = StubOverlay(region: sampleRegion(), windowRegion: sampleWindowRegion())
        let ui = SpyUI()
        let capture = StubCaptureService(.success(sampleImage()), freeze: .failure(error))
        let coordinator = frozenCoordinator(capture: capture, overlay: overlay, ui: ui)

        await coordinator.captureArea()
        await coordinator.captureWindow()

        #expect(overlay.backdrops.isEmpty)                    // never a blank or black selection
        #expect(capture.capturedRegions.isEmpty)
        #expect(ui.openedImages.isEmpty)
        #expect(ui.deniedKinds == (expectDenied ? [.screenRecording, .screenRecording] : []))
        #expect(ui.failures.count == (expectFailure ? 2 : 0))
    }
}

@MainActor
@Test func aSelectionOffTheFrozenScreenIsAFailureNotABlankEditor() async {
    let overlay = StubOverlay(region: .rect(Rect(x: 5000, y: 5000, width: 100, height: 100)))
    let ui = SpyUI()
    let coordinator = frozenCoordinator(
        capture: StubCaptureService(.success(sampleImage())), overlay: overlay, ui: ui
    )

    await coordinator.captureArea()

    #expect(ui.openedImages.isEmpty)
    #expect(ui.failures.count == 1)
}

@MainActor
@Test func escapeOverTheFrozenScreenCapturesNothing() async {
    let capture = StubCaptureService(.success(sampleImage()))
    let ui = SpyUI()
    let (history, dir) = tempHistory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let coordinator = frozenCoordinator(
        capture: capture, overlay: StubOverlay(region: nil), history: history, ui: ui
    )

    await coordinator.captureArea()

    #expect(capture.capturedRegions.isEmpty)
    #expect(ui.openedImages.isEmpty)
    #expect(ui.failures.isEmpty)
    #expect(history.all().isEmpty)
}

@MainActor
@Test func areaCaptureWithASelfTimerSkipsTheFreezeAndCapturesLive() async {
    let settings = StubSettings()
    settings.captureDelay = 3
    let capture = StubCaptureService(.success(sampleImage()))
    let overlay = StubOverlay(region: sampleRegion())
    let delays = DelaySpy()
    let ui = SpyUI()
    let coordinator = frozenCoordinator(
        capture: capture, overlay: overlay, settings: settings, delays: delays, ui: ui
    )

    await coordinator.captureArea()

    #expect(capture.freezeCount == 0)
    #expect(overlay.backdrops == [nil])                       // the live screen
    #expect(delays.waits == [3])
    #expect(capture.capturedRegions == [sampleRegion()])
    #expect(ui.openedImages == [sampleImage()])
}

@MainActor
@Test func windowCaptureGivesThePickedWindowAsItWasAtTheFreeze() async throws {
    let capture = StubCaptureService(.success(sampleImage()))
    let overlay = StubOverlay(region: nil, windowRegion: sampleWindowRegion())
    let ui = SpyUI()
    let coordinator = frozenCoordinator(capture: capture, overlay: overlay, ui: ui)

    await coordinator.captureWindow()

    #expect(capture.windowImagesRequestCount == 1)            // window images grabbed at the freeze
    #expect(overlay.backdrops == [sampleFrozenScreen()])
    #expect(capture.capturedRegions.isEmpty)                  // no live grab at the click
    let opened = try #require(ui.openedImages.first)
    #expect(opened == frozenSampleWindowCapture())
    #expect(opened.pixelWidth == 1600)                        // the frozen window's own image
}

@MainActor
@Test func aWindowWithNoFrozenImageIsCapturedLive() async {
    let capture = StubCaptureService(.success(sampleImage()))
    capture.windowImages = [:]                                // its own grab failed
    let ui = SpyUI()
    let coordinator = frozenCoordinator(
        capture: capture, overlay: StubOverlay(region: nil, windowRegion: sampleWindowRegion()), ui: ui
    )

    await coordinator.captureWindow()

    #expect(capture.capturedRegions == [sampleWindowRegion()])
    #expect(ui.openedImages == [sampleImage()])
}

@MainActor
@Test func windowCaptureWithASelfTimerFreezesThePickerButCapturesLiveAfterTheWait() async {
    let settings = StubSettings()
    settings.captureDelay = 2
    let capture = StubCaptureService(.success(sampleImage()))
    let overlay = StubOverlay(region: nil, windowRegion: sampleWindowRegion())
    let delays = DelaySpy()
    let ui = SpyUI()
    let coordinator = frozenCoordinator(
        capture: capture, overlay: overlay, settings: settings, delays: delays, ui: ui
    )

    await coordinator.captureWindow()

    #expect(capture.windowImagesRequestCount == 0)            // no window images: they'd go unused
    #expect(overlay.backdrops == [sampleFrozenScreen()])
    #expect(delays.waits == [2])
    #expect(capture.capturedRegions == [sampleWindowRegion()])
    #expect(ui.openedImages == [sampleImage()])
}

@MainActor
@Test func areaAndOCRFreezesSkipTheWindowImages() async {
    let h = TextCaptureHarness(recognition: .success([recognizedLine("hi", y: 0)]))

    await h.coordinator.captureArea()
    await h.coordinator.captureText()

    #expect(h.capture.freezeCount == 2)
    #expect(h.capture.windowImagesRequestCount == 0)
}

@MainActor
@Test func ocrTextReadsTheFrozenPixelsOfTheSelection() async {
    let h = TextCaptureHarness(recognition: .success([recognizedLine("frozen", y: 0)]))

    await h.coordinator.captureText()

    #expect(h.overlay.backdrops == [sampleFrozenScreen()])
    #expect(h.capture.capturedRegions.isEmpty)
    #expect(h.recognizer.recognized == [sampleFrozenScreen().image(of: sampleRegion())!])
    #expect(h.sink.copiedText == ["frozen"])
}

@MainActor
@Test func ocrTextFreezeFailureRoutesLikeACaptureFailure() async {
    let h = TextCaptureHarness(capture: .failure(.permissionDenied))

    await h.coordinator.captureText()

    #expect(h.overlay.backdrops.isEmpty)
    #expect(h.recognizer.recognized.isEmpty)
    #expect(h.ui.deniedKinds == [.screenRecording])
}

@MainActor
@Test func repeatingAnAreaCaptureFreezesAfresh() async {
    let capture = StubCaptureService(.success(sampleImage()))
    let ui = SpyUI()
    let coordinator = frozenCoordinator(capture: capture, overlay: StubOverlay(region: sampleRegion()), ui: ui)

    await coordinator.captureArea()
    await coordinator.repeatLastCapture()

    #expect(capture.freezeCount == 2)
    #expect(ui.openedImages.count == 2)
}

@MainActor
@Test func fullscreenNeverFreezes() async {
    let capture = StubCaptureService(.success(sampleImage()))
    let ui = SpyUI()
    let coordinator = frozenCoordinator(capture: capture, overlay: unusedOverlay(), ui: ui)

    await coordinator.captureFullscreen()

    #expect(capture.freezeCount == 0)
}
