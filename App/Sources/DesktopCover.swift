import AppKit
import OSLog
import ScreenCaptureKit

private let log = Logger(subsystem: "dev.lightshot.app", category: "recording")

/// The desktop cover (spec 0013): while a recording runs with Hide desktop icons on, each display
/// shows a picture of its own wallpaper just above Finder's desktop icons and below every app
/// window, so the icons are hidden on screen and — because the recording excepts these panels from
/// leaving Lightshot out — in the take too. Finder windows opened mid-take stay visible, which a
/// filter excluding Finder could not promise.
///
/// A thin OS wrapper (no unit tests). The wallpaper is grabbed at `show()`, so a wallpaper that
/// changes during the take keeps the picture from the start. Clicks pass through to the desktop,
/// so its menus and widgets keep working while the icons are hidden.
@MainActor
final class DesktopCover {
    private var panels: [NSPanel] = []
    /// Bumped by every `hide()`, so a `show()` still grabbing wallpapers when the take ends puts
    /// nothing up afterwards.
    private var generation = 0

    /// Cover every display, and hand back the panels' window ids for the recording filter. Already
    /// shown: the same ids. A display whose wallpaper can't be grabbed is left uncovered (logged),
    /// and the take goes ahead.
    func show() async -> [CGWindowID] {
        guard panels.isEmpty else { return windowIDs }
        let started = generation
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            log.error("Desktop cover unavailable, icons stay visible: \(error.localizedDescription, privacy: .public)")
            return []
        }
        // Everything under the icons: the wallpaper (and the display's backstop behind it).
        let wallpaper = content.windows.filter { $0.windowLayer < SCCaptureService.desktopIconLevel }
        let screenNumber = NSDeviceDescriptionKey("NSScreenNumber")
        for display in content.displays {
            guard let screen = NSScreen.screens.first(where: {
                ($0.deviceDescription[screenNumber] as? CGDirectDisplayID) == display.displayID
            }) else {
                log.error("Desktop cover: no screen for display \(display.displayID), its icons stay visible")
                continue
            }
            let image: CGImage
            do {
                image = try await SCScreenshotManager.captureImage(
                    contentFilter: SCContentFilter(display: display, including: wallpaper),
                    configuration: SCCaptureService.configuration(for: display, showsCursor: false)
                )
            } catch {
                log.error("Desktop cover: wallpaper of display \(display.displayID) unavailable, its icons stay visible: \(error.localizedDescription, privacy: .public)")
                continue
            }
            // The take ended while this grab was in flight: put nothing up.
            guard generation == started else { return [] }
            panels.append(Self.panel(showing: image, over: screen))
        }
        return windowIDs
    }

    func hide() {
        generation += 1
        panels.forEach { $0.orderOut(nil) }
        panels = []
    }

    private var windowIDs: [CGWindowID] {
        panels.map { CGWindowID($0.windowNumber) }
    }

    /// One display's cover: borderless, opaque, one level above the icons, on every Space, and
    /// transparent to the mouse.
    private static func panel(showing image: CGImage, over screen: NSScreen) -> NSPanel {
        let panel = NSPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = NSWindow.Level(rawValue: SCCaptureService.desktopIconLevel + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        panel.isOpaque = true
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.backgroundColor = .black
        let view = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        view.wantsLayer = true
        view.layer?.contents = image
        view.layer?.contentsGravity = .resize
        panel.contentView = view
        panel.setFrame(screen.frame, display: false)
        panel.orderFrontRegardless()
        return panel
    }
}
