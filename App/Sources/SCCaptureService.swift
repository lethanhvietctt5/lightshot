import AppKit
import ScreenCaptureKit
import LightshotKit

/// ScreenCaptureKit-backed `CaptureService` (the OS side of the capture seam).
///
/// Only the fullscreen path exists for this tracer bullet. It is a thin wrapper — no unit tests
/// (it needs a real display + TCC state); the coordinator routing it feeds is tested against a fake.
/// macOS 14+ only: uses `SCScreenshotManager`, never the deprecated `CGWindowListCreateImage`.
final class SCCaptureService: CaptureService {
    func captureFullscreen() async -> Result<CapturedImage, CaptureError> {
        do {
            // The shareable-content query is the first thing that fails when Screen Recording
            // permission is missing — it surfaces as SCStreamError.userDeclined.
            let content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: false
            )
            guard let display = content.displays.first else {
                return .failure(.noDisplayAvailable)
            }

            let filter = SCContentFilter(display: display, excludingWindows: [])
            let config = SCStreamConfiguration()
            // Native (Retina) resolution: display dimensions are in points; scale up to pixels
            // using *this* display's backing scale — not the main screen's, which may differ on a
            // multi-monitor setup or when the captured display isn't the primary one.
            let scale = Self.backingScale(for: display)
            config.width = Int((CGFloat(display.width) * scale).rounded())
            config.height = Int((CGFloat(display.height) * scale).rounded())
            config.showsCursor = false

            let cgImage = try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: config
            )
            guard let data = Self.pngData(from: cgImage) else {
                return .failure(.systemFailure("Could not encode the captured image as PNG."))
            }
            return .success(
                CapturedImage(pixelWidth: cgImage.width, pixelHeight: cgImage.height, data: data)
            )
        } catch {
            return .failure(Self.mapError(error))
        }
    }

    /// The status check is advisory; this actual capture call is authoritative — a permission
    /// revoked after any preflight still lands here as `userDeclined`.
    private static func mapError(_ error: Error) -> CaptureError {
        let nsError = error as NSError
        if nsError.domain == SCStreamErrorDomain,
           nsError.code == SCStreamError.Code.userDeclined.rawValue {
            return .permissionDenied
        }
        return .systemFailure(nsError.localizedDescription)
    }

    /// The backing scale of the specific captured display, found by matching its `displayID`
    /// against the `NSScreen` list. Falls back to 2 (typical Retina) if no match is found.
    private static func backingScale(for display: SCDisplay) -> CGFloat {
        let screenNumberKey = NSDeviceDescriptionKey("NSScreenNumber")
        let screen = NSScreen.screens.first {
            ($0.deviceDescription[screenNumberKey] as? CGDirectDisplayID) == display.displayID
        }
        return screen?.backingScaleFactor ?? 2
    }

    private static func pngData(from cgImage: CGImage) -> Data? {
        let rep = NSBitmapImageRep(cgImage: cgImage)
        return rep.representation(using: .png, properties: [:])
    }
}
