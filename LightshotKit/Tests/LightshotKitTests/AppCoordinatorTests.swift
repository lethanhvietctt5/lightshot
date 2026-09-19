import Testing
import Foundation
@testable import LightshotKit

// Coordinator routing for the fullscreen tracer bullet (stories 8, 40, 44, 57–58).
// These run with **no AppKit / ScreenCaptureKit imports** — fakes stand in for the OS seams,
// which is the whole point of fronting capture/clipboard/UI as protocols.

// MARK: - Fakes

private final class StubCaptureService: CaptureService {
    let result: Result<CapturedImage, CaptureError>
    init(_ result: Result<CapturedImage, CaptureError>) { self.result = result }
    func captureFullscreen() async -> Result<CapturedImage, CaptureError> { result }
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
    private(set) var permissionDeniedCount = 0
    private(set) var failures: [CaptureError] = []

    func openEditor(with image: CapturedImage) { openedImages.append(image) }
    func presentPermissionDenied() { permissionDeniedCount += 1 }
    func presentCaptureFailure(_ error: CaptureError) { failures.append(error) }
}

private func sampleImage() -> CapturedImage {
    CapturedImage(pixelWidth: 2560, pixelHeight: 1440, data: Data([0x89, 0x50, 0x4E, 0x47]))
}

// MARK: - Capture routing

@MainActor
@Test func successfulCaptureReachesEditorWithTheImage() async {
    let image = sampleImage()
    let ui = SpyUI()
    let coordinator = AppCoordinator(
        captureService: StubCaptureService(.success(image)),
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
        imageSink: sink,
        settings: StubSettings(),
        ui: SpyUI()
    )

    coordinator.copyToClipboard(document)

    #expect(sink.copied == [render(document)])   // the flattened document, not the raw capture
}

@MainActor
@Test func saveWritesTheRenderedImageWithTheExactFormat() throws {
    let document = AnnotationDocument(baseImage: sampleImage())
    let sink = SpyImageSink()
    let coordinator = AppCoordinator(
        captureService: StubCaptureService(.success(document.baseImage)),
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
