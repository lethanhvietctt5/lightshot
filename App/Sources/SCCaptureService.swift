import AppKit
import ScreenCaptureKit
import LightshotKit

/// ScreenCaptureKit-backed `CaptureService` (the OS side of the capture seam).
///
/// A thin wrapper with no unit tests — it needs a real display + TCC state; the coordinator routing
/// it feeds is tested against a fake. Fullscreen (LIG-7) captures the whole primary display; the
/// area path (LIG-13) captures that display and crops to the overlay's `CaptureRegion`. macOS 14+
/// only: uses `SCScreenshotManager`, never the deprecated `CGWindowListCreateImage`.
///
/// Area capture targets the **primary display** in v1 (the same `content.displays.first` fullscreen
/// uses), matching the selection overlay, which runs on the main screen. Per-display area selection
/// on a multi-monitor setup is a follow-up.
final class SCCaptureService: CaptureService {
    func captureFullscreen() async -> Result<CapturedImage, CaptureError> {
        await capture { full, _ in full }
    }

    func captureRegion(_ region: CaptureRegion) async -> Result<CapturedImage, CaptureError> {
        guard case let .rect(rect) = region else {
            return .failure(.systemFailure("Unsupported capture region."))
        }
        return await capture { full, scale in
            // The selection arrives in screen points (top-left origin); the captured image is the
            // display at native pixels, also top-left origin — so the crop is the selection scaled
            // to pixels, clamped to the image so an overshoot at the edge can't fail the crop.
            let standardized = rect.standardized
            let pixelRect = CGRect(
                x: (standardized.minX * scale).rounded(.down),
                y: (standardized.minY * scale).rounded(.down),
                width: (standardized.width * scale).rounded(),
                height: (standardized.height * scale).rounded()
            ).intersection(CGRect(x: 0, y: 0, width: full.width, height: full.height))
            guard !pixelRect.isNull, !pixelRect.isEmpty else { return nil }
            return full.cropping(to: pixelRect)
        }
    }

    /// Captures the primary display's full image, hands it (with the display's backing scale) to
    /// `transform` to produce the final `CGImage`, then encodes it — sharing the shareable-content
    /// query, permission mapping, and PNG encoding across the fullscreen and region paths.
    private func capture(
        _ transform: (_ full: CGImage, _ scale: CGFloat) -> CGImage?
    ) async -> Result<CapturedImage, CaptureError> {
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

            let fullImage = try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: config
            )
            guard let cgImage = transform(fullImage, scale) else {
                return .failure(.systemFailure("The selected region was empty."))
            }
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
