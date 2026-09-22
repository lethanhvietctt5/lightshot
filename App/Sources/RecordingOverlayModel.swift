import AppKit
import SwiftUI
import LightshotKit

/// Interaction state for the recording overlay (spec 0006, stories 3–7), kept out of the SwiftUI
/// view so the view stays a thin projection of it — the same split the screenshot overlays use.
///
/// The geometry lives in the pure `EditableSelection`; this model adds what needs a screen: the
/// hover-and-click window pick, the click-vs-drag distinction, the Option key, the recorder
/// toolbar's per-recording toggles (story 9: seeded from Settings, overriding for this take only),
/// and resolution into a `RecordingChoice`. Unlike the screenshot overlay, releasing a drag never
/// confirms — Start Video / Start GIF (Return is Start Video) does. Coordinates are screen points
/// (top-left origin) at 1:1 with the overlay window, so no projection is needed.
@MainActor
@Observable
final class RecordingOverlayModel {
    typealias HoverWindow = WindowHoverOverlayModel.HoverWindow

    private(set) var selection: EditableSelection {
        didSet { syncCameraPreview() }
    }
    /// Candidates front-most first, so the first frame containing the pointer is the visible one.
    let windows: [HoverWindow]
    /// The display the overlay covers — what "Fullscreen" resolves to.
    let displayID: UInt32
    /// Screen points → native pixels: the readout, the typed fields and the arrow keys all speak pixels.
    let pixelScale: Double
    /// The Settings baseline the toggles start from.
    let defaults: RecordingDefaults
    /// The microphones the mic toggle's menu lists (story 20).
    let audioInputs: [AudioInputDevice]
    /// The microphone this take narrates through; `nil` is the system default. Seeded from Settings
    /// and persisted back by the coordinator when the take starts.
    private(set) var microphoneDeviceID: String?
    /// The cameras the camera toggle's menu lists (story 27), and the one this take composites.
    let cameras: [CameraDevice]
    private(set) var cameraDeviceID: String?
    /// The live preview bubble over the selection while the camera toggle is on (story 26).
    private let cameraBubble: CameraBubbleController?
    private let finish: (RecordingChoice?) -> Void
    /// The toolbar's settings shortcut (story 8).
    let openSettings: () -> Void
    /// Whether a toggle may switch on: asks for its grant lazily (story 41); `false` keeps it off.
    let permissionGate: (RecordingToggle) async -> Bool
    /// A toggle's standing grant, read without prompting — for the warning badges (LIG-42).
    let permissionStatus: (RecordingToggle) async -> CaptureAuthorizationStatus
    /// Toggles whose grant is not standing right now; the toolbar badges them.
    private(set) var missingPermissions: Set<RecordingToggle> = []

    /// This take's toggle overrides; `nil` per toggle means "as in Settings".
    private(set) var overrides = RecordingOverrides.none

    /// The window under the pointer while nothing is selected yet — what the view highlights.
    private(set) var hovered: HoverWindow?
    /// The window the selection is snapped to (story 5); `nil` for a drawn rect. A snapped window
    /// shows no handles and resolves to `.window`; any edit turns it back into a plain rect.
    private(set) var snappedWindow: HoverWindow?

    private var dragStart: Point?
    private var isDragging = false

    /// What the pointer should look like where it is (LIG-42): a crosshair over empty screen, an
    /// open hand inside the selection, a closed hand while moving it, the matching resize cursor
    /// over a handle, the arrow when the pointer has left the canvas (over the toolbar).
    private(set) var cursor: PointerCursor = .crosshair

    init(
        bounds: Rect, pixelScale: Double, displayID: UInt32, windows: [HoverWindow],
        initial: CaptureRegion?, defaults: RecordingDefaults,
        audioInputs: [AudioInputDevice] = [],
        cameras: [CameraDevice] = [],
        cameraBubble: CameraBubbleController? = nil,
        openSettings: @escaping () -> Void = {},
        permissionGate: @escaping (RecordingToggle) async -> Bool = { _ in true },
        permissionStatus: @escaping (RecordingToggle) async -> CaptureAuthorizationStatus = { _ in .authorized },
        finish: @escaping (RecordingChoice?) -> Void
    ) {
        self.windows = windows
        self.displayID = displayID
        self.pixelScale = pixelScale
        self.defaults = defaults
        self.audioInputs = audioInputs
        // Kept even if that device is not attached right now: the capture falls back to the system
        // default for this take, and the preference survives for when it is plugged back in.
        self.microphoneDeviceID = defaults.microphoneDeviceID
        self.cameras = cameras
        self.cameraDeviceID = defaults.cameraDeviceID
        self.cameraBubble = cameraBubble
        self.openSettings = openSettings
        self.permissionGate = permissionGate
        self.permissionStatus = permissionStatus
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
        // Nothing usable to pre-fill: start from almost the whole display (LIG-42, as CleanShot
        // does), so the size fields are filled and Record works at once; any drag replaces it.
        if !selection.hasSelection, snappedWindow == nil {
            selection = EditableSelection(bounds: bounds, rect: bounds.insetBy(dx: Self.defaultInset, dy: Self.defaultInset))
        }
        // The camera on by default (Settings) still passes the permission gate first (story 41):
        // an ungranted camera turns the toggle off for this take rather than opening the device.
        if isOn(.camera), cameraBubble != nil {
            Task { @MainActor in
                if await permissionGate(.camera) { syncCameraPreview() } else { overrides[.camera] = false }
            }
        }
        Task { @MainActor in await refreshPermissions() }
    }

    /// Re-read every gated toggle's grant; called at start and after each ask.
    private func refreshPermissions() async {
        var missing = Set<RecordingToggle>()
        for toggle in RecordingToggle.allCases where toggle.requiredPermission != nil {
            if await permissionStatus(toggle) != .authorized { missing.insert(toggle) }
        }
        missingPermissions = missing
    }

    /// The badge's message for a toggle whose grant is missing, else `nil`.
    func permissionWarning(for toggle: RecordingToggle) -> String? {
        guard missingPermissions.contains(toggle), let kind = toggle.requiredPermission else { return nil }
        return "\(kind.settingsTitle) permission not granted — click to allow"
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

    /// The toolbar's toggles in display order (story 8).
    var toggles: [RecordingToggle] { RecordingToggle.allCases }

    /// A toggle's current state: this take's override, else the Settings default.
    func isOn(_ toggle: RecordingToggle) -> Bool {
        overrides[toggle] ?? defaults[toggle]
    }

    /// Flip a toggle for this recording only — Settings are never written (story 9). Switching
    /// one on first passes the permission gate, which asks for the grant right then (story 41).
    func toggle(_ toggle: RecordingToggle) async {
        let turningOn = !isOn(toggle)
        if turningOn {
            guard await permissionGate(toggle) else {
                await refreshPermissions()
                return
            }
        }
        overrides[toggle] = turningOn
        if toggle == .camera { syncCameraPreview() }
        if turningOn { await refreshPermissions() }
    }

    /// Pick a microphone from the mic toggle's menu (story 20) and make sure the toggle is on; a
    /// refused permission leaves both the toggle and the choice as they were.
    func selectMicrophone(_ deviceID: String?) async {
        if !isOn(.microphone) {
            await toggle(.microphone)
            guard isOn(.microphone) else { return }
        }
        microphoneDeviceID = deviceID
    }

    /// The menu's "Do Not Record Microphone".
    func turnOffMicrophone() {
        overrides[.microphone] = false
    }

    /// Pick a camera from the camera toggle's menu (story 27), switching the toggle on first.
    func selectCamera(_ deviceID: String?) async {
        if !isOn(.camera) {
            await toggle(.camera)
            guard isOn(.camera) else { return }
        }
        cameraDeviceID = deviceID
        syncCameraPreview()
    }

    /// The menu's "Do Not Record Camera".
    func turnOffCamera() {
        overrides[.camera] = false
        syncCameraPreview()
    }

    /// CleanShot's warning: a camera take with no microphone is silent, which is rarely intended.
    var cameraWithoutMicrophone: Bool { isOn(.camera) && !isOn(.microphone) }

    /// The preview bubble follows the camera toggle and the selection (story 26): shown over the
    /// selected region while the camera is on, gone otherwise.
    private func syncCameraPreview() {
        guard let cameraBubble else { return }
        guard isOn(.camera) else {
            cameraBubble.hide()
            return
        }
        if hasSelection, let rect = selection.rect {
            // `show` re-targets a running preview (a new device restarts the capture; the same one
            // only moves), so it is safe to call on every change.
            cameraBubble.show(deviceID: cameraDeviceID, region: rect, settings: defaults.cameraBubble)
        } else {
            cameraBubble.conceal()
        }
    }

    // MARK: - Pointer

    func hover(at point: Point) {
        hovered = hasSelection ? nil : window(at: point)
        if !isDragging { cursor = cursor(at: point) }
    }

    /// The pointer left the canvas — for the toolbar or another screen. Mid-drag the drag owns
    /// the cursor.
    func hoverEnded() {
        hovered = nil
        if !isDragging { cursor = .arrow }
    }

    /// The cursor for a pointer at rest at `point`, from what a drag there would do.
    private func cursor(at point: Point) -> PointerCursor {
        switch selection.dragKind(at: point) {
        case .draw: return .crosshair
        case .move: return .openHand
        case let .resize(handle): return .resize(handle)
        }
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
            switch selection.dragKind(at: start) {
            case .draw: cursor = .crosshair
            case .move: cursor = .closedHand
            case let .resize(handle): cursor = .resize(handle)
            }
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
        cursor = cursor(at: point)
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

    /// The region a Start button resolves: a snapped window is `.window`, a rect covering the whole
    /// display is `.display`, anything else `.rect`; `nil` with nothing selected.
    var region: CaptureRegion? {
        guard let rect = selection.rect, hasSelection else { return nil }
        if let snappedWindow { return .window(id: snappedWindow.id, frame: rect) }
        return rect == selection.bounds ? .display(id: displayID) : .rect(rect)
    }

    /// Start Video (also Return, via the hosting window).
    func startVideo() { start(.video) }

    /// Start GIF: recorded as video, converted afterwards (R13).
    func startGIF() { start(.gif) }

    /// Record in Studio Mode (LIG-42): a video take that opens in the video editor when it stops,
    /// whatever the After-recording setting says.
    func startStudio() {
        var overrides = overrides
        overrides.afterRecording = .openEditor
        start(.video, overrides: overrides)
    }

    private func start(_ output: RecordingOutputKind, overrides: RecordingOverrides? = nil) {
        guard let region else { return }
        finish(RecordingChoice(
            region: region, output: output, overrides: overrides ?? self.overrides,
            microphoneDeviceID: microphoneDeviceID, cameraDeviceID: cameraDeviceID
        ))
    }

    /// The Fullscreen button (story 6): select the whole display; Start then records it.
    func chooseFullscreen() {
        snappedWindow = nil
        selection.snap(to: selection.bounds)
        hovered = nil
    }

    /// Cancel (Escape): resolves to `nil`, a silent no-op with no recording.
    func cancel() {
        cameraBubble?.hide()
        finish(nil)
    }

    private static let dragThreshold: Double = 3
    /// How far the default selection sits inside the display's edges, in points.
    private static let defaultInset: Double = 40

    /// SwiftUI's drag gesture carries no modifiers; read the Option key live instead.
    private static var optionHeld: Bool { NSEvent.modifierFlags.contains(.option) }
}

/// The pointers the recording overlay (LIG-42) and the editor's crop (LIG-47) show, resolved to
/// `NSCursor` by their views.
enum PointerCursor: Equatable {
    case arrow
    case crosshair
    case openHand
    case closedHand
    case resize(Handle)

    var nsCursor: NSCursor {
        switch self {
        case .arrow: return .arrow
        case .crosshair: return .crosshair
        case .openHand: return .openHand
        case .closedHand: return .closedHand
        case let .resize(handle): return Self.resizeCursor(for: handle)
        }
    }

    /// Edges get the system's two-way arrows on every supported macOS; the diagonal corner
    /// cursors only exist publicly from macOS 15, so macOS 14 falls back to the crosshair.
    private static func resizeCursor(for handle: Handle) -> NSCursor {
        switch handle {
        case .left, .right: return .resizeLeftRight
        case .top, .bottom: return .resizeUpDown
        case .topLeft, .topRight, .bottomLeft, .bottomRight:
            if #available(macOS 15, *) {
                let position: NSCursor.FrameResizePosition
                switch handle {
                case .topLeft: position = .topLeft
                case .topRight: position = .topRight
                case .bottomLeft: position = .bottomLeft
                default: position = .bottomRight
                }
                return .frameResize(position: position, directions: .all)
            }
            return .crosshair
        }
    }
}
