import AppKit
import ScreenCaptureKit

/// The desktop cover (spec 0013): while a recording runs with Hide desktop icons on, each display
/// shows a picture of its own wallpaper just above Finder's desktop icons and below every app
/// window, so the icons are hidden on screen and — because the recording excepts these panels from
/// leaving Lightshot out — in the take too. Finder windows opened mid-take stay visible, which a
/// filter excluding Finder could not promise.
///
/// A thin OS wrapper (no unit tests). The wallpaper is grabbed at `show()`, so a wallpaper that
/// changes during the take keeps the picture from the start.
@MainActor
final class DesktopCover {
    private var panels: [NSPanel] = []

    /// Cover every display, and hand back the panels' window ids for the recording filter. Already
    /// shown: the same ids. A display whose wallpaper can't be grabbed is left uncovered.
    func show() async -> [CGWindowID] {
        guard panels.isEmpty else { return windowIDs }
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) else {
            return []
        }
        let iconLevel = Int(CGWindowLevelForKey(.desktopIconWindow))
        // Everything under the icons: the wallpaper (and the display's backstop behind it).
        let wallpaper = content.windows.filter { $0.windowLayer < iconLevel }
        let screenNumber = NSDeviceDescriptionKey("NSScreenNumber")
        for display in content.displays {
            guard let screen = NSScreen.screens.first(where: {
                ($0.deviceDescription[screenNumber] as? CGDirectDisplayID) == display.displayID
            }) else { continue }
            let scale = SCCaptureService.backingScale(for: display)
            let config = SCStreamConfiguration()
            config.width = Int((CGFloat(display.width) * scale).rounded())
            config.height = Int((CGFloat(display.height) * scale).rounded())
            config.showsCursor = false
            guard let image = try? await SCScreenshotManager.captureImage(
                contentFilter: SCContentFilter(display: display, including: wallpaper),
                configuration: config
            ) else { continue }
            panels.append(Self.panel(showing: image, over: screen, iconLevel: iconLevel))
        }
        return windowIDs
    }

    func hide() {
        panels.forEach { $0.orderOut(nil) }
        panels = []
    }

    private var windowIDs: [CGWindowID] {
        panels.map { CGWindowID($0.windowNumber) }
    }

    /// One display's cover: borderless, opaque, one level above the icons, on every Space. It
    /// takes clicks on the desktop (so a hidden icon can't be dragged by accident) without ever
    /// activating Lightshot.
    private static func panel(showing image: CGImage, over screen: NSScreen, iconLevel: Int) -> NSPanel {
        let panel = NSPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = NSWindow.Level(rawValue: iconLevel + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        panel.isOpaque = true
        panel.hasShadow = false
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
