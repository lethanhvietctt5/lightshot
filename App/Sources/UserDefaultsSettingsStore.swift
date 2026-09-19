import Foundation
import LightshotKit

/// `UserDefaults`-backed `SettingsStore` (the OS side of the settings seam).
///
/// Persists the save-related slice — default format + JPEG quality, save location, filename pattern
/// — so files land where the user expects without a dialog every time (stories 42–43). Defaults
/// mirror macOS's own screenshots: PNG, onto the Desktop, named `Screenshot <date> at <time>`. Only
/// the save slice is implemented for LIG-11; hotkeys, retention, and the rest join with their
/// tickets.
@MainActor
final class UserDefaultsSettingsStore: SettingsStore {
    private let defaults: UserDefaults

    private enum Key {
        static let format = "save.format"        // "png" | "jpeg"
        static let quality = "save.jpegQuality"  // Double, 0...1
        static let location = "save.location"    // absolute directory path
        static let pattern = "save.filenamePattern"
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

    static let defaultPattern = "Screenshot %Y-%m-%d at %H.%M.%S"
    static var defaultLocation: URL {
        FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
    }
}
