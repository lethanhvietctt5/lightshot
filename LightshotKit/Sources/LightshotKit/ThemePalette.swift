import Foundation

/// One named colour of Lightshot's custom chrome (spec 0008): the recorder toolbar, the recording
/// controls pill and their tips, and the Studio editor. Standard controls use the system's own
/// semantic colours instead; content never uses these.
public enum ThemeToken: String, CaseIterable, Sendable {
    // Toolbar panels (LIG-42's chrome).
    case panel, panelEdge, panelEdgeStrong, panelShadow, gridLine
    case controlHover, controlOn, controlHoverEdge
    case cellHover, cellOn, cellOnHover
    case well, rowHover, helpFill
    case tipBackground, tipText, tipEdge

    // Text and glyphs, strongest to faintest.
    case textPrimary, textStrong, glyph, glyphOff, textSecondary, textTertiary, textDisabled
    /// Text and glyphs on an accent fill (blue, zoom purple, text-pill orange).
    case onAccent
    case warning

    // The Studio editor.
    case studioCanvas, studioDivider, studioControl, studioClip, clipEdge, selectionRing, previewShadow

    // Accents: the same hue in both appearances.
    case accentBlue, playhead, timelineSelection, zoomAccent, textAccent, trimAccent, speedAccent, studioPink, studioViolet
}

/// Every `ThemeToken`'s colour in Light and Dark (spec 0008). The Dark values are the dark chrome
/// Lightshot always drew; the Light values are its light counterpart. `legibilityPairs` names what
/// is drawn on what, and the tests hold both appearances to it.
public enum ThemePalette {
    public static func color(_ token: ThemeToken, in appearance: Appearance) -> RGBAColor {
        let (light, dark) = values(token)
        return appearance == .dark ? dark : light
    }

    private static func white(_ alpha: Double) -> RGBAColor { RGBAColor(red: 1, green: 1, blue: 1, alpha: alpha) }
    private static func black(_ alpha: Double) -> RGBAColor { RGBAColor(red: 0, green: 0, blue: 0, alpha: alpha) }
    private static func grey(_ level: Double) -> RGBAColor { RGBAColor(red: level, green: level, blue: level) }
    private static let ink = RGBAColor(red: 0.11, green: 0.11, blue: 0.13)

    /// (light, dark).
    private static func values(_ token: ThemeToken) -> (RGBAColor, RGBAColor) {
        switch token {
        case .panel: return (RGBAColor(red: 0.965, green: 0.965, blue: 0.97), RGBAColor(red: 0.17, green: 0.19, blue: 0.22))
        case .panelEdge: return (black(0.1), white(0.08))
        case .panelEdgeStrong: return (black(0.16), white(0.18))
        case .panelShadow: return (black(0.16), black(0.3))
        case .gridLine: return (black(0.08), white(0.09))
        case .controlHover: return (black(0.06), white(0.1))
        case .controlOn: return (black(0.1), white(0.14))
        case .controlHoverEdge: return (black(0.14), white(0.18))
        case .cellHover: return (black(0.05), white(0.07))
        case .cellOn: return (black(0.09), black(0.3))
        case .cellOnHover: return (black(0.13), black(0.4))
        case .well: return (black(0.07), black(0.35))
        case .rowHover: return (black(0.06), white(0.08))
        case .helpFill: return (black(0.12), white(0.22))
        case .tipBackground: return (white(0.98), black(0.85))
        case .tipText: return (ink, white(1))
        case .tipEdge: return (black(0.12), white(0.15))

        case .textPrimary: return (ink, white(1))
        case .textStrong: return (black(0.8), white(0.85))
        case .glyph: return (black(0.7), white(0.75))
        case .glyphOff: return (black(0.55), white(0.6))
        case .textSecondary: return (black(0.6), white(0.55))
        case .textTertiary: return (black(0.6), white(0.5))
        case .textDisabled: return (black(0.3), white(0.35))
        case .onAccent: return (white(1), white(1))
        case .warning: return (RGBAColor(red: 0.72, green: 0.33, blue: 0), RGBAColor(red: 1, green: 0.62, blue: 0.04))

        case .studioCanvas: return (RGBAColor(red: 0.93, green: 0.93, blue: 0.94), grey(0.12))
        case .studioDivider: return (black(0.1), white(0.08))
        case .studioControl: return (black(0.07), white(0.08))
        case .studioClip: return (RGBAColor(red: 0.78, green: 0.8, blue: 0.85), RGBAColor(red: 0.25, green: 0.27, blue: 0.32))
        case .clipEdge: return (black(0.15), white(0.15))
        case .selectionRing: return (RGBAColor(red: 0.04, green: 0.52, blue: 1), white(1))
        case .previewShadow: return (black(0.18), black(0.4))

        case .accentBlue: return same(RGBAColor(red: 0.04, green: 0.52, blue: 1))
        case .playhead: return same(RGBAColor(red: 1, green: 0.27, blue: 0.23))
        case .timelineSelection: return same(RGBAColor(red: 1, green: 0.8, blue: 0.2))
        case .zoomAccent: return same(RGBAColor(red: 0.45, green: 0.35, blue: 0.95))
        case .textAccent: return same(RGBAColor(red: 0.95, green: 0.55, blue: 0.2))
        case .trimAccent: return same(RGBAColor(red: 0.88, green: 0.24, blue: 0.3))
        case .speedAccent: return same(RGBAColor(red: 0.08, green: 0.55, blue: 0.42))
        case .studioPink: return same(RGBAColor(red: 0.95, green: 0.4, blue: 0.6))
        case .studioViolet: return same(RGBAColor(red: 0.6, green: 0.45, blue: 0.95))
        }
    }

    private static func same(_ color: RGBAColor) -> (RGBAColor, RGBAColor) { (color, color) }

    /// A foreground drawn on a surface, and how much contrast it needs. A translucent surface is
    /// laid over `backdrop` first (the panel or canvas it sits on).
    public struct LegibilityPair: Sendable, CustomStringConvertible {
        public let foreground: ThemeToken
        public let surface: ThemeToken
        public let backdrop: ThemeToken?
        public let minimum: Double

        public var description: String {
            "\(foreground) on \(surface)" + (backdrop.map { " over \($0)" } ?? "")
        }

        public func contrast(in appearance: Appearance) -> Double {
            var background = ThemePalette.color(surface, in: appearance)
            if let backdrop { background = background.composited(over: ThemePalette.color(backdrop, in: appearance)) }
            return ThemePalette.color(foreground, in: appearance).contrastRatio(on: background)
        }
    }

    /// WCAG AA for text; 3:1 for glyphs, edges and bold labels on accents; and a floor for the
    /// state fills (hover, on) that only have to be told apart from the surface under them.
    public static let textContrast = 4.5
    public static let glyphContrast = 3.0
    public static let stateContrast = 1.12

    public static let legibilityPairs: [LegibilityPair] = {
        func pair(_ foreground: ThemeToken, on surface: ThemeToken, over backdrop: ThemeToken? = nil, _ minimum: Double) -> LegibilityPair {
            LegibilityPair(foreground: foreground, surface: surface, backdrop: backdrop, minimum: minimum)
        }
        return [
            // Toolbar text and glyphs.
            pair(.textPrimary, on: .panel, textContrast),
            pair(.textStrong, on: .panel, textContrast),
            pair(.textTertiary, on: .panel, textContrast),
            pair(.glyph, on: .panel, glyphContrast),
            pair(.glyphOff, on: .panel, glyphContrast),
            pair(.warning, on: .panel, textContrast),
            pair(.textPrimary, on: .well, over: .panel, textContrast),
            pair(.textPrimary, on: .cellOn, over: .panel, textContrast),
            pair(.textPrimary, on: .controlOn, over: .panel, textContrast),
            pair(.textStrong, on: .controlOn, over: .panel, textContrast),
            pair(.tipText, on: .tipBackground, over: .panel, textContrast),
            pair(.warning, on: .tipBackground, over: .panel, textContrast),
            // Toolbar states.
            pair(.controlOn, on: .panel, stateContrast),
            pair(.cellOn, on: .panel, stateContrast),
            pair(.controlHover, on: .panel, stateContrast),

            // Studio text and glyphs.
            pair(.textPrimary, on: .studioCanvas, textContrast),
            pair(.textSecondary, on: .studioCanvas, textContrast),
            pair(.glyph, on: .studioCanvas, textContrast),
            pair(.textPrimary, on: .studioControl, over: .studioCanvas, textContrast),
            pair(.textStrong, on: .studioControl, over: .studioCanvas, textContrast),
            pair(.textSecondary, on: .studioControl, over: .studioCanvas, textContrast),
            pair(.selectionRing, on: .studioCanvas, glyphContrast),
            // Studio states and shapes.
            pair(.studioControl, on: .studioCanvas, stateContrast),
            pair(.studioClip, on: .studioCanvas, stateContrast),
            // Labels on accents.
            pair(.onAccent, on: .accentBlue, glyphContrast),
            pair(.onAccent, on: .zoomAccent, glyphContrast),
            pair(.onAccent, on: .trimAccent, glyphContrast),
            pair(.onAccent, on: .speedAccent, glyphContrast),
        ]
    }()
}
