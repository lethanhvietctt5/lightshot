import SwiftUI
import LightshotKit

/// The pre-capture selection overlay surface: a full-screen dimmed canvas with a live selection
/// rect and a pixel-dimension readout (stories 2–3). Releasing the drag confirms (LIG-23), so
/// there are no resize handles — nothing is adjustable after the mouse comes up.
///
/// A thin projection of `SelectionOverlayModel`: it draws the model's `selection` and routes the
/// drag into it. Keyboard resolution (Escape) is handled by the hosting window, not here, so
/// the overlay needs no focus plumbing. Coordinates are screen points at 1:1 — no projection.
struct SelectionOverlayView: View {
    @State private var model: SelectionOverlayModel

    init(model: SelectionOverlayModel) {
        _model = State(initialValue: model)
    }

    var body: some View {
        Canvas { context, size in
            draw(into: &context, size: size)
        }
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { model.dragChanged(to: Point($0.location)) }
                .onEnded { model.dragEnded(to: Point($0.location)) }
        )
        .ignoresSafeArea()
    }

    private func draw(into context: inout GraphicsContext, size: CGSize) {
        let box = model.hasSelection ? model.selection?.standardized.cgRect : nil
        OverlayCanvas.dim(&context, size: size, punchingOut: box)
        guard let box else { return }

        // Selection border.
        context.stroke(Path(box), with: .color(.white), style: StrokeStyle(lineWidth: 1))

        // Live pixel-dimension readout (story 3).
        if let px = model.pixelSize {
            OverlayCanvas.drawReadout(&context, width: px.width, height: px.height, around: box)
        }
    }
}
