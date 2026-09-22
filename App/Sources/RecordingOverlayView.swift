import SwiftUI
import LightshotKit

/// The recording overlay surface (spec 0006, stories 3–7): a dimmed full-screen canvas with the
/// editable selection — border, eight handles, live pixel readout — the hovered window's highlight
/// before anything is selected, and a small control strip: aspect ratio, typed width/height,
/// Fullscreen, and the keys that start or cancel.
///
/// A thin projection of `RecordingOverlayModel`: drawing reads the model, gestures write to it.
/// Escape/Return/arrows are handled by the hosting window. Coordinates are screen points at 1:1.
struct RecordingOverlayView: View {
    @State private var model: RecordingOverlayModel
    @State private var widthText = ""
    @State private var heightText = ""

    init(model: RecordingOverlayModel) {
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
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { model.dragChanged(to: Point($0.location)) }
                    .onEnded { model.dragEnded(at: Point($0.location)) }
            )

            controls
        }
        .ignoresSafeArea()
        .onChange(of: model.pixelSize?.width) { _, _ in syncFields() }
        .onChange(of: model.pixelSize?.height) { _, _ in syncFields() }
        .onAppear(perform: syncFields)
    }

    // MARK: - Control strip

    /// Ratio / size / Fullscreen, placed just below the selection (above it near the bottom of the
    /// screen), or top-centre while nothing is selected.
    private var controls: some View {
        GeometryReader { geometry in
            HStack(spacing: 10) {
                Picker("Ratio", selection: Binding(get: { model.ratio }, set: { model.setRatio($0) })) {
                    ForEach(AspectRatio.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .frame(width: 96)

                if model.hasSelection {
                    sizeField("W", text: $widthText) { model.setWidth($0) }
                    Text("×").foregroundStyle(.secondary)
                    sizeField("H", text: $heightText) { model.setHeight($0) }
                }

                Button("Fullscreen") { model.chooseFullscreen() }

                Text(model.hasSelection ? "Return to start · Esc to cancel" : "Drag an area or click a window · Esc to cancel")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .controlSize(.small)
            .padding(8)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            .position(controlsCenter(in: geometry.size))
        }
    }

    private func sizeField(_ label: String, text: Binding<String>, commit: @escaping (Double) -> Void) -> some View {
        TextField(label, text: text)
            .textFieldStyle(.roundedBorder)
            .frame(width: 58)
            .multilineTextAlignment(.trailing)
            .onSubmit {
                // Fields are in native pixels like the readout; the model works in points.
                if let pixels = Double(text.wrappedValue), pixels > 0 { commit(pixels / pixelScale) }
                syncFields()
            }
    }

    private var pixelScale: Double {
        guard let px = model.pixelSize, let rect = model.selection.rect, rect.width > 0 else { return 1 }
        return Double(px.width) / rect.width
    }

    private func syncFields() {
        if let px = model.pixelSize {
            widthText = String(px.width)
            heightText = String(px.height)
        }
    }

    private func controlsCenter(in size: CGSize) -> CGPoint {
        let stripHeight: CGFloat = 40
        guard model.hasSelection, let rect = model.selection.rect?.cgRect else {
            return CGPoint(x: size.width / 2, y: 60)
        }
        let below = rect.maxY + 12 + stripHeight / 2
        let y = below + stripHeight / 2 <= size.height ? below : rect.minY - 12 - stripHeight / 2
        return CGPoint(x: min(max(rect.midX, 240), size.width - 240), y: y)
    }

    // MARK: - Canvas

    private func draw(into context: inout GraphicsContext, size: CGSize) {
        // Dim the whole screen, punching the selection (or the hovered window) out with an even-odd
        // fill so the live region shows the real screen through the transparent window.
        var dimmed = Path(CGRect(origin: .zero, size: size))
        let box: CGRect? = model.hasSelection ? model.selection.rect?.cgRect : model.hovered?.frame.cgRect
        if let box { dimmed.addRect(box) }
        context.fill(dimmed, with: .color(.black.opacity(0.45)), style: FillStyle(eoFill: true))

        guard let box else { return }
        context.stroke(Path(box), with: .color(.white), style: StrokeStyle(lineWidth: model.hasSelection ? 1 : 2))

        if model.showsHandles, let rect = model.selection.rect {
            for handle in Handle.allCases {
                let p = handlePoint(handle, in: rect)
                let square = CGRect(x: p.x - 4, y: p.y - 4, width: 8, height: 8)
                context.fill(Path(square), with: .color(.white))
                context.stroke(Path(square), with: .color(.black.opacity(0.6)), style: StrokeStyle(lineWidth: 1))
            }
        }

        if let px = model.pixelSize {
            let label = context.resolve(
                Text("\(px.width) × \(px.height)")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white)
            )
            let textSize = label.measure(in: CGSize(width: 400, height: 40))
            let aboveY = box.minY - textSize.height / 2 - 8
            let center = CGPoint(
                x: box.midX,
                y: aboveY - textSize.height / 2 >= 0 ? aboveY : box.maxY + textSize.height / 2 + 8
            )
            let pill = CGRect(
                x: center.x - textSize.width / 2 - 6, y: center.y - textSize.height / 2 - 3,
                width: textSize.width + 12, height: textSize.height + 6
            )
            context.fill(Path(roundedRect: pill, cornerRadius: 4), with: .color(.black.opacity(0.6)))
            context.draw(label, at: center, anchor: .center)
        }
    }
}
