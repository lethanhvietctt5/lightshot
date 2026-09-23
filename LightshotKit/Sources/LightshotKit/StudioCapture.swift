import Foundation

/// Collects a studio take's input (spec 0007, story 1) on the take's own clock: **source seconds**
/// run from the first frame and skip paused stretches, exactly as the screen movie's timeline
/// does, so a sample at `t` lines up with the movie's frame at `t`. Points arrive in screen points
/// and are stored relative to the recorded region. Host times are whatever clock the recorder
/// stamps frames and events with — they only need to agree with each other.
public struct StudioInputRecorder: Sendable {
    private let regionOrigin: Point
    private let regionSize: Size
    private var startTime: Double?
    private var pausedAt: Double?
    private var pausedTotal = 0.0
    /// Where the pointer is now (region points), even before the take starts or while paused.
    private var lastPointer: Point?
    private var samples: [TimedPoint] = []
    private var clicks: [TimedPoint] = []
    private var keys: [TimedKeyEvent] = []

    public init(regionOrigin: Point, regionSize: Size) {
        self.regionOrigin = regionOrigin
        self.regionSize = regionSize
    }

    /// The first frame arrived: source time zero. Later calls are ignored.
    /// Whether the screen movie has the cursor drawn in (an ordinary take); see `StudioInput.cursorInVideo`.
    public var cursorInVideo = false

    public mutating func start(at hostTime: Double) {
        guard startTime == nil else { return }
        startTime = hostTime
        if let lastPointer { samples.append(TimedPoint(time: 0, point: lastPointer)) }
    }

    public mutating func pause(at hostTime: Double) {
        guard startTime != nil, pausedAt == nil else { return }
        pausedAt = hostTime
    }

    public mutating func resume(at hostTime: Double) {
        guard let pausedAt else { return }
        pausedTotal += max(0, hostTime - pausedAt)
        self.pausedAt = nil
        // The pointer may have moved while paused; the take continues from where it is now.
        if let lastPointer, let time = sourceTime(at: hostTime) { samples.append(TimedPoint(time: time, point: lastPointer)) }
    }

    /// The source time of a host time, or `nil` before the first frame or while paused.
    public func sourceTime(at hostTime: Double) -> Double? {
        guard let startTime, pausedAt == nil, hostTime >= startTime else { return nil }
        return max(0, hostTime - startTime - pausedTotal)
    }

    public mutating func record(_ event: InputEvent, at hostTime: Double) {
        let time = sourceTime(at: hostTime)
        switch event {
        case let .pointer(.moved(p)):
            let point = relative(p)
            lastPointer = point
            if let time { samples.append(TimedPoint(time: time, point: point)) }
        case let .pointer(.down(p)):
            let point = relative(p)
            lastPointer = point
            if let time {
                samples.append(TimedPoint(time: time, point: point))
                clicks.append(TimedPoint(time: time, point: point))
            }
        case let .key(key):
            if let time { keys.append(TimedKeyEvent(time: time, event: key)) }
        }
    }

    private func relative(_ p: Point) -> Point { Point(x: p.x - regionOrigin.x, y: p.y - regionOrigin.y) }

    public func finish() -> StudioInput {
        StudioInput(regionSize: regionSize, samples: samples, clicks: clicks, keys: keys, cursorInVideo: cursorInVideo)
    }
}

/// Where a studio take's side files sit next to its screen movie in scratch (spec 0007): the
/// recorder writes them, the project store collects them.
public enum StudioTake {
    public static func inputURL(forScreen screen: URL) -> URL {
        screen.deletingPathExtension().appendingPathExtension("input.json")
    }

    public static func cameraURL(forScreen screen: URL) -> URL {
        screen.deletingPathExtension().appendingPathExtension("camera.mov")
    }

    /// Beside a take rendered for sharing (S8 / LIG-57): the path of the studio project it came
    /// from, so opening it in the editor opens the editable project.
    public static func projectLinkURL(forScreen screen: URL) -> URL {
        screen.deletingPathExtension().appendingPathExtension("lightshot-project")
    }

    /// The files that travel with a take through history: its input data and its project link.
    public static func sidecars(forScreen screen: URL) -> [URL] {
        [inputURL(forScreen: screen), projectLinkURL(forScreen: screen)]
    }

    /// Link a rendered take to its project.
    public static func writeProjectLink(_ project: StudioProject, forScreen screen: URL) throws {
        try Data(project.url.path.utf8).write(to: projectLinkURL(forScreen: screen), options: .atomic)
    }

    /// The project a take was rendered from, when the link and the folder both still exist.
    public static func linkedProjectURL(forScreen screen: URL) -> URL? {
        guard let data = try? Data(contentsOf: projectLinkURL(forScreen: screen)),
              let path = String(data: data, encoding: .utf8), !path.isEmpty else { return nil }
        // Spelled like the store spells project URLs (no trailing slash), so they compare equal.
        let url = URL(fileURLWithPath: path, isDirectory: false)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}

/// One studio project on disk (spec 0007, stories 3–4): a folder holding the take and its edits.
public struct StudioProject: Equatable, Sendable {
    public let url: URL

    public var name: String { url.deletingPathExtension().lastPathComponent }
    public var screenURL: URL { url.appendingPathComponent(StudioProjectStore.screenFile) }
    public var inputURL: URL { url.appendingPathComponent(StudioProjectStore.inputFile) }
    public var editsURL: URL { url.appendingPathComponent(StudioProjectStore.editsFile) }
    public var transcriptURL: URL { url.appendingPathComponent(StudioProjectStore.transcriptFile) }
    /// The camera movie, when the take recorded one.
    public var cameraURL: URL? {
        let url = url.appendingPathComponent(StudioProjectStore.cameraFile)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
    /// A user image used as the background is copied in here (story 20).
    public func assetURL(named name: String) -> URL { url.appendingPathComponent(name) }
}

/// Studio projects under one directory (spec 0007): created from a finished studio take by
/// moving its files in, edits saved as `project.json`, the most recent listed for the menu bar.
/// Foundation only, like `HistoryStore`.
public struct StudioProjectStore: Sendable {
    public static let folderExtension = "lightshotstudio"
    static let screenFile = "screen.mp4"
    static let inputFile = "input.json"
    static let cameraFile = "camera.mov"
    static let editsFile = "project.json"
    static let transcriptFile = "transcript.json"

    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    /// Make a project named `name` (numbered if taken) from a take in scratch, moving the screen
    /// movie and any input / camera files beside it.
    public func create(fromTake screen: URL, name: String) throws -> StudioProject {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let base = name.isEmpty ? "Studio Take" : name
        var folder = directory.appendingPathComponent(base).appendingPathExtension(Self.folderExtension)
        var n = 2
        while fm.fileExists(atPath: folder.path) {
            folder = directory.appendingPathComponent("\(base) \(n)").appendingPathExtension(Self.folderExtension)
            n += 1
        }
        try fm.createDirectory(at: folder, withIntermediateDirectories: false)
        let project = StudioProject(url: folder)
        do {
            try fm.moveItem(at: screen, to: project.screenURL)
        } catch {
            try? fm.removeItem(at: folder)
            throw error
        }
        let input = StudioTake.inputURL(forScreen: screen)
        if fm.fileExists(atPath: input.path) { try? fm.moveItem(at: input, to: project.inputURL) }
        let camera = StudioTake.cameraURL(forScreen: screen)
        if fm.fileExists(atPath: camera.path) { try? fm.moveItem(at: camera, to: folder.appendingPathComponent(Self.cameraFile)) }
        return project
    }

    /// An existing project folder, or `nil` when it has no screen movie.
    public func open(_ url: URL) -> StudioProject? {
        let project = StudioProject(url: url)
        return FileManager.default.fileExists(atPath: project.screenURL.path) ? project : nil
    }

    public func loadInput(_ project: StudioProject) -> StudioInput? {
        guard let data = try? Data(contentsOf: project.inputURL) else { return nil }
        return try? JSONDecoder().decode(StudioInput.self, from: data)
    }

    public func loadTranscript(_ project: StudioProject) -> StudioTranscript? {
        guard let data = try? Data(contentsOf: project.transcriptURL) else { return nil }
        return try? JSONDecoder().decode(StudioTranscript.self, from: data)
    }

    public func save(_ transcript: StudioTranscript, to project: StudioProject) throws {
        try JSONEncoder().encode(transcript).write(to: project.transcriptURL, options: .atomic)
    }

    public func loadEdits(_ project: StudioProject) -> StudioEdits? {
        guard let data = try? Data(contentsOf: project.editsURL) else { return nil }
        return try? JSONDecoder().decode(StudioEdits.self, from: data)
    }

    public func save(_ edits: StudioEdits, to project: StudioProject) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(edits).write(to: project.editsURL, options: .atomic)
        // The folder's date is what "recent" sorts by.
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: project.url.path)
    }

    /// The most recently created or edited projects, newest first.
    public func recent(limit: Int) -> [StudioProject] {
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]
        ) else { return [] }
        let dated: [(URL, Date)] = urls.compactMap { listed in
            // Rebuilt from `directory`, so callers compare against the URLs `create` returned.
            let url = directory.appendingPathComponent(listed.lastPathComponent, isDirectory: false)
            guard url.pathExtension == Self.folderExtension, open(url) != nil else { return nil }
            let date = (try? listed.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return (url, date)
        }
        return dated.sorted { $0.1 > $1.1 }.prefix(max(0, limit)).map { StudioProject(url: $0.0) }
    }
}

/// Renders a studio take's project into a finished movie for sharing without the editor
/// (spec 0007, S8 / LIG-57): the app's implementation runs the Studio renderer and exporter.
/// Cancellation of the calling task abandons the render and removes the partial file.
@MainActor
public protocol StudioFlattening: AnyObject {
    func flatten(_ project: StudioProject, edits: StudioEdits, to output: URL, progress: @escaping @Sendable (Double) -> Void) async throws
}
