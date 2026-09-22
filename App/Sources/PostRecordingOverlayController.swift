import AppKit
import AVFoundation
import Quartz
import SwiftUI
import LightshotKit

/// The post-recording overlay (spec 0006, stories 32–34; CleanShot's Quick Access Overlay): a
/// small panel in the screen's bottom-right corner with a looping, muted preview of the take, its
/// duration and size, a name to edit, and the after-recording actions. The take is still in the
/// scratch directory while this is up; the `AppCoordinator` owns it and decides where it goes
/// from the action the panel reports.
///
/// A thin OS wrapper (no unit tests): placement, lifetime, keys (Escape dismisses, Space opens
/// Quick Look), the timeout, and the drag-out (the preview is a file drag source).
@MainActor
final class PostRecordingOverlayController: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    /// What the panel can ask of the coordinator. Each takes the name in the Rename field (the
    /// file's own name when untouched) and reports whether the take is settled — `false` means
    /// the take is still pending, so the panel stays up.
    struct Actions {
        let copy: (String) -> Bool
        let save: (String) -> Bool
        let delete: () -> Bool
        /// The overlay went away without a decision: keep the file.
        let dismiss: (String) -> Void
        /// Save under the name, then open the video editor (story 35) — both the Editor and the
        /// Trim buttons lead there; `nil` when the take cannot be edited (a GIF).
        let editor: ((String) -> Bool)?
    }

    /// How long the overlay stays up untouched before it dismisses itself (and the file is kept).
    static let timeout: TimeInterval = 20

    private var panel: NSPanel?
    private var model: PostRecordingModel?
    private var actions: Actions?
    private var timeoutTask: Task<Void, Never>?
    private var keyMonitor: Any?

    func present(_ recording: PendingRecording, actions: Actions) {
        // A previous overlay still up means the coordinator already settled that take (a new take
        // saves a pending one before it starts), so this only takes the old panel down.
        close()
        let model = PostRecordingModel(recording: recording)
        self.model = model
        self.actions = actions

        let view = PostRecordingOverlayView(
            model: model,
            showsEditorActions: recording.kind == .video,
            copy: { [weak self] in self?.settle { $0.copy(model.name) } },
            save: { [weak self] in self?.settle { $0.save(model.name) } },
            delete: { [weak self] in self?.deleteAfterConfirming() },
            quickLook: { [weak self] in self?.toggleQuickLook() },
            // A GIF cannot be trimmed or edited in v1 (spec: the overlay hides both for a GIF).
            editor: recording.kind == .gif ? nil : actions.editor.map { open in { [weak self] in self?.settle { _ in open(model.name) } } },
            touched: { [weak self] in self?.restartTimeout() }
        )
        let hosting = NSHostingView(rootView: view)
        hosting.layoutSubtreeIfNeeded()
        let size = hosting.fittingSize

        let panel = KeyablePanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .screenSaver
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.contentView = hosting
        panel.previewSource = self

        let screen = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        panel.setFrame(
            NSRect(x: screen.maxX - size.width - 16, y: screen.minY + 16, width: size.width, height: size.height),
            display: true
        )
        self.panel = panel
        WindowPresenter.activateApp()
        panel.makeKeyAndOrderFront(nil)
        installKeyMonitor(for: panel)
        restartTimeout()
    }

    // MARK: - Outcomes

    /// Run an action that may settle the take; the panel closes only when it did.
    private func settle(_ action: (Actions) -> Bool) {
        guard let actions else { return }
        if action(actions) { close() } else { restartTimeout() }
    }

    /// Escape, the timeout: the overlay goes and the take is kept under the typed name.
    private func dismissKeepingFile() {
        guard let actions, let model else { return }
        let name = model.name
        close()
        actions.dismiss(name)
    }

    private func deleteAfterConfirming() {
        // The modal must not race the timeout: a fired timeout would save the file the user is
        // about to delete.
        timeoutTask?.cancel()
        let alert = NSAlert()
        alert.messageText = "Delete this recording?"
        alert.informativeText = "The recording will be moved to the Trash."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Keep")
        WindowPresenter.activateApp()
        if alert.runModal() == .alertFirstButtonReturn {
            settle { $0.delete() }
        } else {
            restartTimeout()
        }
    }

    /// Take the panel down without reporting anything.
    private func close() {
        timeoutTask?.cancel()
        timeoutTask = nil
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        if QLPreviewPanel.sharedPreviewPanelExists(), QLPreviewPanel.shared().isVisible { QLPreviewPanel.shared().orderOut(nil) }
        model?.player?.pause()
        panel?.orderOut(nil)
        panel = nil
        model = nil
        actions = nil
    }

    private func restartTimeout() {
        timeoutTask?.cancel()
        timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.timeout))
            guard !Task.isCancelled else { return }
            self?.dismissKeepingFile()
        }
    }

    // MARK: - Keys

    /// Escape and Space by a local monitor: the Rename field is usually first responder, and a
    /// field editor keeps both keys to itself (Space types, Escape cancels editing). Space is left
    /// to the field while it is being edited.
    private func installKeyMonitor(for panel: NSPanel) {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self, weak panel] event in
            guard let self, let panel, event.window === panel else { return event }
            switch event.keyCode {
            case 53:   // Escape
                dismissKeepingFile()
                return nil
            case 49 where !(panel.firstResponder is NSTextView):   // Space, not while typing
                toggleQuickLook()
                return nil
            default:
                return event
            }
        }
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
        guard event.type == .keyDown, event.keyCode == 49 else { return false }
        MainActor.assumeIsolated { panel.orderOut(nil) }
        return true
    }
}

/// A borderless panel that can take keys and lends itself to Quick Look.
private final class KeyablePanel: NSPanel {
    weak var previewSource: PostRecordingOverlayController?

    override var canBecomeKey: Bool { true }

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
    /// The looping preview for a video; a GIF animates itself in an image view.
    let player: AVQueuePlayer?
    private let looper: AVPlayerLooper?
    var name: String
    let fileSize: Int64?

    init(recording: PendingRecording) {
        self.recording = recording
        if recording.kind == .video {
            let player = AVQueuePlayer()
            player.isMuted = true
            looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: recording.file))
            self.player = player
            player.play()
        } else {
            player = nil
            looper = nil
        }
        name = recording.suggestedName ?? recording.file.deletingPathExtension().lastPathComponent
        fileSize = (try? FileManager.default.attributesOfItem(atPath: recording.file.path)[.size] as? NSNumber)?.int64Value
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
    /// A GIF cannot be trimmed or edited in v1, so those controls are not shown at all.
    let showsEditorActions: Bool
    let copy: () -> Void
    let save: () -> Void
    let delete: () -> Void
    let quickLook: () -> Void
    let editor: (() -> Void)?
    let touched: () -> Void
    @FocusState private var renaming: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            preview
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
                // Story 34: the preview drags out as the file itself (a copy; the original is still
                // saved when the overlay goes).
                .onDrag { NSItemProvider(object: model.recording.file as NSURL) }
                .contextMenu { menuItems }
                .help("Drag into another app · Space for Quick Look · Esc to keep and close")

            HStack(spacing: 4) {
                TextField("Name", text: $model.name)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                    .focused($renaming)
                    .onSubmit(save)
                    .onChange(of: model.name) { _, _ in touched() }
                Text(".\(model.recording.file.pathExtension)")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }

            HStack(spacing: 4) {
                button("Copy File", systemImage: "doc.on.doc", action: copy)
                button("Save", systemImage: "square.and.arrow.down", action: save)
                if showsEditorActions {
                    button("Open Video Editor", systemImage: "slider.horizontal.3", action: editor)
                    button("Trim", systemImage: "scissors", action: editor)
                }
                Spacer(minLength: 0)
                button("Delete", systemImage: "trash", action: delete)
            }
        }
        .padding(10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .fixedSize()
        .onHover { _ in touched() }
    }

    @ViewBuilder private var preview: some View {
        if let player = model.player {
            LoopingPlayerView(player: player)
        } else {
            AnimatedImageView(url: model.recording.file)
        }
    }

    /// The right-click menu mirrors the buttons (story 32), with the same disabled entries.
    @ViewBuilder private var menuItems: some View {
        Button("Copy File", action: copy)
        Button("Save", action: save)
        Button("Rename") { renaming = true }
        if showsEditorActions {
            Button("Open Video Editor", action: editor ?? {}).disabled(editor == nil)
            Button("Trim…", action: editor ?? {}).disabled(editor == nil)
        }
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

/// A GIF plays itself: `NSImageView` animates a multi-frame image (story 37's "loops in Preview").
private struct AnimatedImageView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> NSImageView {
        let view = NSImageView()
        view.imageScaling = .scaleProportionallyUpOrDown
        view.animates = true
        view.image = NSImage(contentsOf: url)
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.black.cgColor
        return view
    }

    func updateNSView(_ view: NSImageView, context: Context) {}
}

/// A bare `AVPlayerLayer`: no transport controls to swallow the drag that starts on the preview.
private struct LoopingPlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> PlayerLayerView {
        let view = PlayerLayerView()
        view.playerLayer.player = player
        return view
    }

    func updateNSView(_ view: PlayerLayerView, context: Context) {
        view.playerLayer.player = player
    }

    final class PlayerLayerView: NSView {
        let playerLayer = AVPlayerLayer()

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            playerLayer.videoGravity = .resizeAspectFill
            playerLayer.backgroundColor = NSColor.black.cgColor
            layer?.addSublayer(playerLayer)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { nil }

        override func layout() {
            super.layout()
            playerLayer.frame = bounds
        }
    }
}
