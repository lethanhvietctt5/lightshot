import AppKit
import SwiftUI
import Translation

/// The Translate window for OCR Text (spec 0012): the recognised text, with macOS's own translation
/// popover (`translationPresentation`, macOS 14.4+) open over it. Replace with Translation swaps the
/// window's text for the translation; Copy puts whatever the window shows on the clipboard, so the
/// clipboard only changes when the user asks. Translation is the system's, on this Mac — Lightshot
/// makes no network call. One window at a time: a newer text replaces the text of the open window,
/// which keeps its place and size, and the popover opens again over it.
@available(macOS 14.4, *)
@MainActor
final class TranslateWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var model: TranslateModel?

    func show(_ text: String) {
        if let window, let model {
            model.text = text
            model.showsTranslation = false
            WindowPresenter.present(window)
            model.showsTranslationSoon()
            return
        }
        let model = TranslateModel(text: text)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 260),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Translate"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentViewController = NSHostingController(rootView: TranslateView(model: model))
        window.setContentSize(NSSize(width: 440, height: 260))
        window.center()
        self.window = window
        self.model = model
        WindowPresenter.present(window)
        model.showsTranslationSoon()
    }

    func windowWillClose(_ notification: Notification) {
        guard (notification.object as? NSWindow) === window else { return }
        window = nil
        model = nil
    }
}

@MainActor
@Observable
private final class TranslateModel {
    var text: String
    /// Whether the system translation popover is open over the text.
    var showsTranslation = false

    init(text: String) { self.text = text }

    /// Open the popover once the window is on screen: it needs a visible view to anchor to, and
    /// asking in the same turn the window is ordered front leaves it unshown.
    func showsTranslationSoon() {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(150))
            showsTranslation = true
        }
    }
}

@available(macOS 14.4, *)
private struct TranslateView: View {
    @Bindable var model: TranslateModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ScrollView {
                Text(model.text)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .background(.background, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
            .translationPresentation(isPresented: $model.showsTranslation, text: model.text) { translated in
                model.text = translated
            }
            HStack {
                Spacer()
                Button("Translate") { model.showsTranslation = true }
                Button("Copy") {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(model.text, forType: .string)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(minWidth: 360, minHeight: 200)
    }
}
