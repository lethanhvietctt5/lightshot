import AppKit
import SwiftUI
import LightshotKit

/// Pins captures as always-on-top floating windows (stories 46–49, LIG-17).
///
/// Each pin is a borderless `NSWindow` that floats above other apps so the user can reference a shot
/// while working elsewhere. The window is movable (drag its background), resizable (drag its edges,
/// aspect ratio locked to the image), and closable; a hover-revealed action bar plus keyboard
/// shortcuts (⌘C / ⌘S / ⌘W / Esc) copy the shot or dismiss it; saving is on the action bar.
///
/// A thin OS wrapper with no unit tests — it owns only window placement and lifetime. The image it
/// shows is a `RenderedImage` (already flattened by `render`), and copy/save are closures the
/// `AppController` wires straight to the coordinator's `ImageSink` passthrough. So this file knows
/// nothing about rendering or the sink; it just puts pixels on screen and forwards two actions.
@MainActor
final class PinBoardController {
    /// Live pins, retained until each is closed. Multiple captures can be pinned at once.
    private var windows: [PinWindow] = []

    /// Open a new pinned window showing `image`. `copy` and `save` are invoked when the user
    /// triggers those actions from the pin (button or shortcut); `AppController` routes them to the
    /// `ImageSink` passthrough so the pin acts on exactly what it displays.
    func pin(
        _ image: RenderedImage,
        copy: @escaping () -> Void,
        save: @escaping () -> Void
    ) {
        guard let nsImage = NSImage(data: image.data) else { return }
        let size = contentSize(forPixelWidth: image.pixelWidth, pixelHeight: image.pixelHeight)

        let window = PinWindow(
            contentRect: NSRect(origin: .zero, size: size),
            // `.resizable` on a borderless window keeps edge-drag resizing without any title bar.
            styleMask: [.borderless, .resizable],
            backing: .buffered,
            defer: false
        )
        window.level = .floating
        window.isReleasedWhenClosed = false
        window.isMovableByWindowBackground = true
        window.hasShadow = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.aspectRatio = size          // keep the shot undistorted while resizing
        window.minSize = NSSize(width: 80, height: 80)
        window.onCopy = copy

        let close: () -> Void = { [weak self, weak window] in
            guard let window else { return }
            self?.close(window)
        }
        window.onClose = close
        window.contentView = NSHostingView(rootView: PinBoardView(
            image: nsImage, copy: copy, save: save, close: close
        ))

        place(window, size: size)
        windows.append(window)

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func close(_ window: PinWindow) {
        window.orderOut(nil)
        windows.removeAll { $0 === window }
    }

    /// Logical (point) size for the pin: the native pixel size scaled down by the screen's backing
    /// factor so a Retina capture pins at its on-screen size, then capped to fit comfortably on
    /// screen — preserving aspect ratio — so a fullscreen shot doesn't open larger than the display.
    private func contentSize(forPixelWidth width: Int, pixelHeight height: Int) -> NSSize {
        let screen = NSScreen.main ?? NSScreen.screens.first
        let scale = screen?.backingScaleFactor ?? 2
        var size = NSSize(width: CGFloat(width) / scale, height: CGFloat(height) / scale)

        if let visible = screen?.visibleFrame {
            let factor = min(1, min(visible.width * 0.9 / size.width, visible.height * 0.9 / size.height))
            size = NSSize(width: size.width * factor, height: size.height * factor)
        }
        return size
    }

    /// Centers the pin, cascading each new one down-right so stacked pins stay distinguishable.
    private func place(_ window: NSWindow, size: NSSize) {
        window.setContentSize(size)
        window.center()
        let offset = CGFloat(windows.count) * 24
        var origin = window.frame.origin
        origin.x += offset
        origin.y -= offset
        window.setFrameOrigin(origin)
    }
}

/// A borderless window that can still become key — so it receives keyboard shortcuts — and maps
/// ⌘C / ⌘S / ⌘W / Escape to the pin's copy and close actions — ⌘S copies, as it does in the editor
/// (LIG-23); the pin stays up. Mirrors `OverlayKeyWindow`'s
/// approach of routing keys in the window rather than relying on SwiftUI focus for a chrome-less
/// surface.
final class PinWindow: NSWindow {
    var onCopy: (() -> Void)?
    var onClose: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onClose?(); return }  // Escape
        guard event.modifierFlags.contains(.command),
              let key = event.charactersIgnoringModifiers else {
            super.keyDown(with: event)
            return
        }
        switch key {
        case "w": onClose?()
        case "c", "s": onCopy?()
        default: super.keyDown(with: event)
        }
    }
}

/// The pinned image plus a hover-revealed action bar (copy / save / close). The image fills the
/// window; because the window's aspect ratio is locked to the image, filling never distorts it.
private struct PinBoardView: View {
    let image: NSImage
    let copy: () -> Void
    let save: () -> Void
    let close: () -> Void

    @State private var hovering = false

    var body: some View {
        Image(nsImage: image)
            .resizable()
            .overlay(alignment: .top) {
                if hovering { actionBar }
            }
            .onHover { hovering = $0 }
    }

    private var actionBar: some View {
        HStack(spacing: 4) {
            button("Copy", systemImage: "doc.on.doc", action: copy)
            button("Save", systemImage: "square.and.arrow.down", action: save)
            button("Close", systemImage: "xmark", action: close)
        }
        .padding(5)
        .background(.regularMaterial, in: Capsule())
        .padding(8)
    }

    private func button(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .labelStyle(.iconOnly)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 24, height: 20)
        }
        .buttonStyle(.plain)
        .help(title)
    }
}
