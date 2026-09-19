import Foundation

/// A capture action a global hotkey can be bound to (story 56).
///
/// These are the user-triggerable capture entry points the settings window lets you rebind. The set
/// is deliberately small and stable: adding a mode (e.g. "repeat last") is a new case, not a change
/// to the binding model. All three capture paths are wired (area LIG-13, window LIG-14, fullscreen
/// LIG-7); `repeatLast` (LIG-20, story 9) re-fires whichever of those ran most recently. `window`
/// and `repeatLast` carry no default chord (see `HotkeyBindings.defaults`) — we don't claim extra
/// global shortcuts by default; the user can bind them in settings.
public enum CaptureAction: String, CaseIterable, Codable, Sendable, Identifiable {
    case area
    case window
    case fullscreen
    /// Re-trigger the most recently used capture mode (story 9). Not a capture *mode* itself — it
    /// delegates to the last of area/window/fullscreen the user ran — but it is a rebindable action,
    /// so it lives here alongside them rather than in a parallel binding model.
    case repeatLast

    public var id: String { rawValue }

    /// Menu/settings label for the action.
    public var title: String {
        switch self {
        case .area: return "Capture Area"
        case .window: return "Capture Window"
        case .fullscreen: return "Capture Fullscreen"
        case .repeatLast: return "Repeat Last Capture"
        }
    }
}

extension CaptureAction: Comparable {
    /// Ordered by declaration (`allCases`) so conflict listings and the settings form read in a
    /// stable, intuitive order rather than by raw string.
    public static func < (lhs: CaptureAction, rhs: CaptureAction) -> Bool {
        let all = CaptureAction.allCases
        return all.firstIndex(of: lhs)! < all.firstIndex(of: rhs)!
    }
}
