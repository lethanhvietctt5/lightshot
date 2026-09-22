import Foundation

/// Which container a recording ends up in — the Start Video / Start GIF choice (story 8).
public enum RecordingOutputKind: String, CaseIterable, Codable, Sendable {
    case video
    case gif
}

/// The video encoder a recording is written with (open decision 2: H.264 default, HEVC optional).
public enum VideoCodec: String, CaseIterable, Codable, Sendable {
    case h264
    case hevc
}

/// Caps the recording's longest edge so a Retina display doesn't produce a 5K file by default.
public enum MaxResolution: String, CaseIterable, Codable, Sendable {
    case original
    case p1080
    case p720

    /// The longest-edge cap in pixels, or `nil` for the native size.
    public var maxLongestEdge: Int? {
        switch self {
        case .original: return nil
        case .p1080: return 1920
        case .p720: return 1280
        }
    }
}

/// Encoder settings for an MP4 recording (story 40).
public struct VideoSettings: Equatable, Codable, Sendable {
    /// The encoder the writer is configured with.
    public var codec: VideoCodec
    /// Frames per second the stream is sampled at; one of `fpsChoices`.
    public var fps: Int
    /// Longest-edge cap applied after any Retina scaling.
    public var maxResolution: MaxResolution
    /// Write Retina captures at 1x (halve each edge on a 2x display) to keep files small.
    public var scaleRetinaTo1x: Bool

    public init(codec: VideoCodec, fps: Int, maxResolution: MaxResolution, scaleRetinaTo1x: Bool) {
        self.codec = codec
        self.fps = fps
        self.maxResolution = maxResolution
        self.scaleRetinaTo1x = scaleRetinaTo1x
    }

    /// H.264 at 30 fps, native resolution — the shipped default.
    public static let standard = VideoSettings(codec: .h264, fps: 30, maxResolution: .original, scaleRetinaTo1x: false)

    /// The frame rates the settings window offers (open decision 2).
    public static let fpsChoices = [10, 15, 30, 60]
}

/// Conversion settings for a GIF recording (story 37). The session still records MP4 first; these
/// drive the conversion afterwards (R13).
public struct GIFSettings: Equatable, Codable, Sendable {
    public var fps: Int
    /// Palette/dither quality, `0...1`.
    public var quality: Double
    /// Maximum output width in pixels, or `nil` to keep the recording's width.
    public var maxWidth: Int?
    /// Apply frame differencing to shrink the file.
    public var optimize: Bool

    public init(fps: Int, quality: Double, maxWidth: Int?, optimize: Bool) {
        self.fps = fps
        self.quality = min(max(quality, 0), 1)
        self.maxWidth = maxWidth
        self.optimize = optimize
    }

    /// CleanShot's defaults: 15 fps, 800 px wide, optimised.
    public static let standard = GIFSettings(fps: 15, quality: 0.8, maxWidth: 800, optimize: true)
}

/// What a recording is encoded to, fully specified.
public enum RecordingOutput: Equatable, Sendable {
    case video(VideoSettings)
    case gif(GIFSettings)

    public var kind: RecordingOutputKind {
        switch self {
        case .video: return .video
        case .gif: return .gif
        }
    }
}

/// An audio or camera input choice for one recording: off, or a device — `nil` id meaning the
/// system default device, so the toolbar toggle can turn a source on without a picker having
/// been opened.
public enum InputDeviceSelection: Equatable, Sendable {
    case off
    case device(id: String?)

    public var isOn: Bool {
        if case .device = self { return true }
        return false
    }
}

/// The immutable, fully-resolved configuration one recording session runs with (spec 0006).
///
/// Built once per recording by `resolve(region:output:defaults:overrides:)` and never edited
/// afterwards, so the recorder, the compositor and the post-recording flow all read one value.
public struct RecordingOptions: Equatable, Sendable {
    /// What is recorded: a rect, a window, or a whole display (stories 3–6).
    public var region: CaptureRegion
    /// MP4 or GIF, with the encoder/conversion settings it runs with (stories 37, 40).
    public var output: RecordingOutput
    /// Narration input (story 20), or off.
    public var microphone: InputDeviceSelection
    /// Record what other apps play (story 21).
    public var computerAudio: Bool
    /// The webcam bubble's source (story 26), or off.
    public var camera: InputDeviceSelection
    /// Draw a highlight at the pointer and animate clicks (story 29).
    public var highlightClicks: Bool
    /// Draw the keystroke overlay (story 30).
    public var showKeystrokes: Bool
    /// Draw the cursor into the frames (story 19).
    public var showCursor: Bool
    /// Seconds of 3-2-1 before recording starts (story 10); `0` starts immediately.
    public var countdownSeconds: Int

    public init(
        region: CaptureRegion,
        output: RecordingOutput,
        microphone: InputDeviceSelection = .off,
        computerAudio: Bool = false,
        camera: InputDeviceSelection = .off,
        highlightClicks: Bool = false,
        showKeystrokes: Bool = false,
        showCursor: Bool = true,
        countdownSeconds: Int = 0
    ) {
        self.region = region
        self.output = output
        self.microphone = microphone
        self.computerAudio = computerAudio
        self.camera = camera
        self.highlightClicks = highlightClicks
        self.showKeystrokes = showKeystrokes
        self.showCursor = showCursor
        self.countdownSeconds = max(0, countdownSeconds)
    }

    public var hasCountdown: Bool { countdownSeconds > 0 }

    /// Merge the Settings-owned defaults with the per-recording toggles from the recorder toolbar.
    /// Overrides win (story 9); anything the toolbar left alone comes from `defaults`. `output` is
    /// always per recording — it is which Start button was pressed — so it is a parameter, not an
    /// override.
    public static func resolve(
        region: CaptureRegion,
        output: RecordingOutputKind,
        defaults: RecordingDefaults,
        overrides: RecordingOverrides = .none
    ) -> RecordingOptions {
        let microphoneOn = overrides.microphone ?? defaults.recordMicrophone
        let cameraOn = overrides.camera ?? defaults.recordCamera
        return RecordingOptions(
            region: region,
            output: output == .video ? .video(defaults.video) : .gif(defaults.gif),
            microphone: microphoneOn ? .device(id: defaults.microphoneDeviceID) : .off,
            computerAudio: overrides.computerAudio ?? defaults.recordComputerAudio,
            camera: cameraOn ? .device(id: defaults.cameraDeviceID) : .off,
            highlightClicks: overrides.highlightClicks ?? defaults.highlightClicks,
            showKeystrokes: overrides.showKeystrokes ?? defaults.showKeystrokes,
            showCursor: defaults.showCursor,
            countdownSeconds: defaults.countdownEnabled ? defaults.countdownSeconds : 0
        )
    }
}

/// The Settings-owned baseline for every recording (story 40). `SettingsStore` persists these;
/// the recorder toolbar seeds its toggles from them and overrides per recording.
public struct RecordingDefaults: Equatable, Codable, Sendable {
    public var video: VideoSettings
    public var gif: GIFSettings
    public var recordMicrophone: Bool
    /// `nil` means the system default input.
    public var microphoneDeviceID: String?
    public var recordComputerAudio: Bool
    public var recordCamera: Bool
    /// `nil` means the system default camera.
    public var cameraDeviceID: String?
    public var highlightClicks: Bool
    public var showKeystrokes: Bool
    public var showCursor: Bool
    public var countdownEnabled: Bool
    public var countdownSeconds: Int

    public init(
        video: VideoSettings = .standard,
        gif: GIFSettings = .standard,
        recordMicrophone: Bool = false,
        microphoneDeviceID: String? = nil,
        recordComputerAudio: Bool = false,
        recordCamera: Bool = false,
        cameraDeviceID: String? = nil,
        highlightClicks: Bool = false,
        showKeystrokes: Bool = false,
        showCursor: Bool = true,
        countdownEnabled: Bool = false,
        countdownSeconds: Int = 3
    ) {
        self.video = video
        self.gif = gif
        self.recordMicrophone = recordMicrophone
        self.microphoneDeviceID = microphoneDeviceID
        self.recordComputerAudio = recordComputerAudio
        self.recordCamera = recordCamera
        self.cameraDeviceID = cameraDeviceID
        self.highlightClicks = highlightClicks
        self.showKeystrokes = showKeystrokes
        self.showCursor = showCursor
        self.countdownEnabled = countdownEnabled
        self.countdownSeconds = max(0, countdownSeconds)
    }

    /// The shipped defaults. The countdown is off until its overlay and sound exist (R4) — a
    /// silent three-second wait would read as the hotkey not working.
    public static let standard = RecordingDefaults()
}

/// Per-recording toggles from the recorder toolbar (stories 8–9): exactly the five the toolbar
/// offers — microphone, computer audio, camera, click highlighting, keystrokes. `nil` means "as in
/// Settings". A toggle flipped here changes only this recording, never the persisted default;
/// cursor visibility and the countdown are Settings-only (stories 10, 19) and have no override.
public struct RecordingOverrides: Equatable, Sendable {
    public var microphone: Bool?
    public var computerAudio: Bool?
    public var camera: Bool?
    public var highlightClicks: Bool?
    public var showKeystrokes: Bool?

    public init(
        microphone: Bool? = nil,
        computerAudio: Bool? = nil,
        camera: Bool? = nil,
        highlightClicks: Bool? = nil,
        showKeystrokes: Bool? = nil
    ) {
        self.microphone = microphone
        self.computerAudio = computerAudio
        self.camera = camera
        self.highlightClicks = highlightClicks
        self.showKeystrokes = showKeystrokes
    }

    /// No overrides — every value comes from Settings.
    public static let none = RecordingOverrides()
}
