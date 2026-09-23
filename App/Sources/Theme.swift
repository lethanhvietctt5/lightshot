import AppKit
import SwiftUI
import LightshotKit

/// Lightshot's one appearance (spec 0008): set app-wide, so every window, panel, popover, menu,
/// sheet and open panel — AppKit and SwiftUI alike — draws in it and switches live.
@MainActor
enum AppAppearance {
    static func apply(_ preference: AppearancePreference) {
        switch preference {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }
}

extension NSAppearance {
    /// Light or Dark, for the theme palette.
    var themeAppearance: Appearance {
        bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .dark : .light
    }
}

extension NSColor {
    /// A theme token as a dynamic colour: it resolves against whatever appearance draws it, so
    /// chrome re-colours itself on an appearance change with no view code.
    static func theme(_ token: ThemeToken) -> NSColor {
        ThemeColors.all[token]!
    }

    convenience init(_ color: RGBAColor) {
        self.init(srgbRed: color.red, green: color.green, blue: color.blue, alpha: color.alpha)
    }
}

extension Color {
    /// A theme token for SwiftUI chrome (spec 0008).
    static func theme(_ token: ThemeToken) -> Color {
        Color(nsColor: .theme(token))
    }
}

/// One dynamic `NSColor` per token, made once and never changed (so safe to read anywhere).
private enum ThemeColors {
    static let all: [ThemeToken: NSColor] = Dictionary(uniqueKeysWithValues: ThemeToken.allCases.map { token in
        (token, NSColor(name: NSColor.Name("lightshot.\(token.rawValue)")) { appearance in
            NSColor(ThemePalette.color(token, in: appearance.themeAppearance))
        })
    })
}
