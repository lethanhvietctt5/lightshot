import AppKit
import SwiftUI
import UniformTypeIdentifiers
import LightshotKit

/// A display the fullscreen menu can target (story 8): the window server's id plus a label to show.
/// `Identifiable` so the SwiftUI menu can `ForEach` over it.
struct DisplayInfo: Identifiable {
    let id: UInt32
    let name: String
}

/// The OS-side composition root and `CaptureUI`.
///
/// Owns the `AppCoordinator` (passing itself as the UI delegate) and turns the coordinator's
/// abstract outcomes into real AppKit surfaces: an editor window, a permission-recovery alert with
/// a System-Settings deep link, and a generic failure alert. The domain core stays framework-free;
/// all the AppKit lives here.
@MainActor
final class AppController: NSObject, CaptureUI {
    private var coordinator: AppCoordinator!
    private var editorWindow: NSWindow?
    private var historyWindow: NSWindow?
    private let postCaptureToolbar = PostCaptureToolbarController()
    private let hotkeyService = CarbonHotkeyService()
    private let pinBoard = PinBoardController()

    override init() {
        super.init()
        coordinator = AppCoordinator(
            // Read the cursor-inclusion preference live at capture time (story 12), off the main
            // actor, from the same defaults the settings window writes.
            captureService: SCCaptureService(includeCursor: {
                UserDefaultsSettingsStore.storedIncludeCursor()
            }),
            overlay: OverlaySelectionController(),
            imageSource: FileImageSource(),
            imageSink: SystemImageSink(),
            settings: settings,
            history: history,
            ui: self
        )
        // Enforce the persisted retention setting on the history store at launch (story 54): the
        // value lives in `SettingsStore` (LIG-15), the trimming lives here in the `HistoryStore` seam.
        applyRetention(settings.historyRetention)
    }

    private let settings = UserDefaultsSettingsStore()
    private let history = HistoryStore(directory: AppController.historyDirectory)

    /// The settings-window bridge. Editing hotkeys re-registers them through `applyHotkeys` (the OS's
    /// refusals flow back to be surfaced); editing history retention re-trims the store through
    /// `applyRetention`, so the setting the window persists is enforced immediately.
    lazy var settingsModel = SettingsModel(
        store: settings,
        applyHotkeys: { [weak self] bindings in self?.applyHotkeys(bindings) ?? [] },
        applyRetention: { [weak self] retention in self?.applyRetention(retention) }
    )

    /// Apply the configured history retention to the store (stories 50/54). `SettingsStore` owns the
    /// value (persisted by LIG-15); the store owns trimming to it — so this is where the two meet.
    func applyRetention(_ retention: Int) {
        try? history.setRetention(retention)
    }

    /// Register the persisted global hotkeys (story 56). Called once at launch and again whenever the
    /// settings window edits a binding; returns the actions the OS refused so the UI can flag them.
    @discardableResult
    func applyHotkeys(_ bindings: HotkeyBindings) -> [CaptureAction] {
        hotkeyService.register(bindings) { [weak self] action in
            self?.perform(action)
        }
    }

    /// Register the stored hotkeys at startup so the shortcuts work before the settings window is
    /// ever opened.
    func registerStoredHotkeys() {
        applyHotkeys(settings.hotkeys)
    }

    /// Route a fired hotkey to its capture entry point.
    private func perform(_ action: CaptureAction) {
        switch action {
        case .area: captureArea()
        case .window: captureWindow()
        case .fullscreen: captureFullscreen()
        case .repeatLast: repeatLast()
        }
    }

    /// Menu / hotkey entry point for the fullscreen capture spine. `displayID` targets a specific
    /// display on a multi-monitor setup (story 8); `nil` (the hotkey path) captures the primary one.
    func captureFullscreen(displayID: UInt32? = nil) {
        Task { await coordinator.captureFullscreen(displayID: displayID) }
    }

    /// Menu / hotkey entry point for re-firing the last capture mode (story 9).
    func repeatLast() {
        Task { await coordinator.repeatLastCapture() }
    }

    /// Menu / hotkey entry point for area capture: overlay → capture → post-capture toolbar.
    func captureArea() {
        Task { await coordinator.captureArea() }
    }

    /// Menu / hotkey entry point for window capture: hover-highlight overlay → capture → toolbar.
    func captureWindow() {
        Task { await coordinator.captureWindow() }
    }

    /// The attached displays, so the menu can offer a per-display fullscreen choice on a multi-monitor
    /// setup (story 8). Maps each `NSScreen` to its `CGDirectDisplayID` — the same id `SCCaptureService`
    /// matches against `SCDisplay.displayID` — plus a human label. A screen with no resolvable id is
    /// dropped (it can't be targeted); the menu falls back to the plain, primary-display action when
    /// fewer than two remain.
    func availableDisplays() -> [DisplayInfo] {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        return NSScreen.screens.enumerated().compactMap { index, screen in
            guard let id = screen.deviceDescription[key] as? CGDirectDisplayID else { return nil }
            let name = screen.localizedName.isEmpty ? "Display \(index + 1)" : screen.localizedName
            return DisplayInfo(id: UInt32(id), name: name)
        }
    }

    /// Menu entry point for opening an existing image file (story 39): file picker → editor. The
    /// panel is modal (synchronous), so unlike the capture spine this needs no `Task`.
    func openFile() {
        coordinator.openFile()
    }

    /// Menu entry point for the capture history window (stories 50–54). Reuses a single window;
    /// the view refreshes its snapshot from the store whenever the window becomes key.
    func showHistory() {
        let window = historyWindow ?? makeHistoryWindow()
        if window.contentViewController == nil {
            let model = HistoryModel(
                store: history,
                onReopen: { [weak self] in self?.openEditor(with: $0) },
                onCopy: { [weak self] in self?.coordinator.copyToClipboard(AnnotationDocument(baseImage: $0)) }
            )
            window.contentViewController = NSHostingController(rootView: HistoryView(model: model))
        }
        historyWindow = window

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    // MARK: - CaptureUI

    func presentPostCaptureToolbar(for image: CapturedImage, at region: CaptureRegion) {
        // Wire the toolbar's actions to capabilities that already exist: annotate opens the editor
        // (story 13's `openEditor(with:)`), copy flattens the un-annotated capture through the same
        // render → clipboard path the editor uses, discard just dismisses.
        postCaptureToolbar.present(
            at: region,
            annotate: { [weak self] in self?.openEditor(with: image) },
            copy: { [weak self] in self?.coordinator.copyToClipboard(AnnotationDocument(baseImage: image)) },
            pin: { [weak self] in self?.pin(AnnotationDocument(baseImage: image)) }
        )
    }

    func openEditor(with image: CapturedImage) {
        let document = AnnotationDocument(baseImage: image)
        let view = EditorView(
            document: document,
            onCopy: { [weak self] in self?.coordinator.copyToClipboard($0) },
            onSave: { [weak self] in self?.save($0) },
            onSaveAs: { [weak self] in self?.saveAs($0) },
            onPin: { [weak self] in self?.pin($0) },
            onDrag: { [weak self] in self?.dragProvider(for: $0) ?? NSItemProvider() }
        )
        let window = editorWindow ?? makeEditorWindow()
        window.contentViewController = NSHostingController(rootView: view)
        window.setContentSize(NSSize(width: 720, height: 480))
        window.center()
        editorWindow = window

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func presentPermissionDenied() {
        let alert = NSAlert()
        alert.messageText = "Screen Recording permission needed"
        alert.informativeText = """
        Lightshot needs Screen Recording permission to capture your screen. \
        Open System Settings, enable Lightshot under Screen Recording, then try again.
        """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")

        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            openScreenRecordingSettings()
        }
    }

    func presentCaptureFailure(_ error: CaptureError) {
        let alert = NSAlert()
        alert.messageText = "Couldn’t take the screenshot"
        alert.informativeText = Self.message(for: error)
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")

        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    func presentImageLoadFailure(_ error: ImageLoadError) {
        // The coordinator routes `userCancelled` to a silent no-op, so only the unreadable /
        // unsupported cases reach here — each gets a distinct message, never a blank editor.
        let alert = NSAlert()
        alert.messageText = "Couldn’t open the image"
        alert.informativeText = Self.message(for: error)
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")

        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    // MARK: - Output (stories 41–45)

    /// Save the flattened document with the configured defaults — no dialog (story 43). On success
    /// the file is revealed in Finder so the user sees where it landed; a write failure surfaces a
    /// distinct alert rather than failing silently.
    private func save(_ document: AnnotationDocument) {
        do {
            let url = try coordinator.save(document)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            presentSaveFailure(error)
        }
    }

    /// Save-As (stories 41–42): an `NSSavePanel` that lets the user pick location, name, and format
    /// (PNG / JPEG). JPEG carries the configured default quality — the per-save override flows
    /// through the same `ImageFormat` value to the sink.
    private func saveAs(_ document: AnnotationDocument) {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.directoryURL = settings.saveLocation
        panel.nameFieldStringValue = FilenameFormatter(pattern: settings.filenamePattern).filename(at: Date())

        let picker = FormatPicker(default: settings.defaultFormat)
        panel.accessoryView = picker.view
        picker.onChange = { [weak panel] format in
            panel?.allowedContentTypes = [format == .png ? .png : .jpeg]
        }
        panel.allowedContentTypes = [settings.defaultFormat == .png ? .png : .jpeg]

        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try coordinator.save(document, to: url, format: picker.format)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            presentSaveFailure(error)
        }
    }

    /// Pin the flattened document as an always-on-top floating window (stories 46–49). The document
    /// is rendered once for display; the pin's copy/save go back through the coordinator's `ImageSink`
    /// passthrough (`render` is deterministic, so they reproduce exactly what's pinned). Save uses the
    /// no-dialog default-location path and reveals the file in Finder, matching the editor's Save.
    private func pin(_ document: AnnotationDocument) {
        pinBoard.pin(
            render(document),
            copy: { [weak self] in self?.coordinator.copyToClipboard(document) },
            save: { [weak self] in self?.save(document) }
        )
    }

    /// The drag-out provider for the editor (story 45): wraps the coordinator's `ImageDragItem` in
    /// an `NSItemProvider` so dropping onto another app yields the rendered image as a file.
    private func dragProvider(for document: AnnotationDocument) -> NSItemProvider {
        let item = coordinator.dragItem(for: document)
        let provider = NSItemProvider()
        provider.suggestedName = item.suggestedName
        provider.registerDataRepresentation(forTypeIdentifier: item.format.utiIdentifier, visibility: .all) { completion in
            completion(item.data, nil)
            return nil
        }
        return provider
    }

    private func presentSaveFailure(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Couldn’t save the image"
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    // MARK: - Helpers

    private func makeEditorWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 480),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Lightshot"
        window.isReleasedWhenClosed = false
        return window
    }

    private func makeHistoryWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 460),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Capture History"
        window.isReleasedWhenClosed = false
        window.center()
        return window
    }

    /// Where the local history keeps its owned image copies + index: Application Support, under the
    /// bundle id, so it is per-user, out of the way, and survives relaunches. Local-only — a v1
    /// guardrail (no cloud, no accounts).
    private static var historyDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        let bundleID = Bundle.main.bundleIdentifier ?? "dev.lightshot.app"
        return base.appendingPathComponent(bundleID, isDirectory: true).appendingPathComponent("History", isDirectory: true)
    }

    private func openScreenRecordingSettings() {
        // Deep link straight to the Screen Recording pane of System Settings.
        let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        )!
        NSWorkspace.shared.open(url)
    }

    private static func message(for error: CaptureError) -> String {
        // Only `presentCaptureFailure` calls this, and the coordinator routes `permissionDenied`
        // and `userCancelled` elsewhere — so those fall through to the generic default.
        switch error {
        case .noDisplayAvailable:
            return "No display was available to capture."
        case .systemFailure(let description):
            return description
        default:
            return "The capture could not be completed."
        }
    }

    private static func message(for error: ImageLoadError) -> String {
        // `userCancelled` is routed to a silent no-op by the coordinator and never reaches here.
        switch error {
        case .unreadable:
            return "The file couldn’t be read."
        case .unsupportedFormat:
            return "That file isn’t an image Lightshot can open."
        case .userCancelled:
            return "Opening the image was cancelled."
        }
    }
}

/// The PNG / JPEG chooser shown as the Save-As panel's accessory view.
///
/// A one-row popup that maps the selection back to an `ImageFormat`. JPEG keeps the quality carried
/// by the `default` format (from settings), so the per-save format still flows through as one value.
@MainActor
private final class FormatPicker {
    let view = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 30))
    var onChange: ((ImageFormat) -> Void)?

    /// JPEG quality to carry through if the user picks JPEG (the settings default, or a fallback).
    private let jpegQuality: Double
    private let popup = NSPopUpButton(frame: NSRect(x: 80, y: 2, width: 150, height: 25), pullsDown: false)

    init(default format: ImageFormat) {
        if case let .jpeg(quality) = format {
            jpegQuality = quality
        } else {
            jpegQuality = 0.9
        }

        let label = NSTextField(labelWithString: "Format:")
        label.frame = NSRect(x: 8, y: 5, width: 68, height: 20)
        label.alignment = .right
        popup.addItems(withTitles: ["PNG", "JPEG"])
        popup.selectItem(at: format == .png ? 0 : 1)
        popup.target = self
        popup.action = #selector(changed)
        view.addSubview(label)
        view.addSubview(popup)
    }

    /// The format the user has selected.
    var format: ImageFormat {
        popup.indexOfSelectedItem == 0 ? .png : .jpeg(clamping: jpegQuality)
    }

    @objc private func changed() { onChange?(format) }
}
