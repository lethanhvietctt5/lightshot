import Testing
@testable import LightshotKit

// Spec 0008: the appearance preference and the theme palette's legibility in Light and Dark.

@Test(arguments: AppearancePreference.allCases, Appearance.allCases)
func aPreferenceResolvesToThePinnedAppearanceOrTheSystems(preference: AppearancePreference, system: Appearance) {
    let expected: Appearance
    switch preference {
    case .system: expected = system
    case .light: expected = .light
    case .dark: expected = .dark
    }
    #expect(preference.resolved(system: system) == expected)
}

@Test func aMissingOrUnknownStoredPreferenceMatchesTheSystem() {
    #expect(AppearancePreference(storedValue: nil) == .system)
    #expect(AppearancePreference(storedValue: "sepia") == .system)
    #expect(AppearancePreference(storedValue: "dark") == .dark)
    #expect(AppearancePreference(storedValue: "light") == .light)
    #expect(AppearancePreference.allCases.map(\.title) == ["Match System", "Light", "Dark"])
}

@Test func contrastRatioMatchesWCAGKnownValues() {
    let white = RGBAColor(red: 1, green: 1, blue: 1), black = RGBAColor.black
    #expect(abs(white.contrastRatio(on: black) - 21) < 0.001)
    #expect(abs(black.contrastRatio(on: white) - 21) < 0.001)
    #expect(abs(RGBAColor.red.contrastRatio(on: .red) - 1) < 0.001)
    // Mid grey #777 on white is the classic 4.48:1.
    let grey = RGBAColor(red: 0x77 / 255.0, green: 0x77 / 255.0, blue: 0x77 / 255.0)
    #expect(abs(grey.contrastRatio(on: white) - 4.48) < 0.01)
    // A translucent foreground is composited first: half-transparent black on white is mid grey.
    let halfBlack = RGBAColor(red: 0, green: 0, blue: 0, alpha: 0.5)
    #expect(halfBlack.composited(over: white) == RGBAColor(red: 0.5, green: 0.5, blue: 0.5))
    #expect(abs(halfBlack.contrastRatio(on: white) - RGBAColor(red: 0.5, green: 0.5, blue: 0.5).contrastRatio(on: white)) < 0.001)
}

@Test(arguments: Appearance.allCases)
func everyLegibilityPairMeetsItsContrastInBothAppearances(appearance: Appearance) {
    for pair in ThemePalette.legibilityPairs {
        let contrast = pair.contrast(in: appearance)
        #expect(contrast >= pair.minimum, "\(pair) in \(appearance): \(contrast) < \(pair.minimum)")
    }
}

@Test func everySurfaceTheChromeDrawsOnIsCheckedForText() {
    let surfaces = Set(ThemePalette.legibilityPairs.filter { $0.minimum >= ThemePalette.textContrast }.map(\.surface))
    #expect(surfaces.isSuperset(of: [.panel, .well, .tipBackground, .studioCanvas, .studioControl]))
}

/// Dark is the chrome Lightshot always drew (LIG-42's toolbar, spec 0007's Studio editor): these
/// values must not drift, so Dark Mode users see nothing change.
@Test func darkIsTheChromeLightshotAlwaysDrew() {
    func white(_ a: Double) -> RGBAColor { RGBAColor(red: 1, green: 1, blue: 1, alpha: a) }
    func black(_ a: Double) -> RGBAColor { RGBAColor(red: 0, green: 0, blue: 0, alpha: a) }
    let before: [ThemeToken: RGBAColor] = [
        .panel: RGBAColor(red: 0.17, green: 0.19, blue: 0.22),
        .panelEdge: white(0.08), .panelEdgeStrong: white(0.18), .panelShadow: black(0.3), .gridLine: white(0.09),
        .controlHover: white(0.1), .controlOn: white(0.14), .controlHoverEdge: white(0.18),
        .cellHover: white(0.07), .cellOn: black(0.3), .cellOnHover: black(0.4),
        .well: black(0.35), .rowHover: white(0.08), .helpFill: white(0.22),
        .tipBackground: black(0.85), .tipText: white(1), .tipEdge: white(0.15),
        .textPrimary: white(1), .textStrong: white(0.85), .glyph: white(0.75), .glyphOff: white(0.6),
        .textSecondary: white(0.55), .textTertiary: white(0.5), .textDisabled: white(0.35),
        .studioCanvas: RGBAColor(red: 0.12, green: 0.12, blue: 0.12), .studioDivider: white(0.08), .studioControl: white(0.08),
        .studioClip: RGBAColor(red: 0.25, green: 0.27, blue: 0.32), .clipEdge: white(0.15), .selectionRing: white(1),
        .previewShadow: black(0.4),
        .accentBlue: RGBAColor(red: 0.04, green: 0.52, blue: 1), .playhead: RGBAColor(red: 1, green: 0.27, blue: 0.23),
        .timelineSelection: RGBAColor(red: 1, green: 0.8, blue: 0.2), .zoomAccent: RGBAColor(red: 0.45, green: 0.35, blue: 0.95),
        .textAccent: RGBAColor(red: 0.95, green: 0.55, blue: 0.2),
        .studioPink: RGBAColor(red: 0.95, green: 0.4, blue: 0.6), .studioViolet: RGBAColor(red: 0.6, green: 0.45, blue: 0.95),
    ]
    for (token, color) in before {
        #expect(ThemePalette.color(token, in: .dark) == color, "\(token)")
    }
}

@Test func accentsKeepTheirHueInBothAppearances() {
    for token in [ThemeToken.accentBlue, .playhead, .timelineSelection, .zoomAccent, .textAccent, .studioPink, .studioViolet, .onAccent] {
        #expect(ThemePalette.color(token, in: .light) == ThemePalette.color(token, in: .dark), "\(token)")
    }
}

@Test func lightChromeIsLightAndDarkChromeIsDark() {
    for surface in [ThemeToken.panel, .studioCanvas] {
        #expect(ThemePalette.color(surface, in: .light).relativeLuminance > 0.7, "\(surface)")
        #expect(ThemePalette.color(surface, in: .dark).relativeLuminance < 0.05, "\(surface)")
    }
}
