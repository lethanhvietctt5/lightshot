import Foundation

/// The save-related slice of user settings (stories 42–43): the default output format and
/// where / what to name files when the user saves without a dialog.
///
/// Fronted as a protocol like the other OS-facing seams, so the coordinator's default-save
/// resolution is testable with an in-memory stub — the real implementation (app target) is backed
/// by `UserDefaults`. Only the save slice lives here; hotkeys, retention, and the rest join with
/// their own tickets.
@MainActor
public protocol SettingsStore: AnyObject {
    /// Format used for a save that carries no per-save override.
    var defaultFormat: ImageFormat { get set }
    /// Directory new files are written into by default (story 43).
    var saveLocation: URL { get set }
    /// Filename pattern (without extension), expanded per save — see `FilenameFormatter`.
    var filenamePattern: String { get set }
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
