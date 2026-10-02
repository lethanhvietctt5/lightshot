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

/// The adjustable Capture Area surface (spec 0016): the dimmed canvas with the selection's border,
/// the corner brackets and edge bars over its eight handles, the live readout, and a **Capture**
/// button at the selection. A thin projection of `AdjustableSelectionOverlayModel`; Return, Escape
/// and the arrow keys come from the hosting window. Coordinates are screen points at 1:1.
struct AdjustableSelectionOverlayView: View {
    @State private var model: AdjustableSelectionOverlayModel
    /// The Capture button's rendered size, measured, so placement and clamping use the real thing.
    @State private var buttonSize = CGSize(width: 124, height: 36)

    init(model: AdjustableSelectionOverlayModel) {
        _model = State(initialValue: model)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Canvas { context, size in
                draw(into: &context, size: size)
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case let .active(location): model.hover(at: Point(location))
                case .ended: model.hoverEnded()
                }
                model.cursor.nsCursor.set()
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged {
                        model.dragChanged(to: Point($0.location))
                        model.cursor.nsCursor.set()
                    }
                    .onEnded {
                        model.dragEnded(at: Point($0.location))
                        model.cursor.nsCursor.set()
                    }
            )

            if model.showsControls, let rect = model.selection.rect?.cgRect {
                GeometryReader { geometry in
                    CaptureButton(action: model.confirm)
                        .fixedSize()
                        .onGeometryChange(for: CGSize.self) { $0.size } action: { buttonSize = $0 }
                        .position(Self.captureButtonCenter(for: rect, button: buttonSize, in: geometry.size))
                }
            }
        }
        .ignoresSafeArea()
        .onChange(of: model.cursor) { _, cursor in cursor.nsCursor.set() }
        .onAppear { model.cursor.nsCursor.set() }
    }

    private func draw(into context: inout GraphicsContext, size: CGSize) {
        let box = model.hasSelection ? model.selection.rect?.cgRect : nil
        OverlayCanvas.dim(&context, size: size, punchingOut: box)
        guard let box else { return }

        context.stroke(Path(box), with: .color(.white), style: StrokeStyle(lineWidth: 1))
        if model.showsControls {
            OverlayCanvas.drawSelectionChrome(&context, around: box)
        }
        if let px = model.pixelSize {
            OverlayCanvas.drawReadout(&context, width: px.width, height: px.height, around: box)
        }
    }

    // MARK: - Capture button placement

    private static let gap: CGFloat = 10
    /// The room the readout pill takes on its side of the selection, its gap included. A little
    /// more than `drawReadout` needs (its pill is about 21 pt tall, 8 pt off the selection), so the
    /// button may sit a few points further out than strictly necessary, but never on the pill.
    private static let readoutClearance: CGFloat = 30

    /// Centred under the selection; above it when there is no room below; inside its bottom edge
    /// when neither fits. Never over the readout — `OverlayCanvas.drawReadout` puts the pill above
    /// the selection, or below it when there is no room above — and clamped to the display.
    static func captureButtonCenter(for rect: CGRect, button: CGSize, in size: CGSize) -> CGPoint {
        let buttonHeight = button.height
        let readoutBelow = rect.minY < readoutClearance
        let belowTop = rect.maxY + gap + (readoutBelow ? readoutClearance : 0)
        let aboveBottom = rect.minY - gap - (readoutBelow ? 0 : readoutClearance)
        let y: CGFloat
        if belowTop + buttonHeight <= size.height {
            y = belowTop + buttonHeight / 2
        } else if aboveBottom - buttonHeight >= 0 {
            y = aboveBottom - buttonHeight / 2
        } else {
            y = max(rect.maxY - gap - buttonHeight / 2, buttonHeight / 2)
        }
        let x = min(max(rect.midX, button.width / 2), size.width - button.width / 2)
        return CGPoint(x: x, y: y)
    }
}

/// The adjustable selection's one action, styled like the recorder toolbar's record rows: a slate
/// panel with the glyph, the title and the ↩ shortcut, lit under the pointer.
private struct CaptureButton: View {
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "camera.viewfinder").font(.system(size: 14, weight: .medium))
                Text("Capture").font(.system(size: 14, weight: .semibold))
                Text("↩").font(.system(size: 13)).foregroundStyle(Color.theme(.textStrong))
            }
            .padding(.horizontal, 14)
            .frame(height: 36)
            .contentShape(Rectangle())
            .background(isHovered ? Color.theme(.rowHover) : Color.clear)
        }
        .buttonStyle(.plain)
        .clipShape(RoundedRectangle(cornerRadius: ToolbarChrome.panelRadius))
        .toolbarPanel(edge: .strong)
        .onHover { isHovered = $0 }
    }
}
