import Foundation

/// User settings backing the settings window (stories 12, 42–43, 54, 56, 59, 60).
///
/// Fronted as a protocol like the other OS-facing seams, so the coordinator's default-save
/// resolution is testable with an in-memory stub — the real implementation (app target) is backed
/// by `UserDefaults` (and `SMAppService` for launch-at-login). The save slice (stories 42–43) landed
/// with LIG-11; LIG-15 adds the capture/app defaults: hotkeys, open-in-editor, cursor inclusion,
/// history retention, and launch-at-login.
@MainActor
public protocol SettingsStore: AnyObject {
    /// Format used for a save that carries no per-save override.
    var defaultFormat: ImageFormat { get set }
    /// Directory new files are written into by default (story 43).
    var saveLocation: URL { get set }
    /// Filename pattern (without extension), expanded per save — see `FilenameFormatter`.
    var filenamePattern: String { get set }

    /// The global-hotkey chords bound to each capture action (story 56).
    var hotkeys: HotkeyBindings { get set }
    /// Whether a fresh area/window capture opens straight in the editor (story 13/60) — the default
    /// — or shows the post-capture toolbar at the selection instead. Read live at capture time by
    /// `AppCoordinator` (LIG-23).
    var openInEditor: Bool { get set }
    /// Whether the mouse cursor is included in captures (story 12). Read live at capture time by
    /// `SCCaptureService`.
    var includeCursor: Bool { get set }
    /// Self-timer: how many seconds to wait before a capture fires (story 10), so the user can set
    /// up transient UI (menus, tooltips, hover states) first. `0` (the default) fires immediately.
    /// The `AppCoordinator` reads this and delays before every capture path.
    var captureDelay: TimeInterval { get set }
    /// How many captures the local history retains (story 54); `0` keeps none. **Persisted here by
    /// LIG-15; not yet enforced.** Trimming to this limit and the companion "clear history" action
    /// (story 54) belong to the `HistoryStore` seam (stories 50–54), which does not exist yet.
    var historyRetention: Int { get set }
    /// Whether the app is registered to launch at login (story 59).
    var launchAtLogin: Bool { get set }
}

public extension SettingsStore {
    /// The full destination URL a default save lands at: the configured location joined with the
    /// expanded filename pattern and the default format's extension. This is what "used when no
    /// override is given" resolves to (story 43).
    func defaultDestination(at date: Date = Date()) -> URL {
        FilenameFormatter(pattern: filenamePattern)
            .destinationURL(in: saveLocation, format: defaultFormat, at: date)
    }
}

/// Expands a filename pattern into a concrete name for a save (story 43).
///
/// Supported tokens, each zero-padded and resolved from `date` in `calendar`: `%Y` year (4 digits),
/// `%m` month, `%d` day, `%H` hour (24h), `%M` minute, `%S` second. Any other text — including a
/// lone `%` or an unknown token — is copied through verbatim, so the default
/// `"Screenshot %Y-%m-%d at %H.%M.%S"` mirrors macOS's own screenshot names. Pure and deterministic
/// given a `date` + `calendar`, so it is unit-tested without touching disk.
public struct FilenameFormatter: Equatable, Sendable {
    public var pattern: String
    public var calendar: Calendar

    public init(pattern: String, calendar: Calendar = .current) {
        self.pattern = pattern
        self.calendar = calendar
    }

    /// The expanded filename, without an extension.
    public func filename(at date: Date) -> String {
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let values: [Character: Int] = [
            "Y": c.year ?? 0, "m": c.month ?? 0, "d": c.day ?? 0,
            "H": c.hour ?? 0, "M": c.minute ?? 0, "S": c.second ?? 0,
        ]
        var out = ""
        var chars = pattern.makeIterator()
        while let ch = chars.next() {
            guard ch == "%", let token = chars.next() else { out.append(ch); continue }
            guard let value = values[token] else { out.append("%"); out.append(token); continue }
            out += String(format: "%0\(token == "Y" ? 4 : 2)d", value)
        }
        return out
    }

    /// The full destination URL: `filename(at:)` under `directory`, with `format`'s extension.
    public func destinationURL(in directory: URL, format: ImageFormat, at date: Date) -> URL {
        directory
            .appendingPathComponent(filename(at: date))
            .appendingPathExtension(format.fileExtension)
    }
}
