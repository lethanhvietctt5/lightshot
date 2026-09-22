import AppKit
import AVKit
import Quartz
import SwiftUI
import LightshotKit

/// The post-recording overlay (spec 0006, stories 32–34; CleanShot's Quick Access Overlay): a
/// small panel in the screen's bottom-right corner with a looping, muted preview of the take, its
/// duration and size, a name to edit, and the after-recording actions. The take is still in the
/// scratch directory while this is up; the `AppCoordinator` decides where it goes from the
/// action the panel reports (copy / save / delete / dismiss).
///
/// A thin OS wrapper (no unit tests): placement, lifetime, key handling (Escape dismisses, Space
/// opens Quick Look), the timeout, and the drag-out (the preview is a file drag source).
@MainActor
final class PostRecordingOverlayController: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    struct Actions {
        let copy: () -> Void
        /// Save under the (possibly renamed) name; returns whether it succeeded.
        let save: (String) -> Bool
        let delete: () -> Void
        let dismiss: () -> Void
        let openEditor: (() -> Void)?
        let trim: (() -> Void)?
    }

    /// How long the overlay stays up untouched before it dismisses itself (and the file is kept).
    static let timeout: TimeInterval = 20

    private var panel: OverlayPanel?
    private var model: PostRecordingModel?
    private var timeoutTask: Task<Void, Never>?
    private var keyMonitor: Any?

    func present(_ recording: PendingRecording, actions: Actions) {
        dismiss(reportingDismissal: false)
        let model = PostRecordingModel(recording: recording)
        self.model = model

        let view = PostRecordingOverlayView(
            model: model,
            copy: { [weak self] in actions.copy(); self?.flash("Copied"); self?.restartTimeout() },
            save: { [weak self] in
                guard let self else { return }
                if actions.save(model.name) { close() }
            },
            delete: { [weak self] in
                guard let self else { return }
                if confirmDelete() { actions.delete(); close() }
            },
            quickLook: { [weak self] in self?.toggleQuickLook() },
            openEditor: actions.openEditor.map { open in { [weak self] in open(); self?.close() } },
            trim: actions.trim.map { trim in { [weak self] in trim(); self?.close() } },
            touched: { [weak self] in self?.restartTimeout() }
        )
        let hosting = NSHostingView(rootView: view)
        hosting.layoutSubtreeIfNeeded()
        let size = hosting.fittingSize

        let panel = OverlayPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.contentView = hosting
        panel.onEscape = { [weak self] in self?.dismissNow(actions.dismiss) }
        panel.onSpace = { [weak self] in self?.toggleQuickLook() }
        panel.previewSource = self

        let screen = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        panel.setFrame(
            NSRect(x: screen.maxX - size.width - 16, y: screen.minY + 16, width: size.width, height: size.height),
            display: true
        )
        self.panel = panel
        self.dismissAction = actions.dismiss
        panel.makeKeyAndOrderFront(nil)
        restartTimeout()
    }

    private var dismissAction: (() -> Void)?

    /// Escape, the timeout, or the app moving on: the overlay goes and the take is kept.
    private func dismissNow(_ dismiss: () -> Void) {
        guard panel != nil else { return }
        close()
        dismiss()
    }

    private func close() {
        dismiss(reportingDismissal: false)
    }

    /// Take the panel down. With `reportingDismissal` the coordinator is told (the file is kept);
    /// without, the caller already reported an outcome.
    func dismiss(reportingDismissal: Bool = true) {
        timeoutTask?.cancel()
        timeoutTask = nil
        if QLPreviewPanel.sharedPreviewPanelExists(), QLPreviewPanel.shared().isVisible { QLPreviewPanel.shared().orderOut(nil) }
        model?.player.pause()
        panel?.orderOut(nil)
        panel = nil
        model = nil
        let dismiss = dismissAction
        dismissAction = nil
        if reportingDismissal { dismiss?() }
    }

    private func restartTimeout() {
        timeoutTask?.cancel()
        timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.timeout))
            guard !Task.isCancelled, let self, let dismiss = dismissAction else { return }
            dismissNow(dismiss)
        }
    }

    private func flash(_ text: String) {
        model?.flash = text
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.2))
            if self?.model?.flash == text { self?.model?.flash = nil }
        }
    }

    private func confirmDelete() -> Bool {
        let alert = NSAlert()
        alert.messageText = "Delete this recording?"
        alert.informativeText = "The recording will be moved to the Trash."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Keep")
        WindowPresenter.activateApp()
        return alert.runModal() == .alertFirstButtonReturn
    }

    // MARK: - Quick Look (Space)

    private func toggleQuickLook() {
        guard let quickLook = QLPreviewPanel.shared() else { return }
        if quickLook.isVisible {
            quickLook.orderOut(nil)
        } else {
            quickLook.dataSource = self
            quickLook.delegate = self
            quickLook.makeKeyAndOrderFront(nil)
        }
        restartTimeout()
    }

    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        MainActor.assumeIsolated { model == nil ? 0 : 1 }
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        MainActor.assumeIsolated { model?.recording.file as NSURL? }
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        // Space in Quick Look closes it again, as in Finder.
        guard event.type == .keyDown, event.charactersIgnoringModifiers == " " else { return false }
        MainActor.assumeIsolated { panel.orderOut(nil) }
        return true
    }
}

/// A borderless panel that can take keys (for Escape and Space) and lends itself to Quick Look.
private final class OverlayPanel: NSPanel {
    var onEscape: (() -> Void)?
    var onSpace: (() -> Void)?
    weak var previewSource: PostRecordingOverlayController?

    override var canBecomeKey: Bool { true }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: onEscape?()          // Escape
        case 49: onSpace?()           // Space
        default: super.keyDown(with: event)
        }
    }

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            panel.dataSource = previewSource
            panel.delegate = previewSource
        }
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            panel.dataSource = nil
            panel.delegate = nil
        }
    }
}

@MainActor
@Observable
private final class PostRecordingModel {
    let recording: PendingRecording
    let player: AVQueuePlayer
    private let looper: AVPlayerLooper
    var name: String
    var flash: String?
    let fileSize: Int64?

    init(recording: PendingRecording) {
        self.recording = recording
        let item = AVPlayerItem(url: recording.file)
        let player = AVQueuePlayer()
        player.isMuted = true
        looper = AVPlayerLooper(player: player, templateItem: item)
        self.player = player
        name = recording.file.deletingPathExtension().lastPathComponent
        fileSize = (try? FileManager.default.attributesOfItem(atPath: recording.file.path)[.size] as? NSNumber)?.int64Value
        player.play()
    }

    var durationText: String {
        let total = Int(recording.duration.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    var sizeText: String {
        guard let fileSize else { return "" }
        return ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file)
    }
}

private struct PostRecordingOverlayView: View {
    @Bindable var model: PostRecordingModel
    let copy: () -> Void
    let save: () -> Void
    let delete: () -> Void
    let quickLook: () -> Void
    let openEditor: (() -> Void)?
    let trim: (() -> Void)?
    let touched: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VideoPlayer(player: model.player)
                .frame(width: 280, height: 158)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(alignment: .bottomTrailing) {
                    Text("\(model.durationText) · \(model.sizeText)")
                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(.black.opacity(0.55), in: Capsule())
                        .foregroundStyle(.white)
                        .padding(6)
                }
                .overlay {
                    if let flash = model.flash {
                        Text(flash).font(.headline).padding(8)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                    }
                }
                // Story 34: the preview drags out as the file itself.
                .onDrag { NSItemProvider(contentsOf: model.recording.file) ?? NSItemProvider() }
                .contextMenu { menuItems }
                .help("Drag into another app · Space for Quick Look")

            HStack(spacing: 4) {
                TextField("Name", text: $model.name)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                    .onSubmit(save)
                Text(".\(model.recording.file.pathExtension)")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }

            HStack(spacing: 4) {
                button("Copy", systemImage: "doc.on.doc", action: copy)
                button("Save", systemImage: "square.and.arrow.down", action: save)
                button("Editor", systemImage: "slider.horizontal.3", action: openEditor)
                button("Trim", systemImage: "scissors", action: trim)
                Spacer(minLength: 0)
                button("Delete", systemImage: "trash", action: delete)
            }
        }
        .padding(10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .fixedSize()
        .onHover { _ in touched() }
    }

    @ViewBuilder private var menuItems: some View {
        Button("Copy File", action: copy)
        Button("Save", action: save)
        if let openEditor { Button("Open Video Editor", action: openEditor) }
        if let trim { Button("Trim…", action: trim) }
        Button("Quick Look", action: quickLook)
        Divider()
        Button("Delete", role: .destructive, action: delete)
    }

    /// A `nil` action is a feature that has not landed (video editor, trim — R14): shown, disabled.
    private func button(_ title: String, systemImage: String, action: (() -> Void)?) -> some View {
        Button(action: action ?? {}) {
            Label(title, systemImage: systemImage)
                .labelStyle(.iconOnly)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 28, height: 24)
        }
        .buttonStyle(.plain)
        .disabled(action == nil)
        .help(action == nil ? "\(title) — coming with the video editor" : title)
    }
}
