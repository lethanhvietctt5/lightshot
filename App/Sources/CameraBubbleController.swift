import AppKit
import AVFoundation
import LightshotKit

/// The on-screen camera bubble (spec 0006, stories 26–28): a floating panel over the recording
/// region showing the live preview, before and during the take. It is only a preview — the output
/// gets the bubble from the compositor, laid out by the same `CameraBubbleLayout` in the same
/// region points — and, being one of Lightshot's windows, it is excluded from the stream by process.
/// Drag moves it (the anchor is persisted through `onAnchorChanged`); a click toggles fullscreen.
@MainActor
final class CameraBubbleController {
    let feed: CameraFeed
    /// Told when a drag ends, with the anchor to remember (story 27).
    var onAnchorChanged: ((Point) -> Void)?

    private var panel: NSPanel?
    private var bubbleView: CameraBubbleView?
    /// The recording region in top-left screen points.
    private var region: Rect?
    /// The settings as last shown, with the anchor the user dragged to — so a re-show in the same
    /// session (a re-selected region, a switched device) keeps the position (story 27).
    private var liveSettings: CameraBubbleSettings?
    /// Whether the take is running (countdown or recording). While the toolbar is still up a
    /// fullscreen bubble would cover the toolbar and the handles, so it stays bubble-sized with a
    /// badge until the take starts; the compositor and the preview then both go fullscreen.
    private var isLive = false

    init(feed: CameraFeed) {
        self.feed = feed
    }

    /// Show (or re-target) the bubble over `region` for `deviceID`. A failure to open the camera
    /// leaves nothing on screen; the take then records without a bubble.
    func show(deviceID: String?, region: Rect, settings: CameraBubbleSettings) {
        self.region = region
        var settings = settings
        settings.anchor = liveSettings?.anchor ?? settings.anchor
        liveSettings = settings
        let capture: CameraCapture
        do {
            capture = try feed.start(deviceID: deviceID, settings: settings)
        } catch {
            hide()
            return
        }
        if panel == nil { makePanel() }
        bubbleView?.attach(capture.previewLayer)
        layout()
        if panel?.isVisible != true { panel?.orderFrontRegardless() }
    }

    /// Nothing selected right now: take the bubble off screen but keep the camera running, so a
    /// re-selection a moment later does not restart it (no LED flicker, no warm-up).
    func conceal() {
        panel?.orderOut(nil)
        region = nil
    }

    /// Gone for good: the take ended, the camera was switched off, or the overlay was cancelled.
    func hide() {
        guard panel != nil || feed.isRunning else { return }
        panel?.orderOut(nil)
        panel = nil
        bubbleView = nil
        region = nil
        liveSettings = nil
        isLive = false
        feed.stop()
    }

    /// The take started (countdown or recording): fullscreen now covers the region for real.
    func setLive(_ live: Bool) {
        guard live != isLive else { return }
        isLive = live
        layout()
    }

    // MARK: - Layout

    private func layout() {
        guard let panel, let region, let bubbleView else { return }
        let (settings, fullscreen) = feed.snapshot()
        let regionSize = Size(width: region.width, height: region.height)
        let covers = fullscreen && isLive
        let local = CameraBubbleLayout.frame(settings, in: regionSize, fullscreen: covers)
        let onScreen = Rect(x: region.minX + local.minX, y: region.minY + local.minY, width: local.width, height: local.height)
        let frame = Self.appKitRect(onScreen)
        if panel.frame != frame { panel.setFrame(frame, display: true) }
        bubbleView.cornerRadius = CameraBubbleLayout.cornerRadius(for: settings.shape, side: local.width, fullscreen: covers)
        bubbleView.mirrored = settings.mirror
        bubbleView.showsFullscreenBadge = fullscreen && !isLive
    }

    private func makePanel() {
        let view = CameraBubbleView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        view.onDragEnded = { [weak self] in self?.dragEnded() }
        view.onDragged = { [weak self] delta in self?.dragged(by: delta) }
        view.onClicked = { [weak self] in
            self?.feed.toggleFullscreen()
            self?.layout()
        }
        let panel = NSPanel(
            contentRect: view.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false
        )
        panel.isFloatingPanel = true
        // Above the selection overlay (screen-saver level) so it can be dragged while the toolbar is up.
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.contentView = view
        self.panel = panel
        bubbleView = view
    }

    private func dragged(by delta: CGVector) {
        guard let panel, !feed.snapshot().isFullscreen else { return }
        var frame = panel.frame
        frame.origin.x += delta.dx
        frame.origin.y += delta.dy
        panel.setFrameOrigin(frame.origin)
    }

    /// The panel's centre becomes the anchor; `layout()` then clamps it inside the region.
    private func dragEnded() {
        guard let panel, let region, !feed.snapshot().isFullscreen else { return }
        let center = Self.topLeftPoint(NSPoint(x: panel.frame.midX, y: panel.frame.midY))
        let local = Point(x: center.x - region.minX, y: center.y - region.minY)
        let anchor = CameraBubbleLayout.anchor(forCenter: local, in: Size(width: region.width, height: region.height))
        feed.update { $0.anchor = anchor }
        liveSettings?.anchor = anchor
        onAnchorChanged?(anchor)
        layout()
    }

    // MARK: - Coordinates

    /// Top-left screen points → AppKit's bottom-left global frame (the primary display's height,
    /// as `MouseEventMonitor` uses).
    private static func appKitRect(_ rect: Rect) -> NSRect {
        let height = NSScreen.screens.first?.frame.height ?? 0
        return NSRect(x: rect.minX, y: height - rect.maxY, width: rect.width, height: rect.height)
    }

    private static func topLeftPoint(_ point: NSPoint) -> Point {
        let height = NSScreen.screens.first?.frame.height ?? 0
        return Point(x: point.x, y: height - point.y)
    }
}

/// The bubble's content: the preview layer, masked to the shape, mirrored if asked; reports drags
/// and clicks (a press that moved under 3 pt is a click).
final class CameraBubbleView: NSView {
    var onDragged: ((CGVector) -> Void)?
    var onDragEnded: (() -> Void)?
    var onClicked: (() -> Void)?

    var cornerRadius: Double = 0 { didSet { layer?.cornerRadius = cornerRadius } }
    var mirrored = true { didSet { applyMirror() } }
    /// Fullscreen was chosen while the toolbar is still up: say so instead of covering it.
    var showsFullscreenBadge = false { didSet { badge.isHidden = !showsFullscreenBadge } }

    private var preview: AVCaptureVideoPreviewLayer?
    private let badge = CATextLayer()
    private var pressOrigin: NSPoint?
    private var moved = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor.black.cgColor
        badge.string = "Fullscreen when recording"
        badge.fontSize = 11
        badge.alignmentMode = .center
        badge.foregroundColor = NSColor.white.cgColor
        badge.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
        badge.contentsScale = 2
        badge.isHidden = true
        layer?.addSublayer(badge)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func attach(_ layer: AVCaptureVideoPreviewLayer) {
        guard preview !== layer else { return }
        preview?.removeFromSuperlayer()
        preview = layer
        layer.frame = bounds
        layer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        self.layer?.addSublayer(layer)
        applyMirror()
    }

    override func layout() {
        super.layout()
        preview?.frame = bounds
        badge.frame = CGRect(x: 0, y: 0, width: bounds.width, height: 18)
        badge.zPosition = 1
    }

    private func applyMirror() {
        guard let connection = preview?.connection else { return }
        connection.automaticallyAdjustsVideoMirroring = false
        connection.isVideoMirrored = mirrored
    }

    override func mouseDown(with event: NSEvent) {
        pressOrigin = NSEvent.mouseLocation
        moved = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let pressOrigin else { return }
        let now = NSEvent.mouseLocation
        let delta = CGVector(dx: now.x - pressOrigin.x, dy: now.y - pressOrigin.y)
        if abs(delta.dx) + abs(delta.dy) >= 3 { moved = true }
        if moved {
            onDragged?(delta)
            self.pressOrigin = now
        }
    }

    override func mouseUp(with event: NSEvent) {
        defer { pressOrigin = nil }
        if moved { onDragEnded?() } else { onClicked?() }
    }
}
