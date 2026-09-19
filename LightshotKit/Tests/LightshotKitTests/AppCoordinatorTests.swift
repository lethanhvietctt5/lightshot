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
    func copyToClipboard(_ image: RenderedImage) { copied.append(image) }
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
    let image = sampleImage()
    let sink = SpyImageSink()
    let coordinator = AppCoordinator(
        captureService: StubCaptureService(.success(image)),
        imageSink: sink,
        ui: SpyUI()
    )

    coordinator.copyToClipboard(image)

    #expect(sink.copied == [render(image)])   // the rendered image, not the raw capture
}
