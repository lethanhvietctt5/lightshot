import Foundation
import OSLog
import ServiceManagement
import LightshotKit

/// `UserDefaults`-backed `SettingsStore` (the OS side of the settings seam).
///
/// Persists the save slice — default format + JPEG quality, save location, filename pattern (stories
/// 42–43) — plus the LIG-15 capture/app defaults: hotkey bindings, open-in-editor, cursor inclusion,
/// and history retention. Launch-at-login is not a `UserDefaults` flag: it reads/writes the real
/// login-item registration through `SMAppService`, so the toggle reflects (and drives) system state.
/// Defaults mirror macOS's own screenshots: PNG, onto the Desktop, named `Screenshot <date> at <time>`.
@MainActor
final class UserDefaultsSettingsStore: SettingsStore {
    private let defaults: UserDefaults
    private let logger = Logger(subsystem: "dev.lightshot.app", category: "settings")

    private enum Key {
        static let format = "save.format"        // "png" | "jpeg"
        static let quality = "save.jpegQuality"  // Double, 0...1
        static let location = "save.location"    // absolute directory path
        static let pattern = "save.filenamePattern"
        static let hotkeys = "capture.hotkeys"   // JSON: [action.rawValue: HotkeyBinding]
        static let openInEditor = "capture.openInEditor"
        static let includeCursor = "capture.includeCursor"
        static let captureDelay = "capture.delay"   // TimeInterval seconds; 0 == off
        static let historyRetention = "history.retention"
        static let recordingDefaults = "recording.defaults"   // JSON: RecordingDefaults
        static let rememberLastRecordingArea = "recording.rememberLastArea"
        static let lastRecordingRegion = "recording.lastRegion"   // JSON: CaptureRegion
        static let appearance = "app.appearance"   // "system" | "light" | "dark"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var defaultFormat: ImageFormat {
        get {
            switch defaults.string(forKey: Key.format) {
            case "jpeg":
                let quality = defaults.object(forKey: Key.quality) as? Double ?? 0.9
                return .jpeg(clamping: quality)
            default:
                return .png
            }
        }
        set {
            switch newValue {
            case .png:
                defaults.set("png", forKey: Key.format)
            case let .jpeg(quality):
                defaults.set("jpeg", forKey: Key.format)
                defaults.set(min(max(quality, 0), 1), forKey: Key.quality)
            }
        }
    }

    var saveLocation: URL {
        get {
            if let path = defaults.string(forKey: Key.location) {
                return URL(fileURLWithPath: path, isDirectory: true)
            }
            return Self.defaultLocation
        }
        set { defaults.set(newValue.path, forKey: Key.location) }
    }

    var filenamePattern: String {
        get { defaults.string(forKey: Key.pattern) ?? Self.defaultPattern }
        set { defaults.set(newValue, forKey: Key.pattern) }
    }

    var hotkeys: HotkeyBindings {
        get {
            guard let data = defaults.data(forKey: Key.hotkeys),
                  let raw = try? JSONDecoder().decode([String: HotkeyBinding].self, from: data)
            else {
                return .defaults
            }
            // Fold the string-keyed JSON back onto typed actions; unknown keys are ignored so an old
            // build's file never crashes a new one.
            var bindings = HotkeyBindings()
            for (key, binding) in raw {
                if let action = CaptureAction(rawValue: key) { bindings[action] = binding }
            }
            return bindings
        }
        set {
            let raw = Dictionary(
                uniqueKeysWithValues: newValue.assignments.map { ($0.key.rawValue, $0.value) }
            )
            if let data = try? JSONEncoder().encode(raw) {
                defaults.set(data, forKey: Key.hotkeys)
            }
        }
    }

    var openInEditor: Bool {
        get { defaults.object(forKey: Key.openInEditor) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.openInEditor) }
    }

    var includeCursor: Bool {
        get { defaults.bool(forKey: Key.includeCursor) }   // defaults to false — a clean shot
        set { defaults.set(newValue, forKey: Key.includeCursor) }
    }

    var captureDelay: TimeInterval {
        get { defaults.double(forKey: Key.captureDelay) }  // defaults to 0 — fire immediately
        set { defaults.set(max(0, newValue), forKey: Key.captureDelay) }
    }

    var historyRetention: Int {
        get { defaults.object(forKey: Key.historyRetention) as? Int ?? Self.defaultRetention }
        set { defaults.set(max(0, newValue), forKey: Key.historyRetention) }
    }

    /// The recording baseline (spec 0006), persisted as one JSON blob: it is edited as a unit by the
    /// Recording settings section and read as a unit at the start of every take. Unreadable or
    /// missing data falls back to the shipped `.standard` so an old build's file never breaks a new one.
    var recordingDefaults: RecordingDefaults {
        get {
            guard let data = defaults.data(forKey: Key.recordingDefaults),
                  let stored = try? JSONDecoder().decode(RecordingDefaults.self, from: data)
            else { return .standard }
            return stored
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                defaults.set(data, forKey: Key.recordingDefaults)
            }
        }
    }

    var rememberLastRecordingArea: Bool {
        get { defaults.bool(forKey: Key.rememberLastRecordingArea) }   // defaults to false
        set { defaults.set(newValue, forKey: Key.rememberLastRecordingArea) }
    }

    var lastRecordingRegion: CaptureRegion? {
        get {
            guard let data = defaults.data(forKey: Key.lastRecordingRegion) else { return nil }
            return try? JSONDecoder().decode(CaptureRegion.self, from: data)
        }
        set {
            if let newValue, let data = try? JSONEncoder().encode(newValue) {
                defaults.set(data, forKey: Key.lastRecordingRegion)
            } else {
                defaults.removeObject(forKey: Key.lastRecordingRegion)
            }
        }
    }

    /// Spec 0008: an unknown or missing value matches the system.
    var appearance: AppearancePreference {
        get { AppearancePreference(storedValue: defaults.string(forKey: Key.appearance)) }
        set { defaults.set(newValue.rawValue, forKey: Key.appearance) }
    }

    /// Backed by the real login-item registration, not a stored flag, so the toggle can't drift from
    /// system state (story 59). A failed (un)register is logged and surfaced by the getter returning
    /// the unchanged status.
    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                logger.error("Launch-at-login \(newValue ? "register" : "unregister") failed: \(error.localizedDescription)")
            }
        }
    }

    /// The persisted cursor-inclusion flag, readable off the main actor — the capture service does
    /// its ScreenCaptureKit work off-main, so it can't touch this `@MainActor` store directly. Reads
    /// the same key `includeCursor` writes, so it always reflects the latest saved value.
    nonisolated static func storedIncludeCursor(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: Key.includeCursor)
    }

    static let defaultPattern = "Screenshot %Y-%m-%d at %H.%M.%S"
    static let defaultRetention = 50
    static var defaultLocation: URL {
        FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
    }
}
