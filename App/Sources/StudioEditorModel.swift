import AppKit
import AVFoundation
import CoreImage
import LightshotKit
import Observation
import os

private let log = Logger(subsystem: "dev.lightshot.app", category: "studio-editor")

/// The Studio editor's state (spec 0007, S4): the undoable `StudioDocument`, the preview player
/// rendering it through `StudioCompositor`, selection, playback, autosave and export. Views read
/// it and call its commands; every edit goes through the document.
@MainActor
@Observable
final class StudioEditorModel {
    /// What the editor is editing: a studio project (autosaved), or a plain movie (edits live
    /// while the window is open; export makes a new file or replaces the original).
    enum Session {
        case project(StudioProject, StudioProjectStore)
        case file(URL)
    }

    enum Panel: String, CaseIterable {
        case background, cursor, zoom, captions, text, camera, keys, audio, output

        var title: String {
            switch self {
            case .background: return "Background"
            case .cursor: return "Cursor"
            case .zoom: return "Zoom"
            case .captions: return "Captions"
            case .text: return "Text"
            case .camera: return "Camera"
            case .keys: return "Keystrokes"
            case .audio: return "Audio"
            case .output: return "Output"
            }
        }

        var symbol: String {
            switch self {
            case .background: return "photo.fill"
            case .cursor: return "cursorarrow"
            case .zoom: return "plus.magnifyingglass"
            case .captions: return "captions.bubble"
            case .text: return "textformat"
            case .camera: return "person.crop.circle"
            case .keys: return "keyboard"
            case .audio: return "speaker.wave.2.fill"
            case .output: return "square.and.arrow.up"
            }
        }
    }

    enum Selection: Equatable {
        case clip(StudioClip.ID)
        case zoom(ZoomRegion.ID)
        case annotation(TextAnnotation.ID)
    }

    enum SaveMode: Hashable { case newFile, replace }

    let session: Session
    private(set) var document: StudioDocument
    private(set) var sources: StudioComposition.Sources?
    private(set) var input: StudioInput?
    private(set) var loadError: String?
    let player = AVPlayer()

    /// The preview's render state (canvas capped for speed; same proportions as the export).
    private(set) var previewState: StudioRenderState?
    var selection: Selection?
    var panel: Panel = .background
    /// Waiting for a click on the preview to set the selected zoom's focus (story 11).
    var isPickingFocus = false
    var timelineZoom: Double = 1
    /// A text field (caption line, annotation) has focus: single-key shortcuts must not fire.
    var isEditingText = false
    private(set) var isPlaying = false
    /// Output seconds.
    private(set) var currentTime: Double = 0
    /// Source filmstrip, evenly spaced over the source.
    private(set) var thumbnails: [CGImage] = []

    // Export
    var saveMode: SaveMode = .newFile
    private(set) var isExporting = false
    private(set) var progress: Double = 0
    private(set) var message: String?
    private(set) var error: String?
    private(set) var backup: URL?
    @ObservationIgnored var presentExport: (() -> Void)?
    /// Told once the movie is loaded, so the window can re-validate its Export button.
    @ObservationIgnored var onLoaded: (() -> Void)?
    /// Files a project's export into history and the save location (spec 0007, story 27).
    @ObservationIgnored var fileExport: ((URL, String?) async -> URL?)?
    /// Asks for Speech Recognition through the app's permission gate (round 2, story 29).
    @ObservationIgnored var ensureSpeechPermission: (() async -> Bool)?

    // Captions (round 2, stories 29–31)
    private(set) var transcript: StudioTranscript?
    private(set) var isTranscribing = false
    private(set) var transcriptionError: String?
    /// Indices into `transcript.words` picked in the transcript for cutting.
    var selectedWords: Set<Int> = []

    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var exportTask: Task<Void, Never>?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var builtClips: [StudioClip]?
    @ObservationIgnored private var builtAudio: AudioEdit?

    init(session: Session) {
        self.session = session
        switch session {
        case let .project(project, store):
            let edits = store.loadEdits(project) ?? StudioEdits(sourceDuration: 1, look: .studio)
            document = StudioDocument(edits: edits)
        case .file:
            document = StudioDocument(edits: StudioEdits(sourceDuration: 1, look: .plain))
        }
        loadTask = Task { await load() }
    }

    // MARK: - Derived

    var edits: StudioEdits { document.edits }
    var timeline: StudioTimeline { document.timeline }
    var duration: Double { timeline.outputDuration }
    var screenURL: URL {
        switch session {
        case let .project(project, _): return project.screenURL
        case let .file(url): return url
        }
    }
    var title: String {
        switch session {
        case let .project(project, _): return project.name
        case let .file(url): return url.lastPathComponent
        }
    }
    var isProject: Bool { if case .project = session { return true } else { return false } }
    var hasCursorData: Bool { !(input?.samples.isEmpty ?? true) }
    var hasClicks: Bool { !(input?.clicks.isEmpty ?? true) }
    var hasKeys: Bool { !(input?.keys.isEmpty ?? true) }
    var hasCamera: Bool { sources?.camera != nil }
    var hasAudio: Bool { !(sources?.screenAudio.isEmpty ?? true) }
    var sourceTime: Double { timeline.sourceTime(atOutput: currentTime) }

    var selectedZoom: ZoomRegion? {
        guard case let .zoom(id) = selection else { return nil }
        return edits.zooms.first { $0.id == id }
    }

    var selectedAnnotation: TextAnnotation? {
        guard case let .annotation(id) = selection else { return nil }
        return edits.annotations.first { $0.id == id }
    }

    var selectedClip: StudioClip? {
        guard case let .clip(id) = selection else { return nil }
        return edits.clips.first { $0.id == id }
    }

    /// The export canvas (story 25), for the Output panel.
    var outputSize: Size? {
        sources.map { CanvasLayout(sourceSize: $0.pixelSize, style: edits.canvas, resolution: edits.output.resolution).canvas }
    }

    var estimateText: String {
        guard let sources else { return "—" }
        let exportState = CanvasLayout(sourceSize: sources.pixelSize, style: edits.canvas, resolution: edits.output.resolution)
        let video = VideoBitRate.videoBitsPerSecond(size: exportState.canvas, fps: Double(edits.output.fps), quality: edits.output.quality)
        let audio = hasAudio && edits.audio != .remove ? VideoBitRate.audioBitsPerSecondPerChannel * (edits.audio == .mono ? 1 : 2) : 0
        var bytes = (video + audio) / 8 * duration + SizeEstimator.containerOverheadBytes
        if edits.output.format == .gif { bytes *= 1.6 }
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    // MARK: - Loading

    private func load() async {
        let cameraURL: URL?
        switch session {
        case let .project(project, store):
            input = store.loadInput(project)
            transcript = store.loadTranscript(project)
            cameraURL = project.cameraURL
        case .file:
            cameraURL = nil
        }
        do {
            let sources = try await StudioComposition.Sources.load(screen: screenURL, camera: cameraURL)
            self.sources = sources
            // First opening: the edits start from the movie's real length.
            switch session {
            case let .project(project, store):
                if store.loadEdits(project) == nil {
                    document = StudioDocument(edits: StudioEdits(sourceDuration: sources.duration, look: .studio))
                }
            case .file:
                document = StudioDocument(edits: StudioEdits(sourceDuration: sources.duration, look: .plain))
            }
            installTimeObserver()
            rebuild()
            loadThumbnails(sources)
            onLoaded?()
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func loadThumbnails(_ sources: StudioComposition.Sources) {
        let generator = AVAssetImageGenerator(asset: sources.screen)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 240, height: 240)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.5, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)
        let count = 40
        let times = (0..<count).map { CMTime(seconds: sources.duration * (Double($0) + 0.5) / Double(count), preferredTimescale: 600) }
        Task {
            var images: [CGImage] = []
            for await result in generator.images(for: times) {
                if let image = try? result.image { images.append(image) }
            }
            thumbnails = images
        }
    }

    /// The source thumbnail nearest a source time.
    func thumbnail(atSource time: Double) -> CGImage? {
        guard !thumbnails.isEmpty, let sources, sources.duration > 0 else { return nil }
        let i = Int(time / sources.duration * Double(thumbnails.count))
        return thumbnails[min(max(i, 0), thumbnails.count - 1)]
    }

    // MARK: - Preview

    /// Rebuild what the preview plays after an edit: the whole player item when the clips or the
    /// audio changed, otherwise only the video composition (cheap, keeps playback going).
    private func rebuild() {
        guard let sources else { return }
        var previewEdits = edits
        // The preview renders a smaller canvas of the same proportions.
        previewEdits.output.resolution = .p720
        let state = StudioRenderState(
            edits: previewEdits, input: input, sourceSize: sources.pixelSize,
            assetURL: { [session] name in Self.assetURL(name, session: session) }, context: StudioCompositor.context
        )
        previewState = state
        let renderSize = CGSize(width: state.layout.canvas.width, height: state.layout.canvas.height)
        do {
            let built = try StudioComposition.make(sources, state: state, renderSize: renderSize, fps: 30)
            if builtClips != edits.clips || builtAudio != edits.audio || player.currentItem == nil {
                let time = currentTime
                let item = AVPlayerItem(asset: built.asset)
                item.videoComposition = built.videoComposition
                item.audioMix = built.audioMix
                item.audioTimePitchAlgorithm = .spectral
                player.replaceCurrentItem(with: item)
                builtClips = edits.clips
                builtAudio = edits.audio
                seek(to: min(time, duration))
            } else if let item = player.currentItem {
                item.videoComposition = built.videoComposition
                item.audioMix = built.audioMix
                if !isPlaying { seek(to: currentTime) }
            }
        } catch {
            log.error("Preview rebuild failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    static func assetURL(_ name: String, session: Session) -> URL? {
        if name.hasPrefix("/") { return URL(fileURLWithPath: name) }
        if case let .project(project, _) = session { return project.assetURL(named: name) }
        return nil
    }

    private func installTimeObserver() {
        guard timeObserver == nil else { return }
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] time in
            MainActor.assumeIsolated { self?.playerMoved(to: CMTimeGetSeconds(time)) }
        }
    }

    private func playerMoved(to time: Double) {
        guard isPlaying else { return }
        currentTime = min(max(time, 0), duration)
        if time >= duration - 0.02 {
            player.pause()
            isPlaying = false
        }
    }

    func seek(to time: Double) {
        currentTime = min(max(time, 0), duration)
        player.seek(to: CMTime(seconds: currentTime, preferredTimescale: 6000), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func togglePlay() {
        if isPlaying {
            player.pause()
            isPlaying = false
        } else {
            if currentTime >= duration - 0.05 { seek(to: 0) }
            player.play()
            isPlaying = true
        }
    }

    func skipToStart() { seek(to: 0) }
    func skipToEnd() { seek(to: duration) }

    // MARK: - Commands

    /// Every edit funnels through here: apply, then refresh the preview and autosave.
    private func edit(_ change: (inout StudioDocument) -> Void) {
        let before = document.edits
        change(&document)
        guard document.edits != before else { return }
        if case let .zoom(id) = selection, !document.edits.zooms.contains(where: { $0.id == id }) { selection = nil }
        if case let .clip(id) = selection, !document.edits.clips.contains(where: { $0.id == id }) { selection = nil }
        if case let .annotation(id) = selection, !document.edits.annotations.contains(where: { $0.id == id }) { selection = nil }
        rebuild()
        scheduleSave()
    }

    func set<Value>(_ keyPath: WritableKeyPath<StudioEdits, Value>, _ value: Value) { edit { $0.set(keyPath, value) } }
    func beginChange() { document.beginChange() }
    func endChange() { edit { $0.endChange() } }
    func undo() { edit { $0.undo() } }
    func redo() { edit { $0.redo() } }
    var canUndo: Bool { document.canUndo }
    var canRedo: Bool { document.canRedo }

    func splitAtPlayhead() {
        edit { doc in
            if let id = doc.split(atOutput: currentTime) { selection = .clip(id) }
        }
    }

    func deleteSelection() {
        switch selection {
        case let .clip(id): edit { $0.deleteClip(id) }
        case let .zoom(id): edit { $0.removeZoom(id) }
        case let .annotation(id): edit { $0.removeAnnotation(id) }
        case nil: break
        }
    }

    func trimClip(_ id: StudioClip.ID, start: Double, end: Double) { edit { $0.trimClip(id, start: start, end: end) } }
    func setSpeed(_ id: StudioClip.ID, _ speed: Double) { edit { $0.setSpeed(id, speed) } }

    func addZoom() {
        edit { doc in
            if let id = doc.addZoom(atSource: sourceTime) {
                selection = .zoom(id)
                panel = .zoom
            }
        }
    }

    func autoZoom() {
        guard let clicks = input?.clicks else { return }
        edit { doc in
            if let first = doc.autoZoom(clicks: clicks).first {
                selection = .zoom(first)
                panel = .zoom
            }
        }
    }

    func moveZoom(_ id: ZoomRegion.ID, toStart start: Double) { edit { $0.moveZoom(id, toStart: start) } }
    func resizeZoom(_ id: ZoomRegion.ID, start: Double, end: Double) { edit { $0.resizeZoom(id, start: start, end: end) } }
    func setZoomScale(_ id: ZoomRegion.ID, _ scale: Double) { edit { $0.setZoomScale(id, scale) } }
    func setZoomFocus(_ id: ZoomRegion.ID, _ focus: ZoomFocus) { edit { $0.setZoomFocus(id, focus) } }

    /// A click on the preview while picking (story 11): the canvas point (0…1 of the preview) maps
    /// through the content rect and the current viewport to a point of the recorded frame.
    func pickFocus(atCanvas point: CGPoint) {
        guard isPickingFocus, let zoom = selectedZoom, let state = previewState else { return }
        let layout = state.layout
        let x = point.x * layout.canvas.width, y = point.y * layout.canvas.height
        let viewport = state.zoom.viewport(at: sourceTime)
        let nx = viewport.rect.minX + (x - layout.content.minX) / layout.content.width * viewport.rect.width
        let ny = viewport.rect.minY + (y - layout.content.minY) / layout.content.height * viewport.rect.height
        setZoomFocus(zoom.id, .point(Point(x: nx, y: ny)))
        isPickingFocus = false
    }

    /// Choose a background image (story 20): copied into the project so it travels with it.
    func chooseBackgroundImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        switch session {
        case let .project(project, _):
            let name = "background-\(UUID().uuidString.prefix(8)).\(url.pathExtension)"
            do {
                try FileManager.default.copyItem(at: url, to: project.assetURL(named: name))
                set(\.background, .image(fileName: name))
            } catch {
                self.error = error.localizedDescription
            }
        case .file:
            set(\.background, .image(fileName: url.path))
        }
    }

    // MARK: - Text annotations (round 2, story 32)

    func addAnnotation() {
        edit { doc in
            let id = doc.addAnnotation(atSource: sourceTime)
            selection = .annotation(id)
            panel = .text
        }
    }

    func moveAnnotation(_ id: TextAnnotation.ID, toStart start: Double) { edit { $0.moveAnnotation(id, toStart: start) } }
    func resizeAnnotation(_ id: TextAnnotation.ID, start: Double, end: Double) { edit { $0.resizeAnnotation(id, start: start, end: end) } }
    func updateAnnotation(_ id: TextAnnotation.ID, _ change: (inout TextAnnotation) -> Void) { edit { $0.updateAnnotation(id, change) } }

    /// The screen card in preview-view fractions (0…1 of the rendered canvas), for hit-testing drags.
    var contentFraction: CGRect? {
        guard let layout = previewState?.layout else { return nil }
        return CGRect(x: layout.content.minX / layout.canvas.width, y: layout.content.minY / layout.canvas.height,
                      width: layout.content.width / layout.canvas.width, height: layout.content.height / layout.canvas.height)
    }

    /// Move the selected annotation to a point of the preview (0…1 of the canvas), during a drag.
    func dragSelectedAnnotation(toCanvas point: CGPoint) {
        guard let annotation = selectedAnnotation, let content = contentFraction else { return }
        let center = Point(x: (point.x - content.minX) / content.width, y: (point.y - content.minY) / content.height)
        updateAnnotation(annotation.id) { $0.center = center }
    }

    // MARK: - Captions and transcript editing (round 2, stories 29–31)

    /// Transcribe the narration on this Mac and make caption lines from it.
    func transcribe() {
        guard !isTranscribing else { return }
        transcriptionError = nil
        isTranscribing = true
        Task {
            defer { isTranscribing = false }
            guard await ensureSpeechPermission?() ?? true else {
                transcriptionError = "Speech Recognition permission is needed to transcribe."
                return
            }
            do {
                let result = try await SpeechTranscriber.transcribe(movie: screenURL)
                transcript = result
                selectedWords = []
                if case let .project(project, store) = session { try? store.save(result, to: project) }
                set(\.captions.lines, CaptionBuilder.lines(from: result.words))
            } catch is CancellationError {
            } catch {
                transcriptionError = error.localizedDescription
            }
        }
    }

    /// Rebuild the caption lines from the transcript (drops hand edits to their text).
    func regenerateCaptions() {
        guard let transcript else { return }
        set(\.captions.lines, CaptionBuilder.lines(from: transcript.words))
    }

    func editCaption(_ id: CaptionLine.ID, text: String) { edit { $0.editCaption(id, text: text) } }

    /// Whether a word was cut from the output (its middle falls in a cut).
    func isCut(_ word: TranscriptWord) -> Bool {
        timeline.outputTime(atSource: (word.start + word.end) / 2) == nil
    }

    /// Cut the selected words (story 30): each contiguous run of selected words is one cut, all of
    /// them one undo step.
    func cutSelectedWords() {
        guard let words = transcript?.words, !selectedWords.isEmpty else { return }
        var runs: [[TranscriptWord]] = []
        var previous: Int?
        for index in selectedWords.sorted() where words.indices.contains(index) {
            if let previous, index == previous + 1 { runs[runs.count - 1].append(words[index]) } else { runs.append([words[index]]) }
            previous = index
        }
        document.beginChange()
        for run in runs { edit { $0.cut(words: run) } }
        endChange()
        selectedWords = []
    }

    /// Cut every pause longer than `minimumGap` seconds (story 31); returns how many.
    @discardableResult
    func removeSilences(minimumGap: Double) -> Int {
        guard let words = transcript?.words else { return 0 }
        var count = 0
        edit { count = $0.removeSilences(words: words, minimumGap: minimumGap) }
        return count
    }

    /// Jump the playhead to a word (if it survived the cuts).
    func seek(toWord word: TranscriptWord) {
        if let time = timeline.outputTime(atSource: word.start) { seek(to: time) }
    }

    // MARK: - Autosave (story 3)

    private func scheduleSave() {
        guard case let .project(project, store) = session else { return }
        saveTask?.cancel()
        let edits = document.edits
        saveTask = Task {
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            do { try store.save(edits, to: project) } catch {
                log.error("Autosave failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Flush a pending save now (window closing, app quitting).
    func saveNow() {
        guard case let .project(project, store) = session else { return }
        saveTask?.cancel()
        try? store.save(document.edits, to: project)
    }

    // MARK: - Export (stories 25–28)

    func export() {
        guard let sources, !isExporting else { return }
        error = nil
        message = nil
        isExporting = true
        progress = 0
        let state = StudioRenderState(
            edits: edits, input: input, sourceSize: sources.pixelSize,
            assetURL: { [session] name in Self.assetURL(name, session: session) }, context: StudioCompositor.context
        )
        let ext = edits.output.format == .gif ? "gif" : "mp4"
        let staging = screenURL.deletingLastPathComponent().appendingPathComponent(".lightshot-studio-export-\(UUID().uuidString).\(ext)")
        exportTask = Task {
            do {
                try await StudioExporter.export(sources, state: state, to: staging) { value in
                    Task { @MainActor in self.progress = value }
                }
                try await commit(staging)
            } catch is CancellationError {
                message = "Export cancelled."
            } catch {
                self.error = error.localizedDescription
            }
            try? FileManager.default.removeItem(at: staging)
            isExporting = false
        }
    }

    func cancelExport() { exportTask?.cancel() }

    private func commit(_ staging: URL) async throws {
        switch session {
        case .project:
            guard let fileExport else { return }
            if let saved = await fileExport(staging, title) {
                message = "Saved to \(saved.deletingLastPathComponent().lastPathComponent) as \(saved.lastPathComponent)."
                NSWorkspace.shared.activateFileViewerSelecting([saved])
            }
        case let .file(url):
            let fm = FileManager.default
            if saveMode == .newFile || staging.pathExtension != url.pathExtension {
                let destination = Self.uniqueSibling(of: url, suffix: " edited", pathExtension: staging.pathExtension)
                try fm.moveItem(at: staging, to: destination)
                message = "Saved as \(destination.lastPathComponent)."
            } else {
                if backup == nil {
                    let copy = url.deletingLastPathComponent().appendingPathComponent(".\(url.deletingPathExtension().lastPathComponent) original.\(url.pathExtension)")
                    try? fm.removeItem(at: copy)
                    try fm.copyItem(at: url, to: copy)
                    backup = copy
                }
                _ = try fm.replaceItemAt(url, withItemAt: staging)
                message = "Replaced the original. Revert to Original brings it back."
            }
        }
    }

    /// Put the backup back (plain-movie session).
    func revert() {
        guard case let .file(url) = session, let backup else { return }
        do {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: backup)
            self.backup = nil
            message = "Reverted to the original."
        } catch {
            self.error = error.localizedDescription
        }
    }

    static func uniqueSibling(of url: URL, suffix: String, pathExtension: String) -> URL {
        let base = url.deletingPathExtension().lastPathComponent + suffix
        let folder = url.deletingLastPathComponent()
        var candidate = folder.appendingPathComponent(base).appendingPathExtension(pathExtension)
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(base) \(n)").appendingPathExtension(pathExtension)
            n += 1
        }
        return candidate
    }

    /// The window is going away: stop playback and work, save, drop the backup.
    func close() {
        player.pause()
        isPlaying = false
        exportTask?.cancel()
        loadTask?.cancel()
        saveNow()
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        player.replaceCurrentItem(with: nil)
        if let backup { try? FileManager.default.removeItem(at: backup) }
        backup = nil
    }
}
