import Testing
import Foundation
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
    // Authorization surface (LIG-19). `status` defaults to `.authorized` so the pre-existing
    // routing tests never trip onboarding; the onboarding tests set it explicitly and read the
    // call counts back. `requestAuthorization()` flips the reported status to `requestResult`,
    // mimicking the real prompt updating the world.
    var status: CaptureAuthorizationStatus
    let requestResult: CaptureAuthorizationStatus
    private(set) var authorizationStatusCount = 0
    private(set) var requestAuthorizationCount = 0

    init(
        _ result: Result<CapturedImage, CaptureError>,
        status: CaptureAuthorizationStatus = .authorized,
        requestResult: CaptureAuthorizationStatus = .authorized
    ) {
        self.result = result
        self.status = status
        self.requestResult = requestResult
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

    func captureFullscreen() async -> Result<CapturedImage, CaptureError> { result }
    func captureRegion(_ region: CaptureRegion) async -> Result<CapturedImage, CaptureError> {
        capturedRegions.append(region)
        return result
    }
}

@MainActor
private final class StubOverlay: OverlayController {
    let region: CaptureRegion?
    private(set) var callCount = 0
    init(region: CaptureRegion?) { self.region = region }
    func selectRegion() async -> CaptureRegion? { callCount += 1; return region }
}

private final class SpyImageSink: ImageSink {
    private(set) var copied: [RenderedImage] = []
    private(set) var written: [(image: RenderedImage, url: URL, format: ImageFormat)] = []
    func copyToClipboard(_ image: RenderedImage) { copied.append(image) }
    func write(_ image: RenderedImage, to url: URL, format: ImageFormat) throws {
        written.append((image, url, format))
    }
}

@MainActor
private final class StubSettings: SettingsStore {
    var defaultFormat: ImageFormat = .png
    var saveLocation = URL(fileURLWithPath: "/tmp/shots", isDirectory: true)
    var filenamePattern = "shot-%Y"
}

@MainActor
private final class SpyUI: CaptureUI {
    private(set) var openedImages: [CapturedImage] = []
    private(set) var toolbars: [(image: CapturedImage, region: CaptureRegion)] = []
    private(set) var permissionDeniedCount = 0
    private(set) var failures: [CaptureError] = []

    func openEditor(with image: CapturedImage) { openedImages.append(image) }
    func presentPostCaptureToolbar(for image: CapturedImage, at region: CaptureRegion) {
        toolbars.append((image, region))
    }
    func presentPermissionDenied() { permissionDeniedCount += 1 }
    func presentCaptureFailure(_ error: CaptureError) { failures.append(error) }
}

private func sampleImage() -> CapturedImage {
    CapturedImage(pixelWidth: 2560, pixelHeight: 1440, data: Data([0x89, 0x50, 0x4E, 0x47]))
}

private func sampleRegion() -> CaptureRegion {
    .rect(Rect(x: 120, y: 80, width: 640, height: 480))
}

/// An overlay that is never expected to be consulted (the fullscreen path skips it).
@MainActor private func unusedOverlay() -> StubOverlay { StubOverlay(region: nil) }

// MARK: - Capture routing

@MainActor
@Test func successfulCaptureReachesEditorWithTheImage() async {
    let image = sampleImage()
    let ui = SpyUI()
    let coordinator = AppCoordinator(
        captureService: StubCaptureService(.success(image)),
        overlay: unusedOverlay(),
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
        imageSink: SpyImageSink(),
        settings: StubSettings(),
        ui: ui
    )

    await coordinator.captureFullscreen()

    #expect(ui.permissionDeniedCount == 1)
    #expect(ui.openedImages.isEmpty)          // the editor is never opened blank/black
    #expect(ui.failures.isEmpty)
}

@MainActor
@Test func userCancelledIsASilentNoOp() async {
    let ui = SpyUI()
    let coordinator = AppCoordinator(
        captureService: StubCaptureService(.failure(.userCancelled)),
        overlay: unusedOverlay(),
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
        imageSink: SpyImageSink(),
        settings: StubSettings(),
        ui: ui
    )

    await coordinator.captureFullscreen()

    #expect(capture.requestAuthorizationCount == 0)   // no re-prompt on a standing denial
    #expect(ui.permissionDeniedCount == 1)            // recovery, driven by the capture result
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
        imageSink: SpyImageSink(),
        settings: StubSettings(),
        ui: ui
    )

    await coordinator.captureArea()

    #expect(capture.requestAuthorizationCount == 1)   // first run prompts
    #expect(overlay.callCount == 1)                   // …and the overlay still resolves a region
    #expect(ui.toolbars.count == 1)                   // success reaches the post-capture toolbar
}

// MARK: - Output

@MainActor
@Test func copyPlacesTheRenderedImageOnTheClipboard() async {
    let document = AnnotationDocument(baseImage: sampleImage())
    let sink = SpyImageSink()
    let coordinator = AppCoordinator(
        captureService: StubCaptureService(.success(document.baseImage)),
        overlay: unusedOverlay(),
        imageSink: sink,
        settings: StubSettings(),
        ui: SpyUI()
    )

    coordinator.copyToClipboard(document)

    #expect(sink.copied == [render(document)])   // the flattened document, not the raw capture
}

// MARK: - Area capture routing (stories 1–5, 14)

@MainActor
@Test func areaCaptureResolvesRegionThenCapturesItAndShowsTheToolbar() async {
    let image = sampleImage()
    let region = sampleRegion()
    let ui = SpyUI()
    let capture = StubCaptureService(.success(image))
    let overlay = StubOverlay(region: region)
    let coordinator = AppCoordinator(
        captureService: capture,
        overlay: overlay,
        imageSink: SpyImageSink(),
        settings: StubSettings(),
        ui: ui
    )

    await coordinator.captureArea()

    #expect(overlay.callCount == 1)                 // the overlay runs first, once
    #expect(capture.capturedRegions == [region])    // …then the resolved region is captured
    #expect(ui.toolbars.count == 1)                 // success shows the post-capture toolbar
    #expect(ui.toolbars.first?.image == image)
    #expect(ui.toolbars.first?.region == region)    // positioned at the selection
    #expect(ui.openedImages.isEmpty)                // the toolbar, not a blank editor, is the surface
    #expect(ui.failures.isEmpty)
}

@MainActor
@Test func escapeInTheOverlayCancelsWithNoCapture() async {
    let ui = SpyUI()
    let capture = StubCaptureService(.success(sampleImage()))
    let coordinator = AppCoordinator(
        captureService: capture,
        overlay: StubOverlay(region: nil),          // nil == user pressed Escape
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

// MARK: - Output (save & drag, stories 41–45)

@MainActor
@Test func saveWritesTheRenderedImageWithTheExactFormat() throws {
    let document = AnnotationDocument(baseImage: sampleImage())
    let sink = SpyImageSink()
    let coordinator = AppCoordinator(
        captureService: StubCaptureService(.success(document.baseImage)),
        overlay: unusedOverlay(),
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
