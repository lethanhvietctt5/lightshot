import SwiftUI
import AppKit
import LightshotKit

/// The annotation editor (LIG-9): a captured image plus a live vector-drawing surface.
///
/// The view is a thin projection of `EditorModel` — it renders `document` elements, routes
/// gestures into image space, and binds the palette controls. All editing rules (add,
/// select, move, resize, style, undo/redo) live in the model and the pure `AnnotationDocument`.
struct EditorView: View {
    @State private var model: EditorModel
    @FocusState private var textFieldFocused: Bool

    init(document: AnnotationDocument, onCopy: @escaping (AnnotationDocument) -> Void) {
        _model = State(initialValue: EditorModel(document: document, copy: onCopy))
    }

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            toolbar
            Divider()
            canvas
        }
        .frame(minWidth: 640, minHeight: 460)
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 12) {
            toolPalette
            Divider().frame(height: 20)
            styleControls
            redactionControls
            Spacer()
            historyControls
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private var toolPalette: some View {
        HStack(spacing: 2) {
            ForEach(EditorModel.Tool.allCases) { tool in
                Button {
                    model.selectTool(tool)
                } label: {
                    Image(systemName: tool.symbol)
                        .frame(width: 26, height: 22)
                }
                .buttonStyle(.plain)
                .background(model.tool == tool ? Color.accentColor.opacity(0.25) : .clear, in: RoundedRectangle(cornerRadius: 5))
                .help(tool.help)
            }
        }
    }

    @ViewBuilder
    private var styleControls: some View {
        ColorPicker("", selection: Binding(
            get: { model.style.color.color },
            set: { model.setColor(RGBAColor($0)) }
        ), supportsOpacity: false)
        .labelsHidden()
        .help("Color")

        HStack(spacing: 4) {
            Image(systemName: "lineweight").foregroundStyle(.secondary)
            Slider(
                value: Binding(get: { model.style.strokeWidth }, set: { model.setStrokeWidth($0) }),
                in: 1...24,
                onEditingChanged: { editing in if !editing { model.commitStyleEdit() } }
            )
            .frame(width: 90)
        }
        .help("Stroke width")

        HStack(spacing: 4) {
            Image(systemName: "textformat.size").foregroundStyle(.secondary)
            Slider(
                value: Binding(get: { model.style.fontSize }, set: { model.setFontSize($0) }),
                in: 9...96,
                onEditingChanged: { editing in if !editing { model.commitStyleEdit() } }
            )
            .frame(width: 90)
        }
        .help("Font size")
    }

    /// The redaction style picker, shown only while the redact tool is active. Blackout is
    /// the default and the only style framed as secure; blur/pixelate carry an explicit
    /// "not secure" warning so they are never mistaken for secret-safe redaction (story 24).
    @ViewBuilder
    private var redactionControls: some View {
        @Bindable var model = model
        if model.tool == .redact {
            Divider().frame(height: 20)
            Picker("Redaction style", selection: $model.redactionStyle) {
                Text("Blackout").tag(RedactionStyle.blackout)
                Text("Blur").tag(RedactionStyle.blur)
                Text("Pixelate").tag(RedactionStyle.pixelate)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help(redactionHelp)

            if model.redactionStyle == .blackout {
                Label("Secure erase", systemImage: "lock.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .labelStyle(.titleAndIcon)
            } else {
                Label("Not secure — visual only", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .labelStyle(.titleAndIcon)
            }
        }
    }

    private var redactionHelp: String {
        switch model.redactionStyle {
        case .blackout:
            return "Blackout replaces the covered pixels with an opaque fill on export — the only secure redaction."
        case .blur:
            return "Blur only obscures the region and can be reversed or inferred. Use Blackout to hide secrets."
        case .pixelate:
            return "Pixelate only obscures the region and can be reversed or inferred. Use Blackout to hide secrets."
        }
    }

    private var historyControls: some View {
        HStack(spacing: 6) {
            Button { model.sendBackward() } label: { Image(systemName: "square.2.layers.3d.bottom.filled") }
                .disabled(!model.hasSelection)
                .keyboardShortcut("[", modifiers: .command)
                .help("Send backward (⌘[)")

            Button { model.bringForward() } label: { Image(systemName: "square.2.layers.3d.top.filled") }
                .disabled(!model.hasSelection)
                .keyboardShortcut("]", modifiers: .command)
                .help("Bring forward (⌘])")

            Divider().frame(height: 20)

            Button { model.deleteSelection() } label: { Image(systemName: "trash") }
                .disabled(!model.hasSelection)
                .keyboardShortcut(.delete, modifiers: [])
                .help("Delete selection")

            Button { model.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                .disabled(!model.canUndo)
                .keyboardShortcut("z", modifiers: .command)
                .help("Undo")

            Button { model.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                .disabled(!model.canRedo)
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .help("Redo")

            Button("Copy") { model.copyToClipboard() }
                .keyboardShortcut("c", modifiers: .command)
                .buttonStyle(.borderedProminent)
        }
    }

    // MARK: - Canvas

    private var canvas: some View {
        GeometryReader { geo in
            let projection = CanvasProjection(imageSize: model.baseSize, viewSize: Size(geo.size))
            let fitted = projection.toView(model.imageBounds).cgRect

            ZStack(alignment: .topLeading) {
                Color(nsColor: .windowBackgroundColor)

                if let nsImage {
                    Image(nsImage: nsImage)
                        .resizable()
                        .frame(width: fitted.width, height: fitted.height)
                        .position(x: fitted.midX, y: fitted.midY)
                }

                Canvas { context, _ in
                    for element in model.displayElements {
                        draw(element, into: context, projection: projection)
                    }
                    if let draft = model.draftElement {
                        draw(draft, into: context, projection: projection)
                    }
                    if let box = model.selectionBox {
                        drawSelection(box, into: context, projection: projection)
                    }
                }
                .contentShape(Rectangle())
                .gesture(dragGesture(projection: projection))
                .simultaneousGesture(doubleClickGesture(projection: projection))

                textEditor(projection: projection)
            }
            .onChange(of: geo.size, initial: true) { _, _ in model.viewScale = projection.scale }
        }
    }

    private func dragGesture(projection: CanvasProjection) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                model.gestureChanged(at: projection.toImage(Point(value.location)))
            }
            .onEnded { value in
                model.gestureEnded(at: projection.toImage(Point(value.location)))
                model.syncStyleToSelection()
                if model.editingTextID != nil { textFieldFocused = true }
            }
    }

    private func doubleClickGesture(projection: CanvasProjection) -> some Gesture {
        SpatialTapGesture(count: 2)
            .onEnded { value in
                if model.doubleClick(at: projection.toImage(Point(value.location))) {
                    textFieldFocused = true
                }
            }
    }

    @ViewBuilder
    private func textEditor(projection: CanvasProjection) -> some View {
        if let id = model.editingTextID,
           let box = model.document.element(id: id)?.kind.boundingBox,
           let style = model.document.element(id: id)?.style {
            let vr = projection.toView(box).cgRect
            TextField("Label", text: Bindable(model).editingText, axis: .horizontal)
                .textFieldStyle(.plain)
                .font(.system(size: style.fontSize * projection.scale))
                .foregroundStyle(style.color.color)
                .frame(width: max(vr.width, 80), alignment: .leading)
                .position(x: vr.minX + max(vr.width, 80) / 2, y: vr.midY)
                .focused($textFieldFocused)
                .onSubmit { model.endTextEditing() }
        }
    }

    private var nsImage: NSImage? { NSImage(data: model.document.baseImage.data) }
}

// MARK: - Element drawing

private func draw(_ element: AnnotationElement, into context: GraphicsContext, projection: CanvasProjection) {
    let color = element.style.color.color
    let lineWidth = max(element.style.strokeWidth * projection.scale, 0.5)
    let stroke = StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round)

    switch element.kind {
    case let .line(from, to):
        context.stroke(segment(projection.toView(from), projection.toView(to)), with: .color(color), style: stroke)

    case let .arrow(from, to):
        let a = projection.toView(from).cgPoint
        let b = projection.toView(to).cgPoint
        context.stroke(segment(from: a, to: b), with: .color(color), style: stroke)
        context.fill(arrowhead(from: a, to: b, lineWidth: lineWidth), with: .color(color))

    case let .rectangle(rect):
        let path = Path(projection.toView(rect).cgRect)
        if let fill = element.style.fill { context.fill(path, with: .color(fill.color)) }
        context.stroke(path, with: .color(color), style: stroke)

    case let .ellipse(rect):
        let path = Path(ellipseIn: projection.toView(rect).cgRect)
        if let fill = element.style.fill { context.fill(path, with: .color(fill.color)) }
        context.stroke(path, with: .color(color), style: stroke)

    case let .freehand(points):
        var path = Path()
        let viewPoints = points.map { projection.toView($0).cgPoint }
        if let first = viewPoints.first {
            path.move(to: first)
            for p in viewPoints.dropFirst() { path.addLine(to: p) }
        }
        context.stroke(path, with: .color(color), style: stroke)

    case let .text(string, box):
        guard !string.isEmpty else { break }
        let origin = projection.toView(box.standardized.origin).cgPoint
        context.draw(
            Text(string).font(.system(size: element.style.fontSize * projection.scale)).foregroundColor(color),
            at: origin, anchor: .topLeading
        )

    case let .stepMarker(number, center, radius):
        let c = projection.toView(center).cgPoint
        let r = radius * projection.scale
        context.fill(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)), with: .color(color))
        context.draw(
            Text(String(number)).font(.system(size: r, weight: .semibold)).foregroundColor(.white),
            at: c, anchor: .center
        )

    case let .highlight(rect):
        // A translucent wash: cap the color's alpha exactly as the flatten does
        // (`render`'s `highlightAlpha`) — capping, not multiplying by opacity — so the canvas
        // and the exported image agree even when the chosen color is already translucent.
        var wash = element.style.color
        wash.alpha = min(element.style.color.alpha, highlightPreviewAlpha)
        context.fill(Path(projection.toView(rect).cgRect), with: .color(wash.color))

    case let .redaction(rect, redactionStyle):
        let path = Path(projection.toView(rect).cgRect)
        switch redactionStyle {
        case .blackout:
            // Exact preview: an opaque black fill is what the export produces.
            context.fill(path, with: .color(.black))
        case .blur, .pixelate:
            // The real blur/pixelate is applied by `render` on export; on canvas we show a
            // translucent scrim so the region reads as "obscured, not erased" (visibly
            // different from blackout's solid fill) without re-implementing the filter here.
            context.fill(path, with: .color(.gray.opacity(0.55)))
        }
    }
}

/// Alpha of the highlighter preview wash — mirrors `render`'s `highlightAlpha` so the canvas
/// and the exported image agree.
private let highlightPreviewAlpha: Double = 0.35

private func drawSelection(_ box: Rect, into context: GraphicsContext, projection: CanvasProjection) {
    let vr = projection.toView(box).cgRect
    context.stroke(
        Path(vr), with: .color(.accentColor),
        style: StrokeStyle(lineWidth: 1, dash: [4, 3])
    )
    let size: CGFloat = 7
    for handle in Handle.allCases {
        let p = projection.toView(handlePoint(handle, in: box)).cgPoint
        let square = CGRect(x: p.x - size / 2, y: p.y - size / 2, width: size, height: size)
        context.fill(Path(roundedRect: square, cornerRadius: 1.5), with: .color(.white))
        context.stroke(Path(roundedRect: square, cornerRadius: 1.5), with: .color(.accentColor), lineWidth: 1)
    }
}

private func segment(_ a: Point, _ b: Point) -> Path { segment(from: a.cgPoint, to: b.cgPoint) }

private func segment(from a: CGPoint, to b: CGPoint) -> Path {
    var path = Path()
    path.move(to: a)
    path.addLine(to: b)
    return path
}

private func arrowhead(from: CGPoint, to: CGPoint, lineWidth: CGFloat) -> Path {
    // Shares its trigonometry with the flatten render (`arrowheadPoints`) so the on-screen
    // preview and the exported image draw the same head.
    let corners = arrowheadPoints(from: Point(from), to: Point(to), lineWidth: Double(lineWidth))
    guard corners.count == 3 else { return Path() }
    var path = Path()
    path.move(to: corners[0].cgPoint)
    path.addLine(to: corners[1].cgPoint)
    path.addLine(to: corners[2].cgPoint)
    path.closeSubpath()
    return path
}

// MARK: - Bridging between domain geometry and CoreGraphics/SwiftUI

extension Point {
    init(_ p: CGPoint) { self.init(x: Double(p.x), y: Double(p.y)) }
    var cgPoint: CGPoint { CGPoint(x: x, y: y) }
}

extension Size {
    init(_ s: CGSize) { self.init(width: Double(s.width), height: Double(s.height)) }
}

extension Rect {
    var cgRect: CGRect {
        let s = standardized
        return CGRect(x: s.minX, y: s.minY, width: s.width, height: s.height)
    }
}

extension RGBAColor {
    /// Reads a SwiftUI `Color`'s sRGB components (via `NSColor`) into the domain color.
    init(_ color: Color) {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? NSColor.red
        self.init(
            red: Double(ns.redComponent), green: Double(ns.greenComponent),
            blue: Double(ns.blueComponent), alpha: Double(ns.alphaComponent)
        )
    }

    var color: Color { Color(.sRGB, red: red, green: green, blue: blue, opacity: alpha) }
}
