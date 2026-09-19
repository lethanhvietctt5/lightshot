import Foundation

/// A capture action a global hotkey can be bound to (story 56).
///
/// These are the user-triggerable capture entry points the settings window lets you rebind. The set
/// is deliberately small and stable: adding a mode (e.g. "repeat last") is a new case, not a change
/// to the binding model. `window` is listed so it can be bound now even though the capture itself
/// lands in LIG-14 — it simply carries no default hotkey until then.
public enum CaptureAction: String, CaseIterable, Codable, Sendable, Identifiable {
    case area
    case window
    case fullscreen

    public var id: String { rawValue }

    /// Menu/settings label for the action.
    public var title: String {
        switch self {
        case .area: return "Capture Area"
        case .window: return "Capture Window"
        case .fullscreen: return "Capture Fullscreen"
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
