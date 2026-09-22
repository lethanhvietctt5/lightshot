import AppKit
import AVFoundation
import AVKit
import SwiftUI
import LightshotKit

/// The video editor window (spec 0006, stories 35–36; CleanShot's "Trim & Convert"): a player
/// with in / out trim handles, and a side panel for dimensions, quality, audio and the estimated
/// size. **Trim Only** cuts without re-encoding; **Trim & Convert** re-encodes. The result is a
/// new sibling file or replaces the original (kept as a backup beside it until the window closes,
/// so **Revert to Original** can put it back). Not the annotation editor.
@MainActor
final class VideoEditorController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var model: VideoEditorModel?

    func open(_ url: URL) {
        // A clip already open gives up its backup and any export before the next takes the window.
        model?.close()
        let model = VideoEditorModel(url: url)
        self.model = model
        let window = self.window ?? makeWindow()
        window.contentViewController = NSHostingController(rootView: VideoEditorView(model: model))
        window.title = url.lastPathComponent
        window.setContentSize(NSSize(width: 960, height: 600))
        window.center()
        self.window = window
        WindowPresenter.present(window, asRegularApp: true)
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.delegate = self
        return window
    }

    func windowWillClose(_ notification: Notification) {
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
    var audioChoice: AudioChoice = .unchanged
    var volume = 1.0
    var saveMode: SaveMode = .newFile
    var isExporting = false
    var progress = 0.0
    var message: String?
    var error: String?
    /// The original bytes, kept beside the file after a replace (story 36's Revert).
    private(set) var backup: URL?
    private var loadTask: Task<Void, Never>?
    private var exportTask: Task<Void, Never>?
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
                installTimeObserver()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func installTimeObserver() {
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 20), queue: .main) { [weak self] time in
            MainActor.assumeIsolated { self?.currentTime = CMTimeGetSeconds(time) }
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
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

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

private struct VideoEditorView: View {
    @Bindable var model: VideoEditorModel

    var body: some View {
        HSplitView {
            VStack(spacing: 8) {
                PlayerView(player: model.player)
                    .frame(minWidth: 480, minHeight: 270)
                TrimSlider(model: model)
                    .padding(.horizontal, 8)
                HStack {
                    Button("Set In") { model.setIn(model.currentTime) }
                    Button("Set Out") { model.setOut(model.currentTime) }
                    Spacer()
                    Text("\(Self.time(model.trim.start)) – \(Self.time(model.trim.end)) · \(Self.time(model.trim.length))")
                        .font(.system(size: 12).monospacedDigit()).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
            }
            .frame(minWidth: 500)

            Form {
                Section("Dimensions") {
                    Picker("Preset", selection: $model.preset) {
                        ForEach(DimensionPreset.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .onChange(of: model.preset) { _, _ in model.customWidth = ""; model.customHeight = "" }
                    HStack {
                        TextField("Width", text: $model.customWidth).frame(width: 70)
                        Text("×")
                        TextField("Height", text: $model.customHeight).frame(width: 70)
                        Text("→ \(Int(model.dimensions.width)) × \(Int(model.dimensions.height)) px")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
                Section("Video quality") {
                    Slider(value: $model.quality, in: 0...1)
                }
                Section("Audio") {
                    Picker("Audio", selection: $model.audioChoice) {
                        ForEach(VideoEditorModel.AudioChoice.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                    .disabled(!model.hasAudio)
                    if model.audioChoice == .volume {
                        Slider(value: $model.volume, in: 0...2) { Text("Volume") }
                    }
                    if !model.hasAudio { Text("This recording has no audio.").font(.system(size: 11)).foregroundStyle(.secondary) }
                }
                Section("Estimated file size") {
                    LabeledContent("Trim & Convert", value: model.estimateText)
                    LabeledContent("Trim Only", value: model.trimOnlyEstimateText)
                }
                Section {
                    Picker("Save", selection: $model.saveMode) {
                        Text("As a new video").tag(VideoEditorModel.SaveMode.newFile)
                        Text("Replace the original").tag(VideoEditorModel.SaveMode.replace)
                    }
                    HStack {
                        Button("Trim Only") { model.trimOnly() }
                            .disabled(model.isExporting)
                            .help("Cut without re-encoding: fast, same codec and quality.")
                        Button("Trim & Convert") { model.trimAndConvert() }
                            .disabled(model.isExporting)
                            .keyboardShortcut(.defaultAction)
                    }
                    if model.backup != nil {
                        Button("Revert to Original") { model.revert() }.disabled(model.isExporting)
                    }
                    if model.isExporting {
                        HStack {
                            ProgressView(value: model.progress)
                            Button("Cancel") { model.cancelExport() }
                        }
                    }
                    if let message = model.message { Text(message).font(.system(size: 11)).foregroundStyle(.secondary) }
                    if let error = model.error { Text(error).font(.system(size: 11)).foregroundStyle(.red) }
                }
            }
            .formStyle(.grouped)
            .frame(minWidth: 300, idealWidth: 340)
        }
    }

    static func time(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded(.down))
        let tenths = Int(((seconds - Double(total)) * 10).rounded())
        return String(format: "%d:%02d.%d", total / 60, total % 60, min(tenths, 9))
    }
}

/// Two handles over a bar: drag to set the in / out points; the player follows the handle.
private struct TrimSlider: View {
    @Bindable var model: VideoEditorModel

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let duration = max(model.trim.duration, 0.001)
            let startX = CGFloat(model.trim.start / duration) * width
            let endX = CGFloat(model.trim.end / duration) * width
            let playX = CGFloat(min(max(model.currentTime, 0), duration) / duration) * width
            // Drags are read in the slider's own space, not the 12-pt handle's, so a handle can be
            // dragged the whole width.
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.25)).frame(height: 24)
                RoundedRectangle(cornerRadius: 4).fill(Color.accentColor.opacity(0.35))
                    .frame(width: max(0, endX - startX), height: 24).offset(x: startX)
                Rectangle().fill(Color.primary).frame(width: 1, height: 28).offset(x: playX)
                handle.offset(x: startX - 6)
                    .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("trim")).onChanged { value in
                        let t = Double(value.location.x / width) * duration
                        model.setIn(t); model.seek(to: model.trim.start)
                    })
                handle.offset(x: endX - 6)
                    .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("trim")).onChanged { value in
                        let t = Double(value.location.x / width) * duration
                        model.setOut(t); model.seek(to: model.trim.end)
                    })
            }
            .coordinateSpace(name: "trim")
        }
        .frame(height: 28)
        .help("Drag the handles to set the in and out points")
    }

    private var handle: some View {
        RoundedRectangle(cornerRadius: 3).fill(Color.accentColor).frame(width: 12, height: 28)
    }
}

private struct PlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .inline
        view.showsFullScreenToggleButton = false
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        view.player = player
    }
}
