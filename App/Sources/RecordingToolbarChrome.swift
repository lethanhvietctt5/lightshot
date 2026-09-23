import SwiftUI

/// The look the recorder toolbar and the recording controls pill share (LIG-42), after CleanShot:
/// translucent slate panels — light or dark with the appearance (spec 0008) — every action in a
/// bordered box that lights up under the pointer, and the action's title shown at once above it,
/// with no system tooltip delay.
enum ToolbarChrome {
    /// Every control in a toolbar row takes this height, so the rows stay aligned.
    static let controlHeight: CGFloat = 32
    static let controlWidth: CGFloat = 36
    static let panelRadius: CGFloat = 14
    static let controlRadius: CGFloat = 8
    /// The panels' colour.
    static let slate = Color.theme(.panel)
}

/// How visible a toolbar panel's edge is: the menus draw a visible one, the toolbar barely any.
enum ToolbarPanelEdge {
    case subtle, strong, none

    var color: Color {
        switch self {
        case .subtle: return .theme(.panelEdge)
        case .strong: return .theme(.panelEdgeStrong)
        case .none: return .clear
        }
    }
}

extension View {
    /// The slate panel behind a toolbar, with an `edge` as visible as it needs. The hovered
    /// control's tip shows on the panel's `tipEdge`, lined up with the control, so it never covers
    /// the panel's other actions. Text and glyphs inside default to the panel's primary colour.
    func toolbarPanel(edge: ToolbarPanelEdge = .subtle, tipEdge: VerticalEdge = .top) -> some View {
        overlayPreferenceValue(ToolbarTipKey.self) { tip in
            GeometryReader { proxy in
                if let tip {
                    let control = proxy[tip.anchor]
                    ToolbarTip(title: tip.title, detail: tip.detail)
                        .frame(width: proxy.size.width)
                        .offset(x: control.midX - proxy.size.width / 2)
                        .frame(height: 0, alignment: tipEdge == .top ? .bottom : .top)
                        .offset(y: tipEdge == .top ? -8 : proxy.size.height + 8)
                        .allowsHitTesting(false)
                }
            }
        }
        .transformPreference(ToolbarTipKey.self) { $0 = nil }
        .background(
            RoundedRectangle(cornerRadius: ToolbarChrome.panelRadius)
                .fill(.regularMaterial)
                .overlay(RoundedRectangle(cornerRadius: ToolbarChrome.panelRadius).fill(ToolbarChrome.slate.opacity(0.92)))
                .overlay(RoundedRectangle(cornerRadius: ToolbarChrome.panelRadius).stroke(edge.color, lineWidth: 1))
                .shadow(color: .theme(.panelShadow), radius: 14, y: 6)
        )
        .foregroundStyle(Color.theme(.textPrimary))
    }

    /// One action, as CleanShot draws it: a plain glyph at rest, a filled box while it is on or
    /// under the pointer (with a light edge on hover), `title` shown above it the moment the
    /// pointer arrives, and — when `warning` is set — a small orange badge whose message joins
    /// the tip.
    func toolbarControl(_ title: String, isOn: Bool = false, warning: String? = nil, shape: ToolbarControlShape = .box) -> some View {
        modifier(ToolbarControl(title: title, isOn: isOn, warning: warning, shape: shape))
    }
}

/// How a control lights up: a rounded `box` of its own, or a whole `cell` of the toolbar's grid —
/// filled edge to edge (darker while on), rounded only where it meets the panel's corners.
enum ToolbarControlShape {
    case box
    case cell(RectangleCornerRadii = .init())
}

private struct ToolbarControl: ViewModifier {
    let title: String
    let isOn: Bool
    let warning: String?
    let shape: ToolbarControlShape
    @State private var hovered = false

    private var outline: AnyShape {
        switch shape {
        case .box: AnyShape(RoundedRectangle(cornerRadius: ToolbarChrome.controlRadius))
        case let .cell(corners): AnyShape(UnevenRoundedRectangle(cornerRadii: corners))
        }
    }

    private var fill: Color {
        switch shape {
        case .box: isOn ? .theme(.controlOn) : hovered ? .theme(.controlHover) : .clear
        case .cell: isOn ? .theme(hovered ? .cellOnHover : .cellOn) : hovered ? .theme(.cellHover) : .clear
        }
    }

    private var stroke: Color {
        if case .box = shape, hovered { return .theme(.controlHoverEdge) }
        return .clear
    }

    /// The badge sits on the glyph's corner: a box's own corner, or inset into a cell.
    private var badgeOffset: CGSize {
        if case .box = shape { return CGSize(width: 3, height: -3) }
        return CGSize(width: -15, height: 7)
    }

    func body(content: Content) -> some View {
        content
            .background(outline.fill(fill))
            .overlay(outline.stroke(stroke, lineWidth: 1))
            .overlay(alignment: .topTrailing) {
                if warning != nil {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Color.theme(.warning))
                        .offset(badgeOffset)
                        .allowsHitTesting(false)
                }
            }
            .anchorPreference(key: ToolbarTipKey.self, value: .bounds) { anchor in
                hovered ? ToolbarTipKey.Tip(title: title, detail: warning, anchor: anchor) : nil
            }
            .onHover { hovered = $0 }
            .animation(.easeOut(duration: 0.1), value: hovered)
            .accessibilityLabel(title)
    }
}

/// The hovered control's tip, handed up to its panel to draw.
private struct ToolbarTipKey: PreferenceKey {
    struct Tip {
        let title: String
        let detail: String?
        let anchor: Anchor<CGRect>
    }

    static let defaultValue: Tip? = nil

    static func reduce(value: inout Tip?, nextValue: () -> Tip?) {
        value = value ?? nextValue()
    }
}

/// The instant tip: the title, and the warning under it in orange when there is one.
private struct ToolbarTip: View {
    let title: String
    let detail: String?

    var body: some View {
        VStack(spacing: 2) {
            Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(Color.theme(.tipText))
            if let detail {
                Text(detail).font(.system(size: 11)).foregroundStyle(Color.theme(.warning))
            }
        }
        .multilineTextAlignment(.center)
        .fixedSize()
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.theme(.tipBackground)))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.theme(.tipEdge), lineWidth: 1))
    }
}
