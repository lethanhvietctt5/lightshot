import SwiftUI
import LightshotKit

/// The Settings swatch for the click highlight (story 29): "Click here to preview" draws the halo
/// under the pointer and plays the click ring with the chosen style, size and colour, through the
/// same `ClickHighlightModel` the recorder uses.
struct ClickHighlightPreview: View {
    let settings: ClickHighlightSettings
    @State private var model: ClickHighlightModel
    @State private var started = Date()

    init(settings: ClickHighlightSettings) {
        self.settings = settings
        _model = State(initialValue: ClickHighlightModel(settings: settings))
    }

    var body: some View {
        TimelineView(.animation) { context in
            Canvas { graphics, size in
                let now = context.date.timeIntervalSince(started)
                var live = model
                live.prune(at: now)
                for circle in live.circles(at: now) {
                    let rect = CGRect(x: circle.center.x - circle.radius, y: circle.center.y - circle.radius,
                                      width: circle.radius * 2, height: circle.radius * 2)
                    let color = Self.color(for: settings.color).opacity(circle.opacity)
                    if circle.filled {
                        graphics.fill(Path(ellipseIn: rect), with: .color(color))
                    } else {
                        graphics.stroke(Path(ellipseIn: rect), with: .color(color), lineWidth: max(2, circle.radius * 0.18))
                    }
                }
                if live.pointer == nil {
                    let label = graphics.resolve(Text("Click here to preview").font(.caption).foregroundColor(.secondary))
                    graphics.draw(label, at: CGPoint(x: size.width / 2, y: size.height / 2))
                }
            }
        }
        .frame(height: 90)
        .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
        .onContinuousHover { phase in
            if case let .active(location) = phase { model.pointerMoved(to: Point(location)) }
        }
        .gesture(DragGesture(minimumDistance: 0).onEnded { value in
            model.clicked(at: Point(value.location), time: Date().timeIntervalSince(started))
        })
        .onChange(of: settings) { _, new in model = ClickHighlightModel(settings: new) }
    }

    static func color(for color: CursorHighlightColor) -> Color {
        guard let rgb = color.rgb else { return .accentColor }
        return Color(red: rgb.red, green: rgb.green, blue: rgb.blue)
    }
}
