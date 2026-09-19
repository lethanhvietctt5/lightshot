import AppKit
import SwiftUI
import LightshotKit

/// The concrete `OverlayController`: a full-screen dimmed `NSWindow` that resolves the user's
/// drag into a `CaptureRegion` (or `nil` on Escape). The pre-capture step — it never captures.
///
/// A thin OS wrapper (no unit tests; the coordinator's overlay → capture ordering is tested against
/// a fake). `selectRegion()` bridges the window's imperative lifecycle to `async` via a checked
/// continuation, resumed exactly once when the user confirms or cancels. v1 covers the main screen;
/// per-display selection is a follow-up.
@MainActor
final class OverlaySelectionController: OverlayController {
    private var window: OverlayKeyWindow?
    private var continuation: CheckedContinuation<CaptureRegion?, Never>?

    func selectRegion() async -> CaptureRegion? {
        // Guard against an overlapping presentation resolving the previous one to nil.
        if let stale = continuation {
            continuation = nil
            stale.resume(returning: nil)
        }
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            present()
        }
    }

    private func present() {
        let screen = NSScreen.main ?? NSScreen.screens.first
        let frame = screen?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let scale = Double(screen?.backingScaleFactor ?? 2)

        let model = SelectionOverlayModel(pixelScale: scale) { [weak self] region in
            self?.finish(with: region)
        }

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
        window.onConfirm = { model.confirm() }
        window.onCancel = { model.cancel() }
        window.contentView = NSHostingView(rootView: SelectionOverlayView(model: model))
        window.setFrame(frame, display: true)
        self.window = window

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
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
