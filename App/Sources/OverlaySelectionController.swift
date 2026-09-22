import AppKit
import ScreenCaptureKit
import SwiftUI
import LightshotKit

/// The concrete `OverlayController`: a full-screen dimmed `NSWindow` that resolves the user's
/// choice into a `CaptureRegion` (or `nil` on Escape). The pre-capture step — it never captures.
///
/// A thin OS wrapper (no unit tests; the coordinator's overlay → capture ordering is tested against
/// a fake). Every entry point bridges the window's imperative lifecycle to `async` via a checked
/// continuation, resumed exactly once when the user confirms or cancels: `selectRegion()` drags a
/// rect (LIG-13), `selectWindow()` hover-highlights and clicks a window (LIG-14),
/// `selectRecording(initial:defaults:)` runs the editable recording selection with the recorder
/// toolbar (spec 0006). v1 covers the main screen; per-display selection is a follow-up.
@MainActor
final class OverlaySelectionController: OverlayController {
    /// The recorder toolbar's settings shortcut: cancels the overlay and opens Settings.
    private let openSettings: () -> Void
    /// The recorder toolbar's lazy permission gate: whether a toggle may switch on (story 41).
    private let permissionGate: (RecordingToggle) async -> Bool
    /// The microphones the toolbar's device menu lists (story 20).
    private let audioInputs: () async -> [AudioInputDevice]
    private var window: OverlayKeyWindow?

    init(
        openSettings: @escaping () -> Void = {},
        permissionGate: @escaping (RecordingToggle) async -> Bool = { _ in true },
        audioInputs: @escaping () async -> [AudioInputDevice] = { [] }
    ) {
        self.openSettings = openSettings
        self.permissionGate = permissionGate
        self.audioInputs = audioInputs
    }
    private var continuation: CheckedContinuation<CaptureRegion?, Never>?
    private var recordingContinuation: CheckedContinuation<RecordingChoice?, Never>?

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

    func selectRecording(initial: CaptureRegion?, defaults: RecordingDefaults) async -> RecordingChoice? {
        resolveStaleContinuation()
        let windows = await Self.hoverableWindows()
        let inputs = await audioInputs()
        return await withCheckedContinuation { continuation in
            self.recordingContinuation = continuation
            presentRecordingOverlay(windows: windows, initial: initial, defaults: defaults, audioInputs: inputs)
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
            stale.resume(returning: nil)
        }
    }

    /// The main screen every overlay covers in v1: its frame, backing scale and display id.
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

    private func presentRectOverlay() {
        let geometry = Self.mainScreen()
        let frame = geometry.frame

        let model = SelectionOverlayModel(pixelScale: geometry.scale) { [weak self] region in
            self?.finish(with: region)
        }

        let window = makeOverlayWindow(frame: frame)
        window.onConfirm = { model.confirm() }
        window.onCancel = { model.cancel() }
        window.contentView = NSHostingView(rootView: SelectionOverlayView(model: model))
        present(window, at: frame)
    }

    private func presentWindowOverlay(windows: [WindowHoverOverlayModel.HoverWindow]) {
        let frame = Self.mainScreen().frame

        let model = WindowHoverOverlayModel(windows: windows) { [weak self] region in
            self?.finish(with: region)
        }

        let window = makeOverlayWindow(frame: frame)
        window.onConfirm = { model.confirmHovered() }
        window.onCancel = { model.cancel() }
        window.contentView = NSHostingView(rootView: WindowHoverOverlayView(model: model))
        present(window, at: frame)
    }

    /// The recording overlay (spec 0006): the editable selection with window pick and Fullscreen.
    /// v1 covers the main screen, like the other two modes.
    private func presentRecordingOverlay(
        windows: [WindowHoverOverlayModel.HoverWindow], initial: CaptureRegion?, defaults: RecordingDefaults,
        audioInputs: [AudioInputDevice]
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
            openSettings: { [weak self] in
                self?.finishRecording(with: nil)
                self?.openSettings()
            },
            permissionGate: permissionGate
        ) { [weak self] choice in
            self?.finishRecording(with: choice)
        }

        let window = makeOverlayWindow(frame: frame)
        window.onConfirm = { model.startVideo() }
        window.onCancel = { model.cancel() }
        window.onArrow = { dx, dy, shift in model.arrow(dx: dx, dy: dy, shift: shift) }
        window.contentView = NSHostingView(rootView: RecordingOverlayView(model: model))
        present(window, at: frame)
    }

    /// The shared borderless, screen-saver-level, transparent full-screen window every mode presents
    /// in — only its content view and key handlers differ.
    private func makeOverlayWindow(frame: NSRect) -> OverlayKeyWindow {
        OverlayKeyWindow.fullScreen(frame: frame)
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

    private func finishRecording(with choice: RecordingChoice?) {
        guard let recordingContinuation else { return }
        self.recordingContinuation = nil
        window?.orderOut(nil)
        window = nil
        recordingContinuation.resume(returning: choice)
    }
}

/// A borderless window that can still become key — so it receives Escape/Return — and routes those
/// keys to the overlay instead of relying on SwiftUI focus, which is unreliable for a transient
/// full-screen surface.
final class OverlayKeyWindow: NSWindow {
    var onConfirm: (() -> Void)?
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
        return window
    }

    override func keyDown(with event: NSEvent) {
        let shift = event.modifierFlags.contains(.shift)
        switch event.keyCode {
        case 53: onCancel?()           // Escape
        case 36, 76: onConfirm?()      // Return / keypad Enter
        case 123 where onArrow != nil: onArrow?(-1, 0, shift)   // ←
        case 124 where onArrow != nil: onArrow?(1, 0, shift)    // →
        case 125 where onArrow != nil: onArrow?(0, 1, shift)    // ↓
        case 126 where onArrow != nil: onArrow?(0, -1, shift)   // ↑
        default: super.keyDown(with: event)
        }
    }
}
