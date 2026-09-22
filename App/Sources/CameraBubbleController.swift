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

    init(feed: CameraFeed) {
        self.feed = feed
    }

    /// Show (or re-target) the bubble over `region` for `deviceID`. A failure to open the camera
    /// leaves nothing on screen; the take then records without a bubble.
    func show(deviceID: String?, region: Rect, settings: CameraBubbleSettings) {
        self.region = region
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
        panel?.orderFrontRegardless()
    }

    /// The selection moved or resized while the toolbar is up.
    func move(to region: Rect) {
        self.region = region
        layout()
    }

    func hide() {
        panel?.orderOut(nil)
        panel = nil
        bubbleView = nil
        region = nil
        feed.stop()
    }

    var isShowing: Bool { panel != nil }

    // MARK: - Layout

    private func layout() {
        guard let panel, let region, let bubbleView else { return }
        let (settings, fullscreen) = feed.snapshot()
        let regionSize = Size(width: region.width, height: region.height)
        let local = fullscreen
            ? Rect(x: 0, y: 0, width: region.width, height: region.height)
            : CameraBubbleLayout.frame(settings, in: regionSize)
        let onScreen = Rect(x: region.minX + local.minX, y: region.minY + local.minY, width: local.width, height: local.height)
        panel.setFrame(Self.appKitRect(onScreen), display: true)
        bubbleView.cornerRadius = fullscreen ? 0 : CameraBubbleLayout.cornerRadius(for: settings.shape, side: local.width)
        bubbleView.mirrored = settings.mirror
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

    private var preview: AVCaptureVideoPreviewLayer?
    private var pressOrigin: NSPoint?
    private var moved = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor.black.cgColor
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
