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
    /// Gain applied to the narration, `0...2` (story 25); `1` is unity.
    public var microphoneVolume: Double
    /// Write one audio channel instead of two (story 25).
    public var monoAudio: Bool
    /// Gain applied to computer audio, `0...2` (story 25).
    public var computerAudioVolume: Double
    /// Microphone and computer audio on separate tracks instead of one mix (story 22).
    public var separateAudioTracks: Bool
    /// The webcam bubble's source (story 26), or off.
    public var camera: InputDeviceSelection
    /// Draw a highlight at the pointer and animate clicks (story 29).
    public var highlightClicks: Bool
    /// How the highlight looks when `highlightClicks` is on.
    public var clickHighlight: ClickHighlightSettings
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
        microphoneVolume: Double = 1,
        monoAudio: Bool = false,
        computerAudioVolume: Double = 1,
        separateAudioTracks: Bool = false,
        camera: InputDeviceSelection = .off,
        highlightClicks: Bool = false,
        clickHighlight: ClickHighlightSettings = .standard,
        showKeystrokes: Bool = false,
        showCursor: Bool = true,
        countdownSeconds: Int = 0
    ) {
        self.region = region
        self.output = output
        self.microphone = microphone
        self.computerAudio = computerAudio
        self.microphoneVolume = min(max(microphoneVolume, 0), 2)
        self.monoAudio = monoAudio
        self.computerAudioVolume = min(max(computerAudioVolume, 0), 2)
        self.separateAudioTracks = separateAudioTracks
        self.camera = camera
        self.highlightClicks = highlightClicks
        self.clickHighlight = clickHighlight
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
            microphoneVolume: defaults.microphoneVolume,
            monoAudio: defaults.monoAudio,
            computerAudioVolume: defaults.computerAudioVolume,
            separateAudioTracks: defaults.separateAudioTracks,
            camera: cameraOn ? .device(id: defaults.cameraDeviceID) : .off,
            highlightClicks: overrides.highlightClicks ?? defaults.highlightClicks,
            clickHighlight: defaults.clickHighlight,
            showKeystrokes: overrides.showKeystrokes ?? defaults.showKeystrokes,
            showCursor: defaults.showCursor,
            countdownSeconds: defaults.countdownEnabled ? defaults.countdownSeconds : 0
        )
    }
}

/// Where the recording controls pill sits on the screen (story 12).
public enum RecordingControlsPosition: String, CaseIterable, Codable, Sendable {
    case top
    case bottom
}

/// The Settings-owned baseline for every recording (story 40). `SettingsStore` persists these;
/// the recorder toolbar seeds its toggles from them and overrides per recording.
public struct RecordingDefaults: Equatable, Codable, Sendable {
    public var video: VideoSettings
    public var gif: GIFSettings
    public var recordMicrophone: Bool
    /// `nil` means the system default input.
    public var microphoneDeviceID: String?
    /// Narration gain, `0...2`; `1` is unity (story 25).
    public var microphoneVolume: Double
    /// Write mono audio (story 25).
    public var monoAudio: Bool
    public var recordComputerAudio: Bool
    /// Computer-audio gain, `0...2` (story 25).
    public var computerAudioVolume: Double
    /// "Record on separate tracks" instead of one mix (story 22).
    public var separateAudioTracks: Bool
    public var recordCamera: Bool
    /// `nil` means the system default camera.
    public var cameraDeviceID: String?
    public var highlightClicks: Bool
    /// Style, size, colour and click animation of the highlight (story 29).
    public var clickHighlight: ClickHighlightSettings
    public var showKeystrokes: Bool
    public var showCursor: Bool
    public var countdownEnabled: Bool
    public var countdownSeconds: Int
    /// Play the countdown ticks and the start / stop / pause sounds (story 10 and R4).
    public var playSounds: Bool
    /// Show the pause / stop / restart / discard pill while recording (story 12).
    public var showRecordingControls: Bool
    public var controlsPosition: RecordingControlsPosition
    /// Darken everything outside the recording area while recording (story 16).
    public var dimScreenWhileRecording: Bool
    /// Ask before restart / discard throw a take away (story 14); the alerts' "don't ask again"
    /// turns this off.
    public var confirmBeforeDiscard: Bool
    /// Show the elapsed time next to the stop glyph in the menu bar while recording (story 11).
    public var showRecordingTimeInMenuBar: Bool

    public init(
        video: VideoSettings = .standard,
        gif: GIFSettings = .standard,
        recordMicrophone: Bool = false,
        microphoneDeviceID: String? = nil,
        microphoneVolume: Double = 1,
        monoAudio: Bool = false,
        recordComputerAudio: Bool = false,
        computerAudioVolume: Double = 1,
        separateAudioTracks: Bool = false,
        recordCamera: Bool = false,
        cameraDeviceID: String? = nil,
        highlightClicks: Bool = false,
        clickHighlight: ClickHighlightSettings = .standard,
        showKeystrokes: Bool = false,
        showCursor: Bool = true,
        countdownEnabled: Bool = true,
        countdownSeconds: Int = 3,
        playSounds: Bool = true,
        showRecordingControls: Bool = true,
        controlsPosition: RecordingControlsPosition = .bottom,
        dimScreenWhileRecording: Bool = false,
        confirmBeforeDiscard: Bool = true,
        showRecordingTimeInMenuBar: Bool = true
    ) {
        self.video = video
        self.gif = gif
        self.recordMicrophone = recordMicrophone
        self.microphoneDeviceID = microphoneDeviceID
        self.microphoneVolume = min(max(microphoneVolume, 0), 2)
        self.monoAudio = monoAudio
        self.recordComputerAudio = recordComputerAudio
        self.computerAudioVolume = min(max(computerAudioVolume, 0), 2)
        self.separateAudioTracks = separateAudioTracks
        self.recordCamera = recordCamera
        self.cameraDeviceID = cameraDeviceID
        self.highlightClicks = highlightClicks
        self.clickHighlight = clickHighlight
        self.showKeystrokes = showKeystrokes
        self.showCursor = showCursor
        self.countdownEnabled = countdownEnabled
        self.countdownSeconds = max(0, countdownSeconds)
        self.playSounds = playSounds
        self.showRecordingControls = showRecordingControls
        self.controlsPosition = controlsPosition
        self.dimScreenWhileRecording = dimScreenWhileRecording
        self.confirmBeforeDiscard = confirmBeforeDiscard
        self.showRecordingTimeInMenuBar = showRecordingTimeInMenuBar
    }

    /// The shipped defaults: a 3-second countdown with sounds, everything else off.
    public static let standard = RecordingDefaults()

    /// Fields added later decode with their default when a stored blob lacks them, so a settings
    /// file written by an earlier build never silently resets to `.standard`.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            video: try c.decode(VideoSettings.self, forKey: .video),
            gif: try c.decode(GIFSettings.self, forKey: .gif),
            recordMicrophone: try c.decode(Bool.self, forKey: .recordMicrophone),
            microphoneDeviceID: try c.decodeIfPresent(String.self, forKey: .microphoneDeviceID),
            microphoneVolume: try c.decodeIfPresent(Double.self, forKey: .microphoneVolume) ?? 1,
            monoAudio: try c.decodeIfPresent(Bool.self, forKey: .monoAudio) ?? false,
            recordComputerAudio: try c.decode(Bool.self, forKey: .recordComputerAudio),
            computerAudioVolume: try c.decodeIfPresent(Double.self, forKey: .computerAudioVolume) ?? 1,
            separateAudioTracks: try c.decodeIfPresent(Bool.self, forKey: .separateAudioTracks) ?? false,
            recordCamera: try c.decode(Bool.self, forKey: .recordCamera),
            cameraDeviceID: try c.decodeIfPresent(String.self, forKey: .cameraDeviceID),
            highlightClicks: try c.decode(Bool.self, forKey: .highlightClicks),
            clickHighlight: try c.decodeIfPresent(ClickHighlightSettings.self, forKey: .clickHighlight) ?? .standard,
            showKeystrokes: try c.decode(Bool.self, forKey: .showKeystrokes),
            showCursor: try c.decode(Bool.self, forKey: .showCursor),
            countdownEnabled: try c.decode(Bool.self, forKey: .countdownEnabled),
            countdownSeconds: try c.decode(Int.self, forKey: .countdownSeconds),
            playSounds: try c.decodeIfPresent(Bool.self, forKey: .playSounds) ?? true,
            showRecordingControls: try c.decodeIfPresent(Bool.self, forKey: .showRecordingControls) ?? true,
            controlsPosition: try c.decodeIfPresent(RecordingControlsPosition.self, forKey: .controlsPosition) ?? .bottom,
            dimScreenWhileRecording: try c.decodeIfPresent(Bool.self, forKey: .dimScreenWhileRecording) ?? false,
            confirmBeforeDiscard: try c.decodeIfPresent(Bool.self, forKey: .confirmBeforeDiscard) ?? true,
            showRecordingTimeInMenuBar: try c.decodeIfPresent(Bool.self, forKey: .showRecordingTimeInMenuBar) ?? true
        )
    }
}

/// The five per-recording toggles the recorder toolbar offers (story 8).
public enum RecordingToggle: String, CaseIterable, Codable, Sendable {
    case microphone
    case computerAudio
    case camera
    case highlightClicks
    case showKeystrokes

    public var title: String {
        switch self {
        case .microphone: return "Microphone"
        case .computerAudio: return "Computer Audio"
        case .camera: return "Camera"
        case .highlightClicks: return "Highlight Clicks"
        case .showKeystrokes: return "Show Keystrokes"
        }
    }

    /// The grant switching this toggle on needs, requested lazily at that moment (story 41).
    /// Computer audio rides on Screen Recording and click highlighting needs no grant at all.
    public var requiredPermission: PermissionKind? {
        switch self {
        case .microphone: return .microphone
        case .camera: return .camera
        case .showKeystrokes: return .inputMonitoring
        case .computerAudio, .highlightClicks: return nil
        }
    }
}

/// What the recorder toolbar resolves to (stories 3–9): the region, which Start button was pressed,
/// and the per-recording toggle overrides. `AppCoordinator` turns it into `RecordingOptions`.
public struct RecordingChoice: Equatable, Sendable {
    public var region: CaptureRegion
    public var output: RecordingOutputKind
    public var overrides: RecordingOverrides
    /// The microphone picked in the toolbar's device menu (story 20); `nil` is the system default.
    /// Persisted as the Settings default, so the next take starts from it.
    public var microphoneDeviceID: String?

    public init(
        region: CaptureRegion, output: RecordingOutputKind, overrides: RecordingOverrides = .none,
        microphoneDeviceID: String? = nil
    ) {
        self.region = region
        self.output = output
        self.overrides = overrides
        self.microphoneDeviceID = microphoneDeviceID
    }
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

    /// The override for one toolbar toggle, so the toolbar can flip toggles generically.
    public subscript(toggle: RecordingToggle) -> Bool? {
        get {
            switch toggle {
            case .microphone: return microphone
            case .computerAudio: return computerAudio
            case .camera: return camera
            case .highlightClicks: return highlightClicks
            case .showKeystrokes: return showKeystrokes
            }
        }
        set {
            switch toggle {
            case .microphone: microphone = newValue
            case .computerAudio: computerAudio = newValue
            case .camera: camera = newValue
            case .highlightClicks: highlightClicks = newValue
            case .showKeystrokes: showKeystrokes = newValue
            }
        }
    }
}

public extension RecordingDefaults {
    /// The Settings default for one toolbar toggle — what the toggle shows before any override.
    subscript(toggle: RecordingToggle) -> Bool {
        switch toggle {
        case .microphone: return recordMicrophone
        case .computerAudio: return recordComputerAudio
        case .camera: return recordCamera
        case .highlightClicks: return highlightClicks
        case .showKeystrokes: return showKeystrokes
        }
    }
}
