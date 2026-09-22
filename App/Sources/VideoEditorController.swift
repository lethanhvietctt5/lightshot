import AppKit
import AVFoundation
import SwiftUI
import LightshotKit

/// The video editor window (spec 0006, stories 35–36), laid out like CleanShot's studio editor
/// (LIG-43): a dark window whose toolbar carries the file name, an **Edited** marker and the
/// **Export** button; an icon rail and its panel (trim, size, quality, audio) on the left; the
/// preview with a transport row; and a timeline with a ruler, playhead, filmstrip and trim
/// handles. **Trim Only** cuts without re-encoding; **Trim & Convert** re-encodes. The result is a
/// new sibling file or replaces the original (kept as a backup beside it until the window closes,
/// so **Revert to Original** can put it back). Not the annotation editor.
@MainActor
final class VideoEditorController: NSObject, NSWindowDelegate, NSToolbarDelegate, NSToolbarItemValidation {
    private var window: NSWindow?
    private var model: VideoEditorModel?
    private var exportPopover: NSPopover?

    private static let exportItem = NSToolbarItem.Identifier("videoEditor.export")

    func open(_ url: URL) {
        // A clip already open gives up its backup and any export before the next takes the window.
        model?.close()
        let model = VideoEditorModel(url: url)
        model.presentExport = { [weak self] in self?.toggleExport() }
        self.model = model
        exportPopover?.close()
        exportPopover = nil
        let window = self.window ?? makeWindow()
        let hosting = NSHostingController(rootView: VideoEditorView(model: model))
        // The window keeps the size set below; the timeline and panels stretch to fill it.
        hosting.sizingOptions = []
        window.contentViewController = hosting
        window.title = url.lastPathComponent
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
        window.contentMinSize = NSSize(width: 900, height: 600)
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
        model?.source != nil
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
        guard let model, model.source != nil,
              let item = window?.toolbar?.items.first(where: { $0.itemIdentifier == Self.exportItem }) else { return }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.appearance = NSAppearance(named: .darkAqua)
        popover.contentViewController = NSHostingController(rootView: VideoEditorExportPanel(model: model))
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

    /// Quitting skips `windowWillClose`: drop the backup and cancel an export here instead.
    func prepareForTermination() {
        model?.close()
        model = nil
    }
}

/// The editor's state: the clip, the settings, the live estimate, and the export in flight.
@MainActor
@Observable
final class VideoEditorModel {
    enum SaveMode: String, CaseIterable { case newFile, replace }
    /// The rail's sections, in rail order.
    enum Panel: String, CaseIterable {
        case trim, size, quality, audio
        var title: String {
            switch self {
            case .trim: return "Trim"
            case .size: return "Size"
            case .quality: return "Quality"
            case .audio: return "Audio"
            }
        }
    }
    enum AudioChoice: String, CaseIterable {
        case unchanged, mute, volume, mono, remove
        var title: String {
            switch self {
            case .unchanged: return "Don't change"
            case .mute: return "Mute"
            case .volume: return "Change volume"
            case .mono: return "Convert to mono"
            case .remove: return "Remove the audio"
            }
        }
    }

    /// The file being edited; after a replace it is the same URL with new bytes.
    private(set) var url: URL
    private(set) var source: VideoExporter.Source?
    let player = AVPlayer()
    var trim = TrimRange(duration: 0)
    var preset: DimensionPreset = .original
    var customWidth = ""
    var customHeight = ""
    var quality = VideoBitRate.defaultQuality
    var audioChoice: AudioChoice = .unchanged { didSet { applyAudioToPreview() } }
    var volume = 1.0 { didSet { applyAudioToPreview() } }
    var saveMode: SaveMode = .newFile
    var panel: Panel = .trim
    /// Opens (or closes) the Export popover — the controller's, anchored to its toolbar item.
    @ObservationIgnored var presentExport: (() -> Void)?
    /// How far the timeline is stretched past the window's width (1 = the whole clip fits).
    var timelineZoom = 1.0
    private(set) var isPlaying = false
    /// Frames taken evenly across the clip for the timeline's filmstrip.
    private(set) var thumbnails: [CGImage] = []
    var isExporting = false
    var progress = 0.0
    var message: String?
    var error: String?
    /// The original bytes, kept beside the file after a replace (story 36's Revert).
    private(set) var backup: URL?
    private var loadTask: Task<Void, Never>?
    private var exportTask: Task<Void, Never>?
    private var thumbnailTask: Task<Void, Never>?
    private var timeObserver: Any?
    private(set) var currentTime: TimeInterval = 0

    init(url: URL) {
        self.url = url
        load()
    }

    private func load() {
        loadTask?.cancel()
        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let source = try await VideoExporter.inspect(url)
                guard !Task.isCancelled else { return }
                self.source = source
                trim = TrimRange(duration: source.duration)
                player.replaceCurrentItem(with: AVPlayerItem(url: url))
                currentTime = 0
                installTimeObserver()
                loadThumbnails(duration: source.duration)
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func installTimeObserver() {
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] time in
            MainActor.assumeIsolated { self?.playerMoved(to: CMTimeGetSeconds(time)) }
        }
    }

    /// Playback stops at the out point, so the preview plays the cut, not the whole clip.
    private func playerMoved(to seconds: TimeInterval) {
        currentTime = seconds
        isPlaying = player.rate != 0
        if isPlaying, seconds >= trim.end {
            player.pause()
            isPlaying = false
            seek(to: trim.end)
        }
    }

    private static let filmstripFrameCount = 40

    private func loadThumbnails(duration: TimeInterval) {
        thumbnailTask?.cancel()
        thumbnails = []
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 320, height: 320)
        let tolerance = CMTime(seconds: max(duration / Double(Self.filmstripFrameCount) / 2, 0.05), preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance
        let times = (0..<Self.filmstripFrameCount).map {
            CMTime(seconds: duration * (Double($0) + 0.5) / Double(Self.filmstripFrameCount), preferredTimescale: 600)
        }
        thumbnailTask = Task { [weak self] in
            var images: [CGImage] = []
            for await result in generator.images(for: times) {
                guard !Task.isCancelled else { return }
                if let image = try? result.image { images.append(image) }
            }
            self?.thumbnails = images
        }
    }

    // MARK: - Settings

    var dimensions: Size {
        guard let source else { return Size(width: 0, height: 0) }
        let w = Double(customWidth), h = Double(customHeight)
        if w != nil || h != nil { return VideoDimensions.size(width: w, height: h, source: source.size) }
        return VideoDimensions.size(for: preset, source: source.size)
    }

    var audio: AudioEdit {
        switch audioChoice {
        case .unchanged: return .unchanged
        case .mute: return .mute
        case .volume: return .volume(volume)
        case .mono: return .mono
        case .remove: return .remove
        }
    }

    var settings: VideoEditSettings {
        VideoEditSettings(trim: trim, dimensions: dimensions, quality: quality, audio: audio)
    }

    var hasAudio: Bool { (source?.audioChannels ?? 0) > 0 }

    /// The preview plays with the audio choice applied (mono is not previewed; the player cannot
    /// go above full volume).
    private func applyAudioToPreview() {
        player.isMuted = audioChoice == .mute || audioChoice == .remove
        player.volume = audioChoice == .volume ? Float(min(max(volume, 0), 1)) : 1
    }

    /// Any setting moved off the clip as recorded — the toolbar's **Edited** marker.
    var isEdited: Bool {
        guard source != nil else { return false }
        return !trim.isWholeClip || preset != .original || !customWidth.isEmpty || !customHeight.isEmpty
            || quality != VideoBitRate.defaultQuality || audioChoice != .unchanged
    }

    var estimateText: String {
        guard let source else { return "" }
        let bytes = SizeEstimator.estimatedBytes(settings: settings, fps: source.fps, audioChannels: source.audioChannels)
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    var trimOnlyEstimateText: String {
        guard let source else { return "" }
        return ByteCountFormatter.string(fromByteCount: Int64(SizeEstimator.estimatedTrimOnlyBytes(sourceBytes: source.bytes, trim: trim)), countStyle: .file)
    }

    func setIn(_ seconds: TimeInterval) { trim.setStart(seconds) }
    func setOut(_ seconds: TimeInterval) { trim.setEnd(seconds) }
    func seek(to seconds: TimeInterval) {
        currentTime = seconds
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func resetTrim() { trim = TrimRange(duration: trim.duration) }

    // MARK: - Transport

    /// Play the cut from the playhead — from the in point when the playhead is outside it.
    func togglePlay() {
        if player.rate != 0 {
            player.pause()
            isPlaying = false
            return
        }
        if currentTime < trim.start || currentTime >= trim.end - 0.05 { seek(to: trim.start) }
        player.play()
        isPlaying = true
    }

    func skipToStart() { seek(to: trim.start) }
    func skipToEnd() { seek(to: trim.end) }

    // MARK: - Exports (stories 35–36)

    func trimOnly() {
        guard let source else { return }
        let range = trim
        export { [weak self] output in
            try await VideoExporter.trimOnly(source.url, range: range, to: output) { progress in
                Task { @MainActor in self?.progress = progress }
            }
        }
    }

    func trimAndConvert() {
        guard let source else { return }
        let settings = self.settings
        export { [weak self] output in
            try await VideoExporter.convert(source, settings: settings, to: output) { progress in
                Task { @MainActor in self?.progress = progress }
            }
        }
    }

    private func export(_ run: @escaping (URL) async throws -> Void) {
        guard !isExporting else { return }
        isExporting = true
        progress = 0
        error = nil
        message = nil
        let staging = url.deletingLastPathComponent().appendingPathComponent(".lightshot-export-\(UUID().uuidString).mp4")
        exportTask = Task { [weak self] in
            defer { self?.isExporting = false }
            do {
                try await run(staging)
                guard let self else {
                    try? FileManager.default.removeItem(at: staging)
                    return
                }
                try commit(staging)
            } catch is CancellationError {
                try? FileManager.default.removeItem(at: staging)
            } catch {
                try? FileManager.default.removeItem(at: staging)
                self?.error = error.localizedDescription
            }
        }
    }

    func cancelExport() { exportTask?.cancel() }

    /// Where the export lands: a new sibling file, or the original's place (with the original kept
    /// as a backup for Revert — one backup, taken before the first replace).
    private func commit(_ staging: URL) throws {
        let fileManager = FileManager.default
        switch saveMode {
        case .newFile:
            // The editor keeps the original as its subject: further edits and Revert are about
            // the recording, never about a derivative.
            let destination = Self.uniqueSibling(of: url, suffix: " edited")
            try fileManager.moveItem(at: staging, to: destination)
            message = "Saved as \(destination.lastPathComponent)"
        case .replace:
            if backup == nil {
                let keep = Self.uniqueSibling(of: url, suffix: " original", hidden: true)
                try fileManager.copyItem(at: url, to: keep)
                backup = keep
            }
            _ = try fileManager.replaceItemAt(url, withItemAt: staging, backupItemName: nil, options: [])
            message = "Replaced \(url.lastPathComponent)"
            reload(url)
        }
    }

    /// Story 36: the original bytes come back over the replaced file.
    func revert() {
        guard let backup else { return }
        do {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: backup, backupItemName: nil, options: [])
            self.backup = nil
            message = "Reverted to the original"
            reload(url)
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func reload(_ url: URL) {
        self.url = url
        load()
    }

    /// The window closed: a backup is no longer needed.
    func close() {
        loadTask?.cancel()
        thumbnailTask?.cancel()
        exportTask?.cancel()
        player.pause()
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        if let backup { try? FileManager.default.removeItem(at: backup) }
        backup = nil
    }

    /// `name suffix.ext`, numbered if taken; hidden names get a leading dot.
    private static func uniqueSibling(of url: URL, suffix: String, hidden: Bool = false) -> URL {
        let base = (hidden ? "." : "") + url.deletingPathExtension().lastPathComponent + suffix
        return url.deletingLastPathComponent().appendingPathComponent(base).appendingPathExtension(url.pathExtension).uniqueForFileSystem()
    }
}
