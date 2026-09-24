import AppKit
import ScreenCaptureKit
import LightshotKit

/// ScreenCaptureKit-backed `CaptureService` (the OS side of the capture seam).
///
/// A thin wrapper with no unit tests — it needs a real display + TCC state; the coordinator routing
/// it feeds is tested against a fake. Three paths, one seam: fullscreen (LIG-7) captures the whole
/// chosen display; the area path (LIG-13) captures the display under the `.rect` and crops to it;
/// the window path (LIG-14) captures a single `.window` by its id via a window content filter — just
/// that window, its shadow trimmed. macOS 14+ only: uses `SCScreenshotManager`, never the deprecated
/// `CGWindowListCreateImage`.
///
/// Fullscreen honors the chosen display on a multi-monitor setup (LIG-20, story 8): a passed
/// `displayID` selects that `SCDisplay`, and `nil` falls back to the primary display. Regions are in
/// global top-left screen points, since the overlay covers every display (spec 0011): the area path
/// crops the display the rect overlaps most, and the window path scales by the backing scale of the
/// display holding the window. Freeze Screen grabs every display (and, for Capture Window, every
/// candidate window) at the trigger.
final class SCCaptureService: CaptureService {
    /// Whether to draw the cursor into the capture (story 12). A closure, not a stored flag, so it
    /// reads the live `SettingsStore` value at capture time rather than a value frozen at launch.
    private let includeCursor: @Sendable () -> Bool

    init(includeCursor: @escaping @Sendable () -> Bool = { false }) {
        self.includeCursor = includeCursor
    }

    /// Advisory Screen Recording status (see `ScreenRecordingPermission`). The capture call stays
    /// the authority — this only decides whether onboarding prompts.
    func authorizationStatus() async -> CaptureAuthorizationStatus {
        ScreenRecordingPermission.status()
    }

    /// Trigger the one-time system prompt (see `ScreenRecordingPermission.request()`).
    @discardableResult
    func requestAuthorization() async -> CaptureAuthorizationStatus {
        ScreenRecordingPermission.request()
    }

    func captureFullscreen(displayID: UInt32?) async -> Result<CapturedImage, CaptureError> {
        await capture(pick: { displays in displayID.flatMap { id in displays.first { $0.displayID == id } } }) { full, _, _ in full }
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

    /// Freeze Screen (spec 0011): the whole desktop at the trigger. Every display is grabbed at
    /// once, through the same display grab as fullscreen so cursor and permission mapping match;
    /// frames are the displays' global top-left points (`SCDisplay.frame`), the space the overlay
    /// reports regions in. The window picker's candidates come along with their frames; their own
    /// images come from `freezeWindowImages()`, which Capture Window starts at the same moment.
    ///
    /// Lightshot's own windows above the floating level are left out of the stills: a previous
    /// overlay still closing, the post-capture toolbar, the OCR notice, the status menu. Pins
    /// (floating) and editor windows stay in, as they do in a live capture.
    ///
    /// Stills are uncompressed TIFF, not PNG: they only live for one selection, and a 5K PNG
    /// encode plus the backdrop's decode measured ~225 ms before the overlay could appear, against
    /// ~20 ms for TIFF. Whatever is taken from them is encoded as PNG.
    func freezeScreen() async -> Result<FrozenScreen, CaptureError> {
        do {
            let snapshot = try await Self.snapshot()
            let displays = try await Self.grabDisplays(snapshot, showsCursor: includeCursor())
            guard !displays.isEmpty else { return .failure(.noDisplayAvailable) }
            let windows = snapshot.windows.map { FrozenWindow(id: $0.windowID, frame: Rect($0.frame), image: nil) }
            return .success(FrozenScreen(displays: displays, windows: windows))
        } catch {
            return .failure(Self.mapError(error))
        }
    }

    /// Every window-picker candidate grabbed on its own, concurrently, shadow trimmed (spec 0011).
    /// A window whose grab fails is left out, and is captured live if it's picked.
    func freezeWindowImages() async -> [UInt32: CapturedImage] {
        guard let snapshot = try? await Self.snapshot() else { return [:] }
        return await Self.grabWindows(snapshot, showsCursor: includeCursor())
    }

    /// The on-screen desktop a freeze grabs from: every display, our own windows to leave out of
    /// the stills, and the window picker's candidates, front-most first.
    private static func snapshot() async throws -> Snapshot {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let ownProcess = ProcessInfo.processInfo.processIdentifier
        let floating = NSWindow.Level.floating.rawValue
        return Snapshot(
            displays: content.displays,
            excluded: content.windows.filter {
                $0.owningApplication?.processID == ownProcess && $0.windowLayer > floating
            },
            windows: content.windows.filter(isWindowCandidate)
        )
    }

    /// Whether `window` is a window-capture candidate: on screen, a normal app window (not the menu
    /// bar, Dock or desktop), not empty, and not one of ours. Shared by Freeze Screen's candidates
    /// and the live window picker (`OverlaySelectionController`), so the two agree.
    static func isWindowCandidate(_ window: SCWindow) -> Bool {
        window.isOnScreen
            && window.windowLayer == 0
            && window.frame.width >= 1 && window.frame.height >= 1
            && window.owningApplication?.bundleIdentifier != Bundle.main.bundleIdentifier
    }

    /// The shareable-content objects one freeze grabs from, handed to concurrent grabs together.
    /// `@unchecked Sendable`: `SCDisplay` / `SCWindow` aren't marked Sendable, but they are
    /// immutable snapshots of the window server's state that are only read here.
    private struct Snapshot: @unchecked Sendable {
        let displays: [SCDisplay]
        /// Our own windows to leave out of the stills.
        let excluded: [SCWindow]
        /// The window picker's candidates.
        let windows: [SCWindow]
    }

    /// Every display's still, concurrently, in `snapshot.displays` order.
    private static func grabDisplays(_ snapshot: Snapshot, showsCursor: Bool) async throws -> [FrozenDisplay] {
        try await withThrowingTaskGroup(of: (Int, FrozenDisplay?).self) { group in
            for index in snapshot.displays.indices {
                group.addTask {
                    let display = snapshot.displays[index]
                    let still = try await grab(display, excluding: snapshot.excluded, showsCursor: showsCursor)
                    let image = tiffData(from: still).map {
                        CapturedImage(pixelWidth: still.width, pixelHeight: still.height, data: $0)
                    }
                    return (index, image.map { FrozenDisplay(displayID: display.displayID, frame: Rect(display.frame), image: $0) })
                }
            }
            var byIndex: [Int: FrozenDisplay] = [:]
            for try await (index, frozen) in group { byIndex[index] = frozen }
            return snapshot.displays.indices.compactMap { byIndex[$0] }
        }
    }

    /// Each candidate window's own image, concurrently, keyed by window id — missing where a grab
    /// failed.
    private static func grabWindows(_ snapshot: Snapshot, showsCursor: Bool) async -> [UInt32: CapturedImage] {
        await withTaskGroup(of: (UInt32, CapturedImage?).self) { group in
            for index in snapshot.windows.indices {
                group.addTask {
                    let window = snapshot.windows[index]
                    guard let image = try? await grab(window, on: snapshot.displays, showsCursor: showsCursor),
                          let data = tiffData(from: image)
                    else { return (window.windowID, nil) }
                    return (window.windowID, CapturedImage(pixelWidth: image.width, pixelHeight: image.height, data: data))
                }
            }
            var images: [UInt32: CapturedImage] = [:]
            for await (id, image) in group { images[id] = image }
            return images
        }
    }

    /// The live area path (the self-timer case; spec 0011 freezes otherwise): the display the rect
    /// overlaps most, cropped in that display's pixels. The rect is in global top-left points.
    private func captureRect(_ rect: Rect) async -> Result<CapturedImage, CaptureError> {
        let selection = rect.standardized
        let target = CGRect(x: selection.minX, y: selection.minY, width: selection.width, height: selection.height)
        return await capture(pick: { displays in
            displays.max { a, b in
                let x = a.frame.intersection(target), y = b.frame.intersection(target)
                return x.width * x.height < y.width * y.height
            }
        }) { full, scale, displayFrame in
            // The captured image is the display at native pixels, top-left origin — so the crop is
            // the selection relative to the display, scaled to pixels, clamped to the image so an
            // overshoot at the edge can't fail the crop.
            let pixelRect = CGRect(
                x: ((target.minX - displayFrame.minX) * scale).rounded(.down),
                y: ((target.minY - displayFrame.minY) * scale).rounded(.down),
                width: (target.width * scale).rounded(),
                height: (target.height * scale).rounded()
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
            let cgImage = try await Self.grab(window, on: content.displays, showsCursor: includeCursor())
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

    /// One window on its own at native resolution — the backing scale of the display holding its
    /// centre — with its drop shadow trimmed, so it's the window's own content, not its surroundings.
    private static func grab(_ window: SCWindow, on displays: [SCDisplay], showsCursor: Bool) async throws -> CGImage {
        let centre = CGPoint(x: window.frame.midX, y: window.frame.midY)
        let scale = displays.first { $0.frame.contains(centre) }.map(backingScale(for:)) ?? 2
        let config = SCStreamConfiguration()
        config.width = Int((window.frame.width * scale).rounded())
        config.height = Int((window.frame.height * scale).rounded())
        config.showsCursor = showsCursor   // honor the cursor toggle here too (story 12)
        config.ignoreShadowsSingleWindow = true
        return try await SCScreenshotManager.captureImage(
            contentFilter: SCContentFilter(desktopIndependentWindow: window),
            configuration: config
        )
    }

    /// One whole display at native (Retina) resolution: display dimensions are in points, scaled up
    /// by *this* display's backing scale — not the main screen's, which may differ on a
    /// multi-monitor setup or when the captured display isn't the primary one.
    private static func grab(_ display: SCDisplay, excluding: [SCWindow], showsCursor: Bool) async throws -> CGImage {
        let scale = backingScale(for: display)
        let config = SCStreamConfiguration()
        config.width = Int((CGFloat(display.width) * scale).rounded())
        config.height = Int((CGFloat(display.height) * scale).rounded())
        config.showsCursor = showsCursor
        return try await SCScreenshotManager.captureImage(
            contentFilter: SCContentFilter(display: display, excludingWindows: excluding),
            configuration: config
        )
    }

    /// Captures a display's full image, hands it (with the display's backing scale and global
    /// frame) to `transform` to produce the final `CGImage`, then encodes it as PNG — sharing the
    /// shareable-content query, permission mapping, and encoding across the fullscreen and rect paths.
    ///
    /// `pick` chooses the target on a multi-monitor setup (story 8); the primary display
    /// (`displays.first`) stands in when it picks nothing — never a silent failure to no screen.
    private func capture(
        pick: ([SCDisplay]) -> SCDisplay?,
        _ transform: (_ full: CGImage, _ scale: CGFloat, _ displayFrame: CGRect) -> CGImage?
    ) async -> Result<CapturedImage, CaptureError> {
        do {
            // The shareable-content query is the first thing that fails when Screen Recording
            // permission is missing — it surfaces as SCStreamError.userDeclined.
            let content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: false
            )
            guard let display = pick(content.displays) ?? content.displays.first else {
                return .failure(.noDisplayAvailable)
            }
            let fullImage = try await Self.grab(display, excluding: [], showsCursor: includeCursor())
            guard let cgImage = transform(fullImage, Self.backingScale(for: display), display.frame) else {
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
    static func backingScale(for display: SCDisplay) -> CGFloat {
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

    /// Uncompressed TIFF — the frozen still's fast encoding (see `freezeScreen()`).
    private static func tiffData(from cgImage: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.tiff" as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, cgImage, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }
}

private extension Rect {
    /// A Core Graphics rect in global top-left points as the domain's `Rect`.
    init(_ rect: CGRect) {
        self.init(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height)
    }
}
