import SwiftUI
import LightshotKit

/// The pre-capture selection overlay surface: a full-screen dimmed canvas with a live selection
/// rect, edge/corner handles, and a pixel-dimension readout (stories 2–4).
///
/// A thin projection of `SelectionOverlayModel`: it draws the model's `selection` and routes the
/// drag into it. Keyboard resolution (Escape/Return) is handled by the hosting window, not here, so
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
        // Dim the whole screen, punching the selection out with an even-odd fill so the live
        // region shows the real screen through the transparent window.
        var dimmed = Path(CGRect(origin: .zero, size: size))
        let box = model.hasSelection ? model.selection?.standardized : nil
        if let box { dimmed.addRect(box.cgRect) }
        context.fill(dimmed, with: .color(.black.opacity(0.45)), style: FillStyle(eoFill: true))

        guard let box else { return }
        let rect = box.cgRect

        // Selection border.
        context.stroke(Path(rect), with: .color(.white), style: StrokeStyle(lineWidth: 1))

        // Edge/corner handles.
        for handle in Handle.allCases {
            let p = handlePoint(handle, in: box).cgPoint
            let dot = CGRect(x: p.x - 3.5, y: p.y - 3.5, width: 7, height: 7)
            context.fill(Path(ellipseIn: dot), with: .color(.white))
            context.stroke(Path(ellipseIn: dot), with: .color(.black.opacity(0.5)), lineWidth: 0.5)
        }

        // Live pixel-dimension readout, in a pill above the selection (or below when near the top).
        if let px = model.pixelSize {
            let label = context.resolve(
                Text("\(px.width) × \(px.height)")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white)
            )
            let textSize = label.measure(in: CGSize(width: 400, height: 40))
            let aboveY = rect.minY - textSize.height / 2 - 8
            let center = CGPoint(
                x: rect.midX,
                y: aboveY - textSize.height / 2 >= 0 ? aboveY : rect.maxY + textSize.height / 2 + 8
            )
            let pill = CGRect(
                x: center.x - textSize.width / 2 - 6,
                y: center.y - textSize.height / 2 - 3,
                width: textSize.width + 12,
                height: textSize.height + 6
            )
            context.fill(Path(roundedRect: pill, cornerRadius: 4), with: .color(.black.opacity(0.6)))
            context.draw(label, at: center, anchor: .center)
        }
    }
}
