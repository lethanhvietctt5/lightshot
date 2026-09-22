import SwiftUI
import LightshotKit

/// The Settings swatch for the click highlight (story 29): "Click here to preview" draws the halo
/// under the pointer and plays the click ring with the chosen style, size and colour, through the
/// same `ClickHighlightModel` the recorder uses.
struct ClickHighlightPreview: View {
    let settings: ClickHighlightSettings
    @State private var model: ClickHighlightModel
    @State private var started = Date()
    @State private var pressed = false

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
                let color = Color(nsColor: settings.color.nsColor)
                for circle in live.circles(at: now) {
                    let path = Path(ellipseIn: circle.bounds.cgRect)
                    if circle.filled { graphics.fill(path, with: .color(color.opacity(circle.opacity))) }
                    if circle.strokeWidth > 0 {
                        graphics.stroke(path, with: .color(color.opacity(circle.opacity)), lineWidth: circle.strokeWidth)
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
        // Ring on mouse-down, as the recorder does (a drag gesture's first change is the press).
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard !pressed else { return }
                pressed = true
                model.clicked(at: Point(value.location), time: Date().timeIntervalSince(started))
            }
            .onEnded { _ in pressed = false })
        .onChange(of: settings) { _, new in model = ClickHighlightModel(settings: new) }
    }
}
