import AppKit
import SwiftUI
import LightshotKit

/// Marks the recording area while recording (spec 0006, story 16; LIG-65): a red border just
/// outside it, pulsing while recording and steady while paused, and — per Settings — everything
/// outside it dimmed. A transparent full-screen window that ignores the mouse, just below the
/// controls pill; Lightshot's own window, so the content filter keeps it out of the file.
/// A whole-display take has nothing outside the frame, so it gets the border along the display's
/// edges and no dimming.
/// Content, not chrome (spec 0008): the same colours in Light and Dark, since it is read against the screen.
@MainActor
final class RecordingFrameController {
    private var window: NSWindow?
    private var shown: (region: CaptureRegion, dims: Bool)?
    private var border: CAShapeLayer?

    private static let borderWidth: CGFloat = 3
    private static let pulseKey = "pulse"

    func show(around region: CaptureRegion, dimsOutside: Bool, isPaused: Bool) {
        if shown?.region != region || shown?.dims != dimsOutside {
            hide()
            present(around: region, dimsOutside: dimsOutside)
        }
        setPulsing(!isPaused)
    }

    func hide() {
        window?.orderOut(nil)
        window = nil
        border = nil
        shown = nil
    }

    private func present(around region: CaptureRegion, dimsOutside: Bool) {
        let screen: NSScreen?
        let hole: CGRect?
        switch region {
        case let .rect(rect):
            screen = NSScreen.main ?? NSScreen.screens.first
            hole = rect.standardized.cgRect
        case let .window(_, windowFrame):
            screen = NSScreen.main ?? NSScreen.screens.first
            hole = windowFrame.standardized.cgRect
        case let .display(id):
            let key = NSDeviceDescriptionKey("NSScreenNumber")
            screen = NSScreen.screens.first { ($0.deviceDescription[key] as? CGDirectDisplayID) == id }
                ?? NSScreen.main ?? NSScreen.screens.first
            hole = nil
        }
        let screenFrame = screen?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let bounds = CGRect(origin: .zero, size: screenFrame.size)

        let window = OverlayKeyWindow.fullScreen(frame: screenFrame)
        window.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue - 1)
        window.ignoresMouseEvents = true

        let content = NSView(frame: bounds)
        content.wantsLayer = true
        if dimsOutside, let hole {
            let dim = NSHostingView(rootView: RecordingDimView(hole: hole))
            dim.frame = bounds
            dim.autoresizingMask = [.width, .height]
            content.addSubview(dim)
        }

        // The border's inner edge touches the recorded area, so it never covers what is recorded;
        // where that would run off the screen (an area against a display edge, or a whole display)
        // it is pulled back on screen.
        let half = Self.borderWidth / 2
        let outline = (hole ?? bounds).insetBy(dx: -half, dy: -half).intersection(bounds.insetBy(dx: half, dy: half))
        // The region is top-left origin; the layer is bottom-left.
        let flipped = CGRect(x: outline.minX, y: bounds.height - outline.maxY, width: outline.width, height: outline.height)
        let border = CAShapeLayer()
        border.frame = bounds
        border.path = CGPath(rect: flipped, transform: nil)
        border.fillColor = nil
        border.strokeColor = NSColor.systemRed.cgColor
        border.lineWidth = Self.borderWidth
        // Its own view above the dimming: AppKit orders subviews' layers over a bare sublayer.
        let borderView = NSView(frame: bounds)
        borderView.wantsLayer = true
        borderView.autoresizingMask = [.width, .height]
        borderView.layer?.addSublayer(border)
        content.addSubview(borderView)

        window.contentView = content
        window.setFrame(screenFrame, display: true)
        self.window = window
        self.border = border
        shown = (region, dimsOutside)
        window.orderFrontRegardless()
    }

    /// Recording pulses (the "live" signal); paused holds the border steady.
    private func setPulsing(_ pulsing: Bool) {
        guard let border else { return }
        let isPulsing = border.animation(forKey: Self.pulseKey) != nil
        guard pulsing != isPulsing else { return }
        if pulsing {
            let pulse = CABasicAnimation(keyPath: "opacity")
            pulse.fromValue = 1
            pulse.toValue = 0.3
            pulse.duration = 1
            pulse.autoreverses = true
            pulse.repeatCount = .infinity
            pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            border.add(pulse, forKey: Self.pulseKey)
        } else {
            border.removeAnimation(forKey: Self.pulseKey)
        }
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
