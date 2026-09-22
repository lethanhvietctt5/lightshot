import CoreGraphics
import CoreText
import Foundation

/// How a text label is laid out (LIG-47): its text sits `padding` inside a box and wraps at the
/// box's width. A label's box has either its **natural** width — the widest line, so it grows as
/// it is typed — or a width set by hand with a side handle, at which the text wraps. One layout
/// for the editor's canvas and the export, both drawn by `draw(_:fontSize:color:in:context:)`.
public enum TextLayout {
    /// The typeface of every label, on the canvas and in the export.
    public static let fontName = "Helvetica"

    /// The space between a label's text and its box edge.
    public static func padding(for fontSize: Double) -> Double { max(4, (fontSize * 0.3).rounded()) }

    /// The narrowest a label's box can be made.
    public static func minimumWidth(for fontSize: Double) -> Double { fontSize * 1.5 + 2 * padding(for: fontSize) }

    /// The box for `string` whose top-left corner is `origin`: `width` wide when given (the text
    /// wraps inside it), else the natural width; always as tall as the wrapped text.
    public static func box(for string: String, fontSize: Double, origin: Point, width: Double? = nil) -> Rect {
        let pad = padding(for: fontSize)
        let boxWidth = max(width ?? naturalWidth(string, fontSize: fontSize), minimumWidth(for: fontSize))
        let content = contentSize(string, fontSize: fontSize, wrapWidth: boxWidth - 2 * pad)
        return Rect(x: origin.x, y: origin.y, width: boxWidth, height: content.height + 2 * pad)
    }

    /// Whether `box` has the natural width of `string` — a label still growing as it is typed,
    /// rather than one whose width was set by hand.
    public static func hasNaturalWidth(_ box: Rect, string: String, fontSize: Double) -> Bool {
        let natural = max(naturalWidth(string, fontSize: fontSize), minimumWidth(for: fontSize))
        return abs(box.standardized.width - natural) < 0.5
    }

    /// The width of the widest line of `string`, plus padding.
    static func naturalWidth(_ string: String, fontSize: Double) -> Double {
        contentSize(string, fontSize: fontSize, wrapWidth: nil).width.rounded(.up) + 2 * padding(for: fontSize)
    }

    /// The size of `string` laid out no wider than `wrapWidth` (or unwrapped when nil). An empty
    /// string is one line tall, so a new label has a caret-sized box.
    static func contentSize(_ string: String, fontSize: Double, wrapWidth: Double?) -> Size {
        let measured = string.isEmpty ? " " : string
        let framesetter = CTFramesetterCreateWithAttributedString(attributed(measured, fontSize: fontSize, color: nil))
        let constraint = CGSize(width: wrapWidth.map { CGFloat(max($0, 1)) } ?? .greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        let size = CTFramesetterSuggestFrameSizeWithConstraints(framesetter, CFRange(location: 0, length: 0), nil, constraint, nil)
        return Size(width: string.isEmpty ? 0 : Double(size.width), height: Double(size.height).rounded(.up))
    }

    /// Draws `string` wrapped inside `rect` (already inset by the padding) into `context`, whose
    /// y axis points up (a bitmap context); `rect` is in that context's coordinates.
    public static func draw(_ string: String, fontSize: Double, color: CGColor, in rect: CGRect, context: CGContext) {
        guard !string.isEmpty else { return }
        let framesetter = CTFramesetterCreateWithAttributedString(attributed(string, fontSize: fontSize, color: color))
        // A little extra height so a last line that rounds up is never clipped away.
        let path = CGPath(rect: rect.insetBy(dx: 0, dy: -2).offsetBy(dx: 0, dy: -2), transform: nil)
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), path, nil)
        CTFrameDraw(frame, context)
    }

    private static func attributed(_ string: String, fontSize: Double, color: CGColor?) -> CFAttributedString {
        let font = CTFontCreateWithName(fontName as CFString, CGFloat(fontSize), nil)
        var attributes: [NSAttributedString.Key: Any] = [.init(kCTFontAttributeName as String): font]
        if let color { attributes[.init(kCTForegroundColorAttributeName as String)] = color }
        return NSAttributedString(string: string, attributes: attributes) as CFAttributedString
    }
}
