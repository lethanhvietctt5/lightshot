import AppKit
import SwiftUI
import LightshotKit

/// Interaction state for the recording overlay (spec 0006, stories 3–7), kept out of the SwiftUI
/// view so the view stays a thin projection of it — the same split the screenshot overlays use.
///
/// The geometry lives in the pure `EditableSelection`; this model adds what needs a screen: the
/// hover-and-click window pick, the click-vs-drag distinction, the Option key, and resolution into
/// a `CaptureRegion`. Unlike the screenshot overlay, releasing a drag never confirms — Return
/// (Start, once the recorder toolbar lands) does. Coordinates are screen points (top-left origin)
/// at 1:1 with the overlay window, so no projection is needed.
@MainActor
@Observable
final class RecordingOverlayModel {
    typealias HoverWindow = WindowHoverOverlayModel.HoverWindow

    private(set) var selection: EditableSelection
    /// Candidates front-most first, so the first frame containing the pointer is the visible one.
    let windows: [HoverWindow]
    /// The display the overlay covers — what "Fullscreen" resolves to.
    let displayID: UInt32
    /// Screen points → native pixels: the readout, the typed fields and the arrow keys all speak pixels.
    let pixelScale: Double
    private let finish: (CaptureRegion?) -> Void

    /// The window under the pointer while nothing is selected yet — what the view highlights.
    private(set) var hovered: HoverWindow?
    /// The window the selection is snapped to (story 5); `nil` for a drawn rect. A snapped window
    /// shows no handles and resolves to `.window`; any edit turns it back into a plain rect.
    private(set) var snappedWindow: HoverWindow?

    private var dragStart: Point?
    private var isDragging = false

    init(
        bounds: Rect, pixelScale: Double, displayID: UInt32, windows: [HoverWindow],
        initial: CaptureRegion?, finish: @escaping (CaptureRegion?) -> Void
    ) {
        self.windows = windows
        self.displayID = displayID
        self.pixelScale = pixelScale
        self.finish = finish

        // Pre-fill the remembered region (story 7) when it still makes sense on this display: a
        // rect is clipped or dropped by `EditableSelection`; a window only if it is still open.
        switch initial {
        case let .rect(rect):
            selection = EditableSelection(bounds: bounds, rect: rect)
        case let .window(id, frame):
            selection = EditableSelection(bounds: bounds)
            if let window = windows.first(where: { $0.id == id }) {
                selection.snap(to: frame)
                snappedWindow = window
            }
        case let .display(id):
            // Only the display this overlay covers can be pre-filled.
            selection = EditableSelection(bounds: bounds, rect: id == displayID ? bounds : nil)
        case nil:
            selection = EditableSelection(bounds: bounds)
        }
    }

    // MARK: - Derived state for the view

    var hasSelection: Bool { selection.hasSelection }

    /// Handles are drawn only for an editable rect that isn't mid-drag.
    var showsHandles: Bool { hasSelection && snappedWindow == nil && !isDragging }

    var pixelSize: (width: Int, height: Int)? {
        guard let rect = selection.rect, hasSelection else { return nil }
        return (Int((rect.width * pixelScale).rounded()), Int((rect.height * pixelScale).rounded()))
    }

    var ratio: AspectRatio { selection.ratio }

    // MARK: - Pointer

    func hover(at point: Point) {
        hovered = hasSelection ? nil : window(at: point)
    }

    func hoverEnded() {
        hovered = nil
    }

    /// A zero-distance gesture is a click; only movement past a few points becomes a drag, so a
    /// click on a window snaps to it rather than drawing a 1-pt rect over it.
    func dragChanged(to point: Point) {
        guard let start = dragStart else {
            dragStart = point
            return
        }
        if !isDragging {
            guard start.distance(to: point) >= Self.dragThreshold else { return }
            isDragging = true
            // Any drag — a fresh rect, a move, or a (hidden) handle — turns a snapped window back
            // into a plain rect, so what is resolved always matches what is shown.
            snappedWindow = nil
            selection.dragBegan(at: start)
        }
        selection.dragChanged(to: point, forceSquare: Self.optionHeld)
    }

    func dragEnded(at point: Point) {
        defer { dragStart = nil; isDragging = false }
        if isDragging {
            selection.dragEnded(at: point, forceSquare: Self.optionHeld)
            hovered = nil
        } else {
            click(at: point)
        }
    }

    /// Click: snap to the window under the pointer when nothing is selected; a click outside an
    /// existing selection clears it so windows can be picked again; a click inside does nothing.
    private func click(at point: Point) {
        if !hasSelection {
            guard let window = window(at: point) else { return }
            snappedWindow = window
            selection.snap(to: window.frame)
            hovered = nil
        } else if selection.dragKind(at: point) == .draw {   // outside the selection and its handles
            clearSelection()
        }
    }

    private func window(at point: Point) -> HoverWindow? {
        windows.first { $0.frame.contains(point) }
    }

    private func clearSelection() {
        snappedWindow = nil
        selection = EditableSelection(bounds: selection.bounds, ratio: selection.ratio)
    }

    // MARK: - Keyboard and fields

    /// Arrow keys: move by 1 px; with ⇧, resize by 10 px (native pixels, like the readout). Either
    /// edit turns a snapped window into a plain rect.
    func arrow(dx: Double, dy: Double, shift: Bool) {
        guard hasSelection else { return }
        snappedWindow = nil
        if shift {
            selection.resize(dw: dx * 10 / pixelScale, dh: dy * 10 / pixelScale)
        } else {
            selection.nudge(dx: dx / pixelScale, dy: dy / pixelScale)
        }
    }

    func setRatio(_ ratio: AspectRatio) {
        snappedWindow = nil
        selection.setRatio(ratio)
    }

    /// The typed width, in native pixels.
    func setWidth(pixels: Double) {
        snappedWindow = nil
        selection.setWidth(pixels / pixelScale)
    }

    /// The typed height, in native pixels.
    func setHeight(pixels: Double) {
        snappedWindow = nil
        selection.setHeight(pixels / pixelScale)
    }

    // MARK: - Resolution

    /// Start (Return): a snapped window resolves to `.window`, a rect covering the whole display to
    /// `.display`, anything else to `.rect`. A no-op with nothing selected.
    func confirm() {
        guard let rect = selection.rect, hasSelection else { return }
        if let snappedWindow {
            finish(.window(id: snappedWindow.id, frame: rect))
        } else if rect == selection.bounds {
            finish(.display(id: displayID))
        } else {
            finish(.rect(rect))
        }
    }

    /// The Fullscreen button (story 6): record the whole display.
    func chooseFullscreen() {
        finish(.display(id: displayID))
    }

    /// Cancel (Escape): resolves to `nil`, a silent no-op with no recording.
    func cancel() { finish(nil) }

    private static let dragThreshold: Double = 3

    /// SwiftUI's drag gesture carries no modifiers; read the Option key live instead.
    private static var optionHeld: Bool { NSEvent.modifierFlags.contains(.option) }
}
