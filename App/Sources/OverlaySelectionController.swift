import AppKit
import ScreenCaptureKit
import SwiftUI
import LightshotKit

/// The concrete `OverlayController`: a full-screen dimmed `NSWindow` that resolves the user's
/// choice into a `CaptureRegion` (or `nil` on Escape). The pre-capture step — it never captures.
///
/// A thin OS wrapper (no unit tests; the coordinator's overlay → capture ordering is tested against
/// a fake). Both entry points bridge the window's imperative lifecycle to `async` via a checked
/// continuation, resumed exactly once when the user confirms or cancels: `selectRegion()` drags a
/// rect (LIG-13), `selectWindow()` hover-highlights and clicks a window (LIG-14). v1 covers the main
/// screen; per-display selection is a follow-up.
@MainActor
final class OverlaySelectionController: OverlayController {
    private var window: OverlayKeyWindow?
    private var continuation: CheckedContinuation<CaptureRegion?, Never>?

    func selectRegion() async -> CaptureRegion? {
        resolveStaleContinuation()
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            presentRectOverlay()
        }
    }

    func selectWindow() async -> CaptureRegion? {
        resolveStaleContinuation()
        // Enumerate the on-screen windows *before* the overlay appears, so our own full-screen
        // overlay is never among the hover candidates or the window that gets captured.
        let windows = await Self.hoverableWindows()
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            presentWindowOverlay(windows: windows)
        }
    }

    /// Guard against an overlapping presentation leaving a stale continuation: resolve the previous
    /// one to `nil` (a silent no-op) before installing a new one.
    private func resolveStaleContinuation() {
        if let stale = continuation {
            continuation = nil
            stale.resume(returning: nil)
        }
    }

    private func presentRectOverlay() {
        let screen = NSScreen.main ?? NSScreen.screens.first
        let frame = screen?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let scale = Double(screen?.backingScaleFactor ?? 2)

        let model = SelectionOverlayModel(pixelScale: scale) { [weak self] region in
            self?.finish(with: region)
        }

        let window = makeOverlayWindow(frame: frame)
        window.onConfirm = { model.confirm() }
        window.onCancel = { model.cancel() }
        window.contentView = NSHostingView(rootView: SelectionOverlayView(model: model))
        present(window, at: frame)
    }

    private func presentWindowOverlay(windows: [WindowHoverOverlayModel.HoverWindow]) {
        let screen = NSScreen.main ?? NSScreen.screens.first
        let frame = screen?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)

        let model = WindowHoverOverlayModel(windows: windows) { [weak self] region in
            self?.finish(with: region)
        }

        let window = makeOverlayWindow(frame: frame)
        window.onConfirm = { model.confirmHovered() }
        window.onCancel = { model.cancel() }
        window.contentView = NSHostingView(rootView: WindowHoverOverlayView(model: model))
        present(window, at: frame)
    }

    /// The shared borderless, screen-saver-level, transparent full-screen window both modes present
    /// in — only its content view and key handlers differ.
    private func makeOverlayWindow(frame: NSRect) -> OverlayKeyWindow {
        let window = OverlayKeyWindow(
            contentRect: frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.level = .screenSaver
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        return window
    }

    private func present(_ window: OverlayKeyWindow, at frame: NSRect) {
        window.setFrame(frame, display: true)
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// The capture candidates for window mode: on-screen, normal-layer windows other than our own,
    /// front-most first. `SCWindow.frame` is top-left-origin screen points — the same space the
    /// overlay draws in — so it becomes a `HoverWindow` frame directly, no conversion. A failed
    /// shareable-content query (e.g. permission not yet granted) yields an empty list; the overlay
    /// still opens and Escape/click-through resolve to a no-op, and the capture step then surfaces
    /// the real permission error.
    private static func hoverableWindows() async -> [WindowHoverOverlayModel.HoverWindow] {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: true
        ) else { return [] }

        let ownBundleID = Bundle.main.bundleIdentifier
        return content.windows
            .filter { window in
                window.isOnScreen
                    && window.windowLayer == 0            // normal app windows, not menu bar/dock/desktop
                    && window.frame.width >= 1 && window.frame.height >= 1
                    && window.owningApplication?.bundleIdentifier != ownBundleID
            }
            .map { window in
                WindowHoverOverlayModel.HoverWindow(
                    id: window.windowID,
                    frame: Rect(
                        x: window.frame.minX,
                        y: window.frame.minY,
                        width: window.frame.width,
                        height: window.frame.height
                    )
                )
            }
    }

    private func finish(with region: CaptureRegion?) {
        guard let continuation else { return }  // ignore a second resolution (e.g. key after click)
        self.continuation = nil
        window?.orderOut(nil)
        window = nil
        continuation.resume(returning: region)
    }
}

/// A borderless window that can still become key — so it receives Escape/Return — and routes those
/// keys to the overlay instead of relying on SwiftUI focus, which is unreliable for a transient
/// full-screen surface.
final class OverlayKeyWindow: NSWindow {
    var onConfirm: (() -> Void)?
    var onCancel: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: onCancel?()           // Escape
        case 36, 76: onConfirm?()      // Return / keypad Enter
        default: super.keyDown(with: event)
        }
    }
}
