import SwiftUI
import LightshotKit

/// The window-capture overlay surface (stories 6–7): a dimmed full-screen canvas that highlights the
/// window under the pointer so the user sees exactly what a click will grab.
/// Content, not chrome (spec 0008): the same colours in Light and Dark, since it is read against the screen.
///
/// A thin projection of `WindowHoverOverlayModel`: it punches the hovered window's frame out of the
/// dimming and outlines it, and routes pointer moves/clicks into the model. Keyboard resolution
/// (Escape/Return) is handled by the hosting window, not here. Coordinates are screen points at 1:1
/// with the overlay window — no projection.
struct WindowHoverOverlayView: View {
    @State private var model: WindowHoverOverlayModel

    init(model: WindowHoverOverlayModel) {
        _model = State(initialValue: model)
    }

    var body: some View {
        Canvas { context, size in
            draw(into: &context, size: size)
        }
        .contentShape(Rectangle())
        .onContinuousHover { phase in
            switch phase {
            case let .active(location): model.hover(at: Point(location))
            case .ended: model.hoverEnded()
            }
        }
        // A zero-distance drag registers the click and gives its location; the model captures the
        // window under it on mouse-up.
        .gesture(
            DragGesture(minimumDistance: 0)
                .onEnded { model.click(at: Point($0.location)) }
        )
        .ignoresSafeArea()
    }

    private func draw(into context: inout GraphicsContext, size: CGSize) {
        // The hovered window shows through at full brightness — the live preview of what a click
        // will capture.
        let box = model.hovered?.frame.standardized.cgRect
        OverlayCanvas.dim(&context, size: size, punchingOut: box)
        guard let box else { return }
        // Outline the target so the highlight reads even against a bright window.
        context.stroke(Path(box), with: .color(.white), style: StrokeStyle(lineWidth: 2))
    }
}
