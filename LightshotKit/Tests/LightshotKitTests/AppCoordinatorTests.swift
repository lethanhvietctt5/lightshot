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

@MainActor
private final class StubOverlay: OverlayController {
    let region: CaptureRegion?
    private(set) var callCount = 0
    init(region: CaptureRegion?) { self.region = region }
    func selectRegion() async -> CaptureRegion? { callCount += 1; return region }
}

private final class SpyImageSink: ImageSink {
    private(set) var copied: [RenderedImage] = []
    func copyToClipboard(_ image: RenderedImage) { copied.append(image) }
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
        imageSink: sink,
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
        ui: ui
    )

    await coordinator.captureArea()

    #expect(ui.failures == [.noDisplayAvailable])
    #expect(ui.toolbars.isEmpty)
    #expect(ui.openedImages.isEmpty)
    #expect(ui.permissionDeniedCount == 0)
}
