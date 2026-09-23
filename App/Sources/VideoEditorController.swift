import AppKit
import AVFoundation
import SwiftUI
import LightshotKit

/// The video editor window — the **Studio editor** (spec 0007), in the LIG-43 shell: a dark
/// window whose toolbar carries the title, an **Edited** marker and the **Export** button; an icon
/// rail and its inspector (background, cursor, zoom, camera, keystrokes, audio, output); the
/// preview with a transport row; and a timeline with clip and zoom tracks. A studio project is
/// autosaved and its export filed like a recording; a plain movie exports to a new sibling file or
/// replaces the original (kept as a backup until the window closes, for **Revert to Original**).
/// Not the annotation editor.
@MainActor
final class VideoEditorController: NSObject, NSWindowDelegate, NSToolbarDelegate, NSToolbarItemValidation {
    private var window: NSWindow?
    private var model: StudioEditorModel?
    private var exportPopover: NSPopover?
    /// Files a project's export into history and the save location (story 27); set by the app.
    var fileExport: ((URL, String?) async -> URL?)?

    private static let exportItem = NSToolbarItem.Identifier("videoEditor.export")

    /// A studio project (spec 0007, stories 3–4): autosaved as it is edited.
    func open(project: StudioProject, store: StudioProjectStore) {
        present(StudioEditorModel(session: .project(project, store)))
    }

    /// A plain movie (a non-studio take, or one from history).
    func open(_ url: URL) {
        present(StudioEditorModel(session: .file(url)))
    }

    private func present(_ model: StudioEditorModel) {
        // A session already open saves, gives up its backup and any export before the next takes the window.
        self.model?.close()
        model.presentExport = { [weak self] in self?.toggleExport() }
        model.onLoaded = { [weak self] in self?.window?.toolbar?.validateVisibleItems() }
        model.fileExport = fileExport
        self.model = model
        exportPopover?.close()
        exportPopover = nil
        let window = self.window ?? makeWindow()
        let hosting = NSHostingController(rootView: StudioEditorView(model: model))
        // The window keeps the size set below; the timeline and panels stretch to fill it.
        hosting.sizingOptions = []
        window.contentViewController = hosting
        window.title = model.title
        if window.toolbar == nil { window.toolbar = makeToolbar() }
        window.setContentSize(Self.defaultContentSize(on: window.screen ?? NSScreen.main))
        window.center()
        self.window = window
        // Counted once per showing: a clip opened into the open window must not count again, or
        // closing it would leave the app regular.
        WindowPresenter.present(window, asRegularApp: !window.isVisible)
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(white: 0.12, alpha: 1)
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        // The content draws the title and its own divider under the transparent toolbar.
        window.titlebarSeparatorStyle = .none
        window.toolbarStyle = .unified
        window.contentMinSize = NSSize(width: 1000, height: 680)
        return window
    }

    /// Most of the screen, like CleanShot's editor: up to 1600 × 1000, leaving a margin.
    private static func defaultContentSize(on screen: NSScreen?) -> NSSize {
        let visible = screen?.visibleFrame.size ?? NSSize(width: 1440, height: 900)
        return NSSize(width: min(1600, visible.width * 0.85), height: min(1000, visible.height * 0.85))
    }

    private func makeToolbar() -> NSToolbar {
        let toolbar = NSToolbar(identifier: "videoEditor")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        return toolbar
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, Self.exportItem]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    /// **Export**: the system's prominent toolbar button tinted blue (macOS 26+), a blue push
    /// button before that — a native item, so it never gets a glass platter around a custom view.
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard identifier == Self.exportItem else { return nil }
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = "Export"
        item.toolTip = "Export the edited video (⌘E)"
        item.target = self
        item.action = #selector(exportClicked(_:))
        if #available(macOS 26.0, *) {
            item.title = "Export"
            item.isBordered = true
            item.style = .prominent
            item.backgroundTintColor = .systemBlue
        } else {
            let button = NSButton(title: "Export", target: self, action: #selector(exportClicked(_:)))
            button.bezelStyle = .push
            button.bezelColor = .systemBlue
            item.view = button
        }
        return item
    }

    func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        model?.sources != nil
    }

    @objc private func exportClicked(_ sender: Any?) {
        toggleExport()
    }

    /// The export options in a popover under the Export item.
    private func toggleExport() {
        if let exportPopover, exportPopover.isShown {
            exportPopover.close()
            return
        }
        guard let model, model.sources != nil,
              let item = window?.toolbar?.items.first(where: { $0.itemIdentifier == Self.exportItem }) else { return }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.appearance = NSAppearance(named: .darkAqua)
        popover.contentViewController = NSHostingController(rootView: StudioExportPanel(model: model))
        popover.show(relativeTo: item)
        exportPopover = popover
    }

    func windowWillClose(_ notification: Notification) {
        exportPopover?.close()
        exportPopover = nil
        model?.close()
        model = nil
        WindowPresenter.regularWindowClosed()
    }

    #if DEBUG
    /// Development aid for the `-studioSeek` launch argument.
    func debugSeek(to time: Double) { model?.seek(to: time) }
    #endif

    /// Quitting skips `windowWillClose`: save, drop the backup and cancel an export here instead.
    func prepareForTermination() {
        model?.close()
        model = nil
    }
}
