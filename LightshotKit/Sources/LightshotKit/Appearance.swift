import Foundation

/// The look Lightshot's chrome is drawn in right now (spec 0008). Content — captures,
/// annotations, recordings, exports, and the overlays drawn over the screen — never depends on it.
public enum Appearance: String, CaseIterable, Sendable {
    case light, dark
}

/// The Settings choice behind the appearance (spec 0008, stories 11–15): follow macOS, or pin
/// Light or Dark for Lightshot alone.
public enum AppearancePreference: String, CaseIterable, Codable, Sendable {
    case system, light, dark

    public var title: String {
        switch self {
        case .system: return "Match System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    /// A stored raw value, falling back to `system` when it is missing or unknown.
    public init(storedValue: String?) {
        self = storedValue.flatMap(Self.init(rawValue:)) ?? .system
    }

    /// The appearance to draw in, given the system's.
    public func resolved(system: Appearance) -> Appearance {
        switch self {
        case .system: return system
        case .light: return .light
        case .dark: return .dark
        }
    }
}

public extension RGBAColor {
    /// WCAG relative luminance of the colour's RGB (alpha ignored), from its sRGB components.
    var relativeLuminance: Double {
        func linear(_ c: Double) -> Double {
            let c = min(max(c, 0), 1)
            return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    /// This colour laid over `backdrop` (source-over, in sRGB as AppKit composites by default);
    /// the result is opaque when the backdrop is.
    func composited(over backdrop: RGBAColor) -> RGBAColor {
        let a = alpha + backdrop.alpha * (1 - alpha)
        guard a > 0 else { return RGBAColor(red: 0, green: 0, blue: 0, alpha: 0) }
        func mix(_ top: Double, _ bottom: Double) -> Double {
            (top * alpha + bottom * backdrop.alpha * (1 - alpha)) / a
        }
        return RGBAColor(red: mix(red, backdrop.red), green: mix(green, backdrop.green), blue: mix(blue, backdrop.blue), alpha: a)
    }

    /// The WCAG contrast ratio (1…21) of this colour drawn on `background`; a translucent
    /// foreground is composited over the background first.
    func contrastRatio(on background: RGBAColor) -> Double {
        let top = composited(over: background).relativeLuminance
        let bottom = background.relativeLuminance
        return (max(top, bottom) + 0.05) / (min(top, bottom) + 0.05)
    }
}
