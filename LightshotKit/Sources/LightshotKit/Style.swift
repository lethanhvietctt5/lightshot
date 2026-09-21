import Foundation

/// An RGBA color with normalized `0.0...1.0` components.
///
/// A pure value so the domain core never reaches for `NSColor` / `CGColor`.
public struct RGBAColor: Equatable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1.0) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    public static let red = RGBAColor(red: 1, green: 0, blue: 0)
    public static let black = RGBAColor(red: 0, green: 0, blue: 0)
}

/// How a redaction region obscures the pixels beneath it.
///
/// **Only `blackout` is secure redaction** — an opaque fill that erases the
/// pixels underneath on export. `blur` and `pixelate` merely obscure and can be
/// reversed or inferred, so they must never be presented as secret-safe.
public enum RedactionStyle: Equatable, Sendable {
    case blackout
    case blur
    case pixelate

    /// Strength a new redaction starts at — the midpoint of the `0...1` range that `blur`
    /// maps to a Gaussian radius and `pixelate` to a block size. `blackout` ignores it.
    public static let defaultStrength: Double = 0.5
}

/// How an arrow is drawn. `standard` and `fancy` are straight, filled, and taper from a
/// thin tail into the head; `curved` and `double` are an even stroke with open heads that
/// can be bent through a midpoint (see `AnnotationElement.Kind.arrow`).
public enum ArrowStyle: Equatable, Sendable, CaseIterable {
    /// Tapered shaft, solid head with softened corners.
    case standard
    /// Tapered shaft, sharp swept-back (barbed) head.
    case fancy
    /// Even stroke with an open head at the tip; bendable.
    case curved
    /// Even stroke with an open head at both ends; bendable.
    case double

    /// Whether the style follows a bend point. Straight styles never carry one.
    public var isBendable: Bool { self == .curved || self == .double }
}

/// Visual attributes shared by every annotation element.
///
/// Geometry lives on the element's `Kind`; `Style` carries only appearance so a
/// `setStyle` command can recolor or reweight a mark without moving it.
public struct Style: Equatable, Sendable {
    public var color: RGBAColor
    public var strokeWidth: Double
    public var fontSize: Double
    /// Optional interior fill; `nil` means an unfilled outline.
    public var fill: RGBAColor?

    public init(
        color: RGBAColor = .red,
        strokeWidth: Double = 3,
        fontSize: Double = 17,
        fill: RGBAColor? = nil
    ) {
        self.color = color
        self.strokeWidth = strokeWidth
        self.fontSize = fontSize
        self.fill = fill
    }

    public static let `default` = Style()
}
