import AppKit
import SwiftUI
import UniformTypeIdentifiers
import LightshotKit

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
    private let postCaptureToolbar = PostCaptureToolbarController()

    override init() {
        super.init()
        coordinator = AppCoordinator(
            captureService: SCCaptureService(),
            overlay: OverlaySelectionController(),
            imageSink: SystemImageSink(),
            settings: settings,
            ui: self
        )
    }

    private let settings = UserDefaultsSettingsStore()

    /// Menu / hotkey entry point for the fullscreen capture spine.
    func captureFullscreen() {
        Task { await coordinator.captureFullscreen() }
    }

    /// Menu / hotkey entry point for area capture: overlay → capture → post-capture toolbar.
    func captureArea() {
        Task { await coordinator.captureArea() }
    }

    /// Menu / hotkey entry point for window capture: hover-highlight overlay → capture → toolbar.
    func captureWindow() {
        Task { await coordinator.captureWindow() }
    }

    // MARK: - CaptureUI

    func presentPostCaptureToolbar(for image: CapturedImage, at region: CaptureRegion) {
        // Wire the toolbar's actions to capabilities that already exist: annotate opens the editor
        // (story 13's `openEditor(with:)`), copy flattens the un-annotated capture through the same
        // render → clipboard path the editor uses, discard just dismisses.
        postCaptureToolbar.present(
            at: region,
            annotate: { [weak self] in self?.openEditor(with: image) },
            copy: { [weak self] in self?.coordinator.copyToClipboard(AnnotationDocument(baseImage: image)) }
        )
    }

    func openEditor(with image: CapturedImage) {
        let document = AnnotationDocument(baseImage: image)
        let view = EditorView(
            document: document,
            onCopy: { [weak self] in self?.coordinator.copyToClipboard($0) },
            onSave: { [weak self] in self?.save($0) },
            onSaveAs: { [weak self] in self?.saveAs($0) },
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
