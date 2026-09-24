import AppKit
import ScreenCaptureKit
import SwiftUI
import LightshotKit

/// The concrete `OverlayController`: full-screen dimmed `NSWindow`s that resolve the user's choice
/// into a `CaptureRegion` (or `nil` on Escape). The pre-capture step — it never captures.
///
/// A thin OS wrapper (no unit tests; the coordinator's overlay → capture ordering is tested against
/// a fake). Every entry point bridges the window's imperative lifecycle to `async` via a checked
/// continuation, resumed exactly once when the user confirms or cancels: `selectRegion(over:)` drags
/// a rect (LIG-13), `selectWindow(over:)` hover-highlights and clicks a window (LIG-14),
/// `selectRecording(initial:defaults:)` runs the editable recording selection with the recorder
/// toolbar (spec 0006). The two screenshot modes put one overlay window on every display (spec 0011)
/// and resolve regions in global top-left screen points; the recording overlay stays on the main
/// screen.
@MainActor
final class OverlaySelectionController: OverlayController {
    /// The recorder toolbar's settings shortcut: cancels the overlay and opens Settings.
    private let openSettings: () -> Void
    /// The recorder toolbar's lazy permission gate: whether a toggle may switch on (story 41).
    private let permissionGate: (RecordingToggle) async -> Bool
    /// A toggle's standing grant, for the toolbar's warning badges (LIG-42).
    private let permissionStatus: (RecordingToggle) async -> CaptureAuthorizationStatus
    /// The microphones the toolbar's device menu lists (story 20).
    private let audioInputs: () async -> [AudioInputDevice]
    /// The cameras the toolbar's device menu lists (story 27), and the preview bubble it shows.
    private let cameras: () async -> [CameraDevice]
    private let cameraBubble: CameraBubbleController?
    /// The overlay windows up now — one per display for the screenshot modes, one for recording.
    private var windows: [OverlayKeyWindow] = []

    init(
        openSettings: @escaping () -> Void = {},
        permissionGate: @escaping (RecordingToggle) async -> Bool = { _ in true },
        permissionStatus: @escaping (RecordingToggle) async -> CaptureAuthorizationStatus = { _ in .authorized },
        audioInputs: @escaping () async -> [AudioInputDevice] = { [] },
        cameras: @escaping () async -> [CameraDevice] = { [] },
        cameraBubble: CameraBubbleController? = nil
    ) {
        self.openSettings = openSettings
        self.permissionGate = permissionGate
        self.permissionStatus = permissionStatus
        self.audioInputs = audioInputs
        self.cameras = cameras
        self.cameraBubble = cameraBubble
    }
    private var continuation: CheckedContinuation<CaptureRegion?, Never>?
    private var recordingContinuation: CheckedContinuation<RecordingChoice?, Never>?

    func selectRegion(over frozen: FrozenScreen?) async -> CaptureRegion? {
        resolveStaleContinuation()
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            presentRectOverlay(over: frozen)
        }
    }

    func selectWindow(over frozen: FrozenScreen?) async -> CaptureRegion? {
        resolveStaleContinuation()
        // The candidates are the windows as they were at the freeze, so the highlights line up with
        // the stills (spec 0011). Without a freeze, enumerate the on-screen windows *before* the
        // overlay appears, so our own full-screen overlay is never among the hover candidates.
        let windows = if let frozen {
            frozen.windows.map { WindowHoverOverlayModel.HoverWindow(id: $0.id, frame: $0.frame) }
        } else {
            await Self.hoverableWindows()
        }
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            presentWindowOverlay(windows: windows, over: frozen)
        }
    }

    func selectRecording(initial: CaptureRegion?, defaults: RecordingDefaults) async -> RecordingChoice? {
        resolveStaleContinuation()
        let windows = await Self.hoverableWindows()
        let inputs = await audioInputs()
        let cameras = await cameras()
        return await withCheckedContinuation { continuation in
            self.recordingContinuation = continuation
            presentRecordingOverlay(windows: windows, initial: initial, defaults: defaults, audioInputs: inputs, cameras: cameras)
        }
    }

    /// Guard against an overlapping presentation leaving a stale continuation: resolve the previous
    /// one to `nil` (a silent no-op) before installing a new one.
    private func resolveStaleContinuation() {
        if let stale = continuation {
            continuation = nil
            stale.resume(returning: nil)
        }
        if let stale = recordingContinuation {
            recordingContinuation = nil
            cameraBubble?.hide()
            stale.resume(returning: nil)
        }
    }

    /// The main screen the recording overlay covers: its frame, backing scale and display id.
    private struct ScreenGeometry {
        let frame: NSRect
        let scale: Double
        let displayID: UInt32
    }

    private static func mainScreen() -> ScreenGeometry {
        let screen = NSScreen.main ?? NSScreen.screens.first
        let number = screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        return ScreenGeometry(
            frame: screen?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900),
            scale: Double(screen?.backingScaleFactor ?? 2),
            displayID: UInt32(number ?? CGMainDisplayID())
        )
    }

    /// One display an overlay window covers: its AppKit frame (to place the window), its bounds in
    /// global top-left screen points (the space regions and frozen frames use), its backing scale
    /// and display id.
    private struct OverlayScreen {
        let frame: NSRect
        let bounds: Rect
        let scale: Double
        let displayID: UInt32
    }

    private static func overlayScreens() -> [OverlayScreen] {
        NSScreen.screens.compactMap { screen in
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else {
                return nil
            }
            let bounds = CGDisplayBounds(id)
            return OverlayScreen(
                frame: screen.frame,
                bounds: Rect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: bounds.height),
                scale: Double(screen.backingScaleFactor),
                displayID: UInt32(id)
            )
        }
    }

    /// The drag overlay on every display (spec 0011). Each window's model works in its own screen's
    /// points; the region it resolves is shifted into global points before it's reported.
    private func presentRectOverlay(over frozen: FrozenScreen?) {
        let overlays = Self.overlayScreens().map { screen in
            let origin = screen.bounds.origin
            let model = SelectionOverlayModel(pixelScale: screen.scale) { [weak self] region in
                guard case let .rect(local)? = region else { self?.finish(with: nil); return }
                self?.finish(with: .rect(Rect(
                    x: local.minX + origin.x, y: local.minY + origin.y, width: local.width, height: local.height
                )))
            }
            let window = makeOverlayWindow(frame: screen.frame)
            window.onConfirm = { model.confirm() }
            window.onCancel = { model.cancel() }
            window.contentView = Self.content(
                NSHostingView(rootView: SelectionOverlayView(model: model)),
                over: frozen?.displays.first { $0.displayID == screen.displayID },
                size: screen.frame.size
            )
            return (window, screen.frame)
        }
        present(overlays)
    }

    /// The window picker on every display (spec 0011). Each model gets the candidates in its own
    /// screen's points; a pick is reported with the window's global frame.
    private func presentWindowOverlay(windows: [WindowHoverOverlayModel.HoverWindow], over frozen: FrozenScreen?) {
        let globalFrames = Dictionary(windows.map { ($0.id, $0.frame) }, uniquingKeysWith: { first, _ in first })
        let overlays = Self.overlayScreens().map { screen in
            let origin = screen.bounds.origin
            let local = windows.map { window in
                WindowHoverOverlayModel.HoverWindow(id: window.id, frame: Rect(
                    x: window.frame.minX - origin.x, y: window.frame.minY - origin.y,
                    width: window.frame.width, height: window.frame.height
                ))
            }
            let model = WindowHoverOverlayModel(windows: local) { [weak self] region in
                guard case let .window(id, _)? = region, let frame = globalFrames[id] else {
                    self?.finish(with: nil)
                    return
                }
                self?.finish(with: .window(id: id, frame: frame))
            }
            let window = makeOverlayWindow(frame: screen.frame)
            window.onConfirm = { model.confirmHovered() }
            window.onCancel = { model.cancel() }
            window.contentView = Self.content(
                NSHostingView(rootView: WindowHoverOverlayView(model: model)),
                over: frozen?.displays.first { $0.displayID == screen.displayID },
                size: screen.frame.size
            )
            return (window, screen.frame)
        }
        present(overlays)
    }

    /// The recording overlay (spec 0006): the editable selection with window pick and Fullscreen.
    /// v1 covers the main screen, like the other two modes.
    private func presentRecordingOverlay(
        windows: [WindowHoverOverlayModel.HoverWindow], initial: CaptureRegion?, defaults: RecordingDefaults,
        audioInputs: [AudioInputDevice], cameras: [CameraDevice]
    ) {
        let geometry = Self.mainScreen()
        let frame = geometry.frame

        let model = RecordingOverlayModel(
            bounds: Rect(x: 0, y: 0, width: frame.width, height: frame.height),
            pixelScale: geometry.scale,
            displayID: geometry.displayID,
            windows: windows,
            initial: initial,
            defaults: defaults,
            audioInputs: audioInputs,
            cameras: cameras,
            cameraBubble: cameraBubble,
            openSettings: { [weak self] in
                self?.finishRecording(with: nil)
                self?.openSettings()
            },
            permissionGate: permissionGate,
            permissionStatus: permissionStatus
        ) { [weak self] choice in
            self?.finishRecording(with: choice)
        }

        let window = makeOverlayWindow(frame: frame)
        window.onConfirm = { model.startVideo() }
        window.onAlternateConfirm = { model.startGIF() }
        window.onCancel = { model.cancel() }
        window.onArrow = { dx, dy, shift in model.arrow(dx: dx, dy: dy, shift: shift) }
        window.contentView = NSHostingView(rootView: RecordingOverlayView(model: model))
        present([(window, frame)])
    }

    /// Freeze Screen (spec 0011): `content` over an opaque backdrop of its display's frozen still, so
    /// nothing underneath the overlay moves while the user selects — the dimming and the undimmed
    /// selection then show the still, not the live screen. The still is decoded once, here, and
    /// drawn by a layer at the window's exact frame. No still (the self-timer area path) leaves
    /// `content` as is.
    private static func content(_ content: NSView, over frozen: FrozenDisplay?, size: NSSize) -> NSView {
        guard let frozen,
              let source = CGImageSourceCreateWithData(frozen.image.data as CFData, nil),
              let still = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return content }
        let container = NSView(frame: NSRect(origin: .zero, size: size))
        container.wantsLayer = true
        container.layer?.contents = still
        container.layer?.contentsGravity = .resize
        content.frame = container.bounds
        content.autoresizingMask = [.width, .height]
        container.addSubview(content)
        return container
    }

    /// The shared borderless, screen-saver-level, transparent full-screen window every mode presents
    /// in — only its content view and key handlers differ.
    private func makeOverlayWindow(frame: NSRect) -> OverlayKeyWindow {
        OverlayKeyWindow.fullScreen(frame: frame)
    }

    /// Show `overlays` and make the one under the pointer key, so Escape and Return reach it first;
    /// clicking another display's overlay makes that one key.
    private func present(_ overlays: [(window: OverlayKeyWindow, frame: NSRect)]) {
        windows = overlays.map(\.window)
        NSApp.activate(ignoringOtherApps: true)
        let pointer = NSEvent.mouseLocation
        for (window, frame) in overlays {
            window.setFrame(frame, display: true)
            window.orderFront(nil)
        }
        (overlays.first { NSMouseInRect(pointer, $0.frame, false) } ?? overlays.first)?.window.makeKeyAndOrderFront(nil)
    }

    /// Close every overlay window.
    private func dismissWindows() {
        windows.forEach { $0.orderOut(nil) }
        windows = []
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

        return content.windows
            .filter(SCCaptureService.isWindowCandidate)
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
        dismissWindows()
        continuation.resume(returning: region)
    }

    private func finishRecording(with choice: RecordingChoice?) {
        guard let recordingContinuation else { return }
        self.recordingContinuation = nil
        dismissWindows()
        // No take (Escape, the Settings shortcut, a stale overlay): the preview goes with the
        // toolbar. With a take, it stays through the countdown and the recording (story 26).
        if choice == nil { cameraBubble?.hide() }
        recordingContinuation.resume(returning: choice)
    }
}

/// A borderless window that can still become key — so it receives Escape/Return — and routes those
/// keys to the overlay instead of relying on SwiftUI focus, which is unreliable for a transient
/// full-screen surface.
final class OverlayKeyWindow: NSWindow {
    var onConfirm: (() -> Void)?
    /// ⌥-Return (the recording overlay's Record GIF, LIG-42); falls back to `onConfirm` when unset.
    var onAlternateConfirm: (() -> Void)?
    var onCancel: (() -> Void)?
    /// Arrow keys (the recording overlay nudges / ⇧-resizes the selection): unit dx/dy and ⇧.
    var onArrow: ((_ dx: Double, _ dy: Double, _ shift: Bool) -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    /// A borderless, screen-saver-level, transparent window covering `frame` — the surface every
    /// overlay (selection, window hover, recording, countdown) is presented in.
    static func fullScreen(frame: NSRect) -> OverlayKeyWindow {
        let window = OverlayKeyWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.level = .screenSaver
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        // The overlays set the cursor themselves (crosshair, hands, resize arrows); AppKit's
        // cursor rects would keep snapping it back to the arrow on every move.
        window.disableCursorRects()
        return window
    }

    override func keyDown(with event: NSEvent) {
        let shift = event.modifierFlags.contains(.shift)
        switch event.keyCode {
        case 53: onCancel?()           // Escape
        case 36, 76:                   // Return / keypad Enter; ⌥ picks the alternate action
            if event.modifierFlags.contains(.option), let onAlternateConfirm { onAlternateConfirm() } else { onConfirm?() }
        case 123 where onArrow != nil: onArrow?(-1, 0, shift)   // ←
        case 124 where onArrow != nil: onArrow?(1, 0, shift)    // →
        case 125 where onArrow != nil: onArrow?(0, 1, shift)    // ↓
        case 126 where onArrow != nil: onArrow?(0, -1, shift)   // ↑
        default: super.keyDown(with: event)
        }
    }
}
