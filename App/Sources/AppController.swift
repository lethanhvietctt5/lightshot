import AppKit
import SwiftUI
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
            imageSink: PasteboardImageSink(),
            ui: self
        )
    }

    /// Menu / hotkey entry point for the fullscreen capture spine.
    func captureFullscreen() {
        Task { await coordinator.captureFullscreen() }
    }

    /// Menu / hotkey entry point for area capture: overlay → capture → post-capture toolbar.
    func captureArea() {
        Task { await coordinator.captureArea() }
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
        let view = EditorView(document: document) { [weak self] edited in
            self?.coordinator.copyToClipboard(edited)
        }
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
