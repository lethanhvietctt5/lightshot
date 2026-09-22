import AppKit
import ScreenCaptureKit
import LightshotKit

/// ScreenCaptureKit-backed `CaptureService` (the OS side of the capture seam).
///
/// A thin wrapper with no unit tests — it needs a real display + TCC state; the coordinator routing
/// it feeds is tested against a fake. Three paths, one seam: fullscreen (LIG-7) captures the whole
/// primary display; the area path (LIG-13) captures that display and crops to the overlay's `.rect`;
/// the window path (LIG-14) captures a single `.window` by its id via a window content filter — just
/// that window, its shadow trimmed. macOS 14+ only: uses `SCScreenshotManager`, never the deprecated
/// `CGWindowListCreateImage`.
///
/// Fullscreen honors the chosen display on a multi-monitor setup (LIG-20, story 8): a passed
/// `displayID` selects that `SCDisplay`, and `nil` falls back to the primary display. The area and
/// window paths still target the **primary display** (the main screen's backing scale for the window
/// path), matching the overlay, which runs on the main screen.
final class SCCaptureService: CaptureService {
    /// Persisted "have we ever asked?" flag. macOS's preflight (`CGPreflightScreenCaptureAccess`)
    /// is only two-state — it can't tell a never-asked first run from a standing denial — so we
    /// remember whether `requestAuthorization()` has run to recover the `.notDetermined` case that
    /// drives first-run onboarding (story 57).
    static let hasRequestedDefaultsKey = "com.lightshot.hasRequestedScreenRecordingAccess"

    /// Whether to draw the cursor into the capture (story 12). A closure, not a stored flag, so it
    /// reads the live `SettingsStore` value at capture time rather than a value frozen at launch.
    private let includeCursor: @Sendable () -> Bool

    init(includeCursor: @escaping @Sendable () -> Bool = { false }) {
        self.includeCursor = includeCursor
    }

    /// Advisory Screen Recording status. `authorized` when the preflight passes; otherwise
    /// `notDetermined` until we've prompted once, then `denied`. The capture call stays the
    /// authority — this only decides whether onboarding prompts.
    func authorizationStatus() async -> CaptureAuthorizationStatus {
        if CGPreflightScreenCaptureAccess() {
            return .authorized
        }
        return UserDefaults.standard.bool(forKey: Self.hasRequestedDefaultsKey) ? .denied : .notDetermined
    }

    /// Trigger the one-time system prompt and report the status as of the call returning —
    /// `CGRequestScreenCaptureAccess()` doesn't wait for the user, so a first ask is always
    /// un-authorized here, with the system prompt still on screen. Recording that we've
    /// asked lets a later `authorizationStatus()` report `.denied` (recovery) rather than
    /// `.notDetermined` (re-prompt) — the OS itself only ever prompts once.
    @discardableResult
    func requestAuthorization() async -> CaptureAuthorizationStatus {
        let granted = CGRequestScreenCaptureAccess()
        UserDefaults.standard.set(true, forKey: Self.hasRequestedDefaultsKey)
        return granted ? .authorized : .denied
    }

    func captureFullscreen(displayID: UInt32?) async -> Result<CapturedImage, CaptureError> {
        await capture(displayID: displayID) { full, _ in full }
    }

    func captureRegion(_ region: CaptureRegion) async -> Result<CapturedImage, CaptureError> {
        switch region {
        case let .rect(rect):
            return await captureRect(rect)
        case let .window(id, _):
            // The overlay resolved a window id; capture that single window cleanly. The carried
            // frame is only for toolbar placement, so it's unused here — the live window is the
            // source of truth for what to capture.
            return await captureWindow(id: id)
        case let .display(id):
            // A whole display (recording's record mode, spec 0006) is exactly a fullscreen capture
            // of that display.
            return await captureFullscreen(displayID: id)
        }
    }

    private func captureRect(_ rect: Rect) async -> Result<CapturedImage, CaptureError> {
        // The overlay runs on the main screen, so the rect is captured from the primary display.
        await capture(displayID: nil) { full, scale in
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

    /// Captures a single window by its `CGWindowID` (LIG-14, stories 6–7) — just that window, none
    /// of its surroundings. Unlike the rect path this uses a *window* content filter rather than
    /// cropping a display grab, so the result is exactly the window's bounds with its shadow trimmed
    /// off. The id is re-resolved to the live `SCWindow` here so a window that closed between the
    /// overlay hover and the click surfaces a typed failure, never a blank capture.
    private func captureWindow(id: CGWindowID) async -> Result<CapturedImage, CaptureError> {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: true
            )
            guard let window = content.windows.first(where: { $0.windowID == id }) else {
                return .failure(.systemFailure("The selected window is no longer available."))
            }

            let filter = SCContentFilter(desktopIndependentWindow: window)
            let config = SCStreamConfiguration()
            // Native (Retina) resolution: the window frame is in points; scale up to pixels. v1
            // targets the primary display (same scope as the rect path and the overlay), so the
            // main screen's backing scale is used; per-display window capture is a follow-up.
            let scale = (NSScreen.main ?? NSScreen.screens.first)?.backingScaleFactor ?? 2
            config.width = Int((window.frame.width * scale).rounded())
            config.height = Int((window.frame.height * scale).rounded())
            config.showsCursor = includeCursor()   // honor the cursor toggle here too (story 12)
            // Trim the drop shadow so the capture is the window's own content, not its surroundings.
            config.ignoreShadowsSingleWindow = true

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

    /// Captures a display's full image, hands it (with the display's backing scale) to `transform`
    /// to produce the final `CGImage`, then encodes it — sharing the shareable-content query,
    /// permission mapping, and PNG encoding across the fullscreen and region paths.
    ///
    /// `displayID` selects the target on a multi-monitor setup (story 8): the matching `SCDisplay`,
    /// or the primary display (`displays.first`) when it is `nil` or no display matches — never a
    /// silent failure to the wrong screen.
    private func capture(
        displayID: UInt32?,
        _ transform: (_ full: CGImage, _ scale: CGFloat) -> CGImage?
    ) async -> Result<CapturedImage, CaptureError> {
        do {
            // The shareable-content query is the first thing that fails when Screen Recording
            // permission is missing — it surfaces as SCStreamError.userDeclined.
            let content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: false
            )
            let chosen = displayID.flatMap { id in content.displays.first { $0.displayID == id } }
            guard let display = chosen ?? content.displays.first else {
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
            config.showsCursor = includeCursor()

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
