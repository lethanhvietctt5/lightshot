import AppKit
import SwiftUI
import LightshotKit

/// Dims everything outside the recording area while recording (spec 0006, story 16), so the user
/// sees what is in and out of frame. A transparent full-screen window that ignores the mouse, just
/// below the controls pill; Lightshot's own window, so the content filter keeps it out of the file.
/// A whole-display take has nothing outside the frame, so no dimming is shown.
@MainActor
final class RecordingDimController {
    private var window: NSWindow?

    func show(outside region: CaptureRegion) {
        let frame: Rect
        switch region {
        case let .rect(rect): frame = rect
        case let .window(_, windowFrame): frame = windowFrame
        case .display: hide(); return
        }
        guard window == nil else { return }

        let screen = NSScreen.main ?? NSScreen.screens.first
        let screenFrame = screen?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let window = OverlayKeyWindow.fullScreen(frame: screenFrame)
        window.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue - 1)
        window.ignoresMouseEvents = true
        window.contentView = NSHostingView(rootView: RecordingDimView(hole: frame.standardized.cgRect))
        window.setFrame(screenFrame, display: true)
        self.window = window
        window.orderFrontRegardless()
    }

    func hide() {
        window?.orderOut(nil)
        window = nil
    }
}

private struct RecordingDimView: View {
    let hole: CGRect

    var body: some View {
        Canvas { context, size in
            OverlayCanvas.dim(&context, size: size, punchingOut: hole)
        }
        .ignoresSafeArea()
    }
}
