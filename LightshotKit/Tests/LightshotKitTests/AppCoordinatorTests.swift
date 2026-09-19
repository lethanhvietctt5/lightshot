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
    init(_ result: Result<CapturedImage, CaptureError>) { self.result = result }
    func captureFullscreen() async -> Result<CapturedImage, CaptureError> { result }
    func captureRegion(_ region: CaptureRegion) async -> Result<CapturedImage, CaptureError> {
        capturedRegions.append(region)
        return result
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
    init(region: CaptureRegion?, windowRegion: CaptureRegion? = nil) {
        self.region = region
        self.windowRegion = windowRegion
    }
    func selectRegion() async -> CaptureRegion? { callCount += 1; return region }
    func selectWindow() async -> CaptureRegion? { windowCallCount += 1; return windowRegion }
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
    private(set) var imageLoadFailures: [ImageLoadError] = []

    func openEditor(with image: CapturedImage) { openedImages.append(image) }
    func presentPostCaptureToolbar(for image: CapturedImage, at region: CaptureRegion) {
        toolbars.append((image, region))
    }
    func presentPermissionDenied() { permissionDeniedCount += 1 }
    func presentCaptureFailure(_ error: CaptureError) { failures.append(error) }
    func presentImageLoadFailure(_ error: ImageLoadError) { imageLoadFailures.append(error) }
}

private func sampleImage() -> CapturedImage {
    CapturedImage(pixelWidth: 2560, pixelHeight: 1440, data: Data([0x89, 0x50, 0x4E, 0x47]))
}

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
        imageSource: unusedImageSource(),
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
@Test func windowCaptureResolvesWindowThenCapturesItAndShowsTheToolbar() async {
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
    #expect(capture.capturedRegions == [region])    // …then the resolved window is captured
    #expect(ui.toolbars.count == 1)                 // success shows the post-capture toolbar
    #expect(ui.toolbars.first?.image == image)
    #expect(ui.toolbars.first?.region == region)    // positioned at the window
    #expect(ui.openedImages.isEmpty)                // the toolbar, not a blank editor, is the surface
    #expect(ui.failures.isEmpty)
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
