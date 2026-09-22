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
                    sizeField("W", text: $widthText) { model.setWidth(pixels: $0) }
                    Text("×").foregroundStyle(.secondary)
                    sizeField("H", text: $heightText) { model.setHeight(pixels: $0) }
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

    /// Fields are in native pixels, like the readout; the model converts to points.
    private func sizeField(_ label: String, text: Binding<String>, commit: @escaping (Double) -> Void) -> some View {
        TextField(label, text: text)
            .textFieldStyle(.roundedBorder)
            .frame(width: 58)
            .multilineTextAlignment(.trailing)
            .onSubmit {
                if let pixels = Double(text.wrappedValue), pixels > 0 { commit(pixels) }
                syncFields()
            }
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
        // The selection — or, before one exists, the hovered window — shows through the dimming.
        let box: CGRect? = model.hasSelection ? model.selection.rect?.cgRect : model.hovered?.frame.cgRect
        OverlayCanvas.dim(&context, size: size, punchingOut: box)
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
            OverlayCanvas.drawReadout(&context, width: px.width, height: px.height, around: box)
        }
    }
}
