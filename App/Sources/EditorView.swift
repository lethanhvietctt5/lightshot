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

    init(
        document: AnnotationDocument,
        onCopy: @escaping (AnnotationDocument) -> Void,
        onDone: @escaping (AnnotationDocument) -> Void,
        onSaveAs: @escaping (AnnotationDocument) -> Void
    ) {
        _model = State(initialValue: EditorModel(document: document, copy: onCopy, done: onDone, saveAs: onSaveAs))
    }

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            toolbar
            Divider()
            optionsBar
            Divider()
            canvas
        }
        .background { editingShortcuts }
        .frame(minWidth: 760, minHeight: 520)
    }

    // MARK: - Toolbar

    /// Top row: the tools on the left, the output actions on the right.
    private var toolbar: some View {
        HStack(spacing: 12) {
            toolPalette
            Spacer()
            outputActions
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
        // Tooltips hang below their buttons, over the rows that follow.
        .zIndex(2)
    }

    /// Second row: the style controls for the active tool or selection. Kept off the tool row
    /// so the larger tool buttons and the contextual pickers both fit at the minimum width.
    private var optionsBar: some View {
        HStack(spacing: 12) {
            styleControls
            arrowControls
            redactionControls
            if model.canResetCrop {
                Divider().frame(height: 20)
                Button("Reset Crop") { model.resetCrop() }
                    .help("Restore the full image (⌘Z also reverses)")
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .frame(height: 40)
        .background(.bar)
        .zIndex(1)
    }

    private var toolPalette: some View {
        HStack(spacing: 4) {
            ForEach(EditorModel.Tool.allCases) { tool in
                Button {
                    model.selectTool(tool)
                } label: {
                    Image(systemName: tool.symbol)
                        .font(.system(size: 17, weight: .medium))
                        .frame(width: Self.toolButtonSize.width, height: Self.toolButtonSize.height)
                        // The whole button is the target, not just the glyph's painted pixels.
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .background(model.tool == tool ? Color.accentColor.opacity(0.25) : .clear, in: RoundedRectangle(cornerRadius: 7))
                .instantTooltip(tool.title)
                .accessibilityLabel(tool.title)
                .accessibilityHint(tool.help)
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

    /// The arrow style picker, shown while drawing arrows or with one selected (which it
    /// restyles in place). Each button draws its style with the same geometry as the canvas.
    @ViewBuilder
    private var arrowControls: some View {
        if model.showsArrowControls {
            Divider().frame(height: 20)
            HStack(spacing: 4) {
                ForEach(ArrowStyle.allCases, id: \.self) { arrowStyle in
                    Button {
                        model.setArrowStyle(arrowStyle)
                    } label: {
                        ArrowStyleIcon(style: arrowStyle)
                            .frame(width: 40, height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .background(model.arrowStyle == arrowStyle ? Color.accentColor.opacity(0.25) : .clear, in: RoundedRectangle(cornerRadius: 6))
                    .instantTooltip(arrowStyle.title)
                    .accessibilityLabel(arrowStyle.title)
                    .accessibilityHint(arrowStyle.help)
                }
            }
        }
    }

    /// The redaction style picker and strength slider, shown while the redact tool is active
    /// or a redaction is selected (which they restyle in place). Pixelate is the default, but
    /// blackout is the only style framed as secure; blur/pixelate carry an explicit "not
    /// secure" warning so they are never mistaken for secret-safe redaction (story 24).
    @ViewBuilder
    private var redactionControls: some View {
        if model.showsRedactionControls {
            Divider().frame(height: 20)
            Picker("Redaction style", selection: Binding(
                get: { model.redactionStyle }, set: { model.setRedactionStyle($0) }
            )) {
                Text("Pixelate").tag(RedactionStyle.pixelate)
                Text("Blur").tag(RedactionStyle.blur)
                Text("Blackout").tag(RedactionStyle.blackout)
            }
            .pickerStyle(.segmented)
            .controlSize(.large)
            .labelsHidden()
            .fixedSize()
            .help(redactionHelp)

            if model.redactionStyle != .blackout {
                HStack(spacing: 4) {
                    Image(systemName: "circle.lefthalf.filled").foregroundStyle(.secondary)
                    Slider(
                        value: Binding(get: { model.redactionStrength }, set: { model.setRedactionStrength($0) }),
                        in: 0...1,
                        onEditingChanged: { editing in if !editing { model.commitStyleEdit() } }
                    )
                    .frame(width: 90)
                }
                .help("Intensity")
            }

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

    /// The editor's only visible actions (spec 0004): Save As…, Copy, Done.
    private var outputActions: some View {
        HStack(spacing: 8) {
            Button("Save As…") { model.saveToDiskAs() }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .help("Save As… (⇧⌘S)")

            Button("Copy") { model.copyToClipboard() }
                .keyboardShortcut("c", modifiers: .command)
                .help("Copy to clipboard (⌘C)")

            // ⌘S is the finishing gesture (LIG-23): the image lands on the clipboard and the editor
            // gets out of the way. It never writes a file — that's Save As….
            Button("Done") { model.copyAndClose() }
                .keyboardShortcut("s", modifiers: .command)
                .buttonStyle(.borderedProminent)
                .help("Copy to clipboard and close (⌘S)")
        }
        .controlSize(.large)
    }

    /// The editing commands that lost their toolbar buttons (spec 0004) but keep their standard
    /// keys, so a mistake can still be undone or deleted. Invisible and out of the layout.
    private var editingShortcuts: some View {
        Group {
            Button("Undo") { model.undo() }
                .disabled(!model.canUndo)
                .keyboardShortcut("z", modifiers: .command)
            Button("Redo") { model.redo() }
                .disabled(!model.canRedo)
                .keyboardShortcut("z", modifiers: [.command, .shift])
            Button("Delete") { model.deleteSelection() }
                .disabled(!model.hasSelection)
                .keyboardShortcut(.delete, modifiers: [])
            Button("Send Backward") { model.sendBackward() }
                .disabled(!model.hasSelection)
                .keyboardShortcut("[", modifiers: .command)
            Button("Bring Forward") { model.bringForward() }
                .disabled(!model.hasSelection)
                .keyboardShortcut("]", modifiers: .command)
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }

    // MARK: - Canvas

    private var canvas: some View {
        GeometryReader { geo in
            let projection = CanvasProjection(
                imageSize: model.baseSize, viewSize: Size(geo.size), inset: Self.canvasInset
            )
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
                    for (index, element) in model.displayElements.enumerated() {
                        draw(element, redactionPatch: model.redactionPatch(at: index), into: context, projection: projection)
                    }
                    if let draft = model.draftElement {
                        draw(draft, redactionPatch: model.draftRedactionPatch, into: context, projection: projection)
                    }
                    if let box = model.selectionBox {
                        drawSelection(box, into: context, projection: projection)
                    }
                    if let endpoints = model.selectionEndpoints {
                        drawHandles(at: endpoints, size: 9, round: true, stroke: .accentColor, into: context, projection: projection)
                    }
                    if let crop = model.cropFrame {
                        drawCropOverlay(
                            crop, imageBounds: model.imageBounds, showHandles: model.isCropping,
                            into: context, projection: projection
                        )
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

    private static let toolButtonSize = CGSize(width: 36, height: 32)
    /// Clear space kept between the image and the canvas edges, in points.
    private static let canvasInset: Double = 24
}

// MARK: - Element drawing

private func draw(
    _ element: AnnotationElement, redactionPatch: RedactionPatch?,
    into context: GraphicsContext, projection: CanvasProjection
) {
    let color = element.style.color.color
    let lineWidth = max(element.style.strokeWidth * projection.scale, 0.5)
    let stroke = StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round)

    switch element.kind {
    case let .line(from, to):
        context.stroke(segment(projection.toView(from), projection.toView(to)), with: .color(color), style: stroke)

    case let .arrow(from, to, bend, arrowStyle):
        // Shares its geometry with the flatten render (`arrowShape`) so the on-screen
        // preview and the exported image draw the same arrow.
        let shape = arrowShape(
            from: projection.toView(from), to: projection.toView(to), bend: bend.map(projection.toView),
            style: arrowStyle, lineWidth: Double(lineWidth)
        )
        draw(shape, color: color, into: context)

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

    case let .redaction(rect, redactionStyle, _, _):
        switch redactionStyle {
        case .blackout:
            // Exact preview: an opaque black fill is what the export produces.
            context.fill(Path(projection.toView(rect).cgRect), with: .color(.black))
        case .blur, .pixelate:
            // Exact preview too: the patch is cut by the same code `render` exports with
            // (see `RedactionBackdrop`), over everything beneath this element.
            guard let redactionPatch else { break }
            context.draw(
                Image(decorative: redactionPatch.image, scale: 1),
                in: projection.toView(redactionPatch.rect).cgRect
            )
        }
    }
}

/// Paints an `ArrowShape` whose points are already in view space.
private func draw(_ shape: ArrowShape, color: Color, into context: GraphicsContext) {
    var path = Path()
    for element in shape.path {
        switch element {
        case let .move(p): path.move(to: p.cgPoint)
        case let .line(p): path.addLine(to: p.cgPoint)
        case let .quadCurve(to, control): path.addQuadCurve(to: to.cgPoint, control: control.cgPoint)
        case .close: path.closeSubpath()
        }
    }
    switch shape.paint {
    case let .fill(rounding):
        context.fill(path, with: .color(color))
        if rounding > 0 {
            context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: rounding, lineJoin: .round))
        }
    case let .stroke(width):
        context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round))
    }
}

/// A name tag shown under a control the instant the pointer is over it — the system `.help`
/// tooltip waits over a second, too long to learn an icon-only palette by sweeping across it.
private struct InstantTooltip: ViewModifier {
    let text: String
    @State private var isHovered = false

    func body(content: Content) -> some View {
        content
            .onHover { isHovered = $0 }
            .overlay(alignment: .bottom) {
                if isHovered {
                    // A zero-size anchor on the control's bottom edge; the tag hangs from it, so
                    // it sits just below the control instead of covering it.
                    Color.clear.frame(width: 0, height: 0).overlay(alignment: .top) {
                        Text(text)
                            .font(.caption)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 5))
                            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.separator))
                            .shadow(color: .black.opacity(0.15), radius: 3, y: 1)
                            .fixedSize()
                            .padding(.top, 4)
                            .allowsHitTesting(false)
                    }
                }
            }
    }
}

private extension View {
    func instantTooltip(_ text: String) -> some View { modifier(InstantTooltip(text: text)) }
}

/// A toolbar glyph for an arrow style, drawn with the canvas's own arrow geometry.
private struct ArrowStyleIcon: View {
    let style: ArrowStyle

    var body: some View {
        Canvas { context, size in
            let tail = Point(x: 4, y: Double(size.height) - 6)
            let tip = Point(x: Double(size.width) - 4, y: 6)
            // New bendable arrows start straight; the glyph still bows so the style reads as bendable.
            let mid = arrowMidpoint(tail, tip)
            let bow = Point(x: mid.x - (tip.y - tail.y) * 0.18, y: mid.y + (tip.x - tail.x) * 0.18)
            let shape = arrowShape(
                from: tail, to: tip, bend: style.isBendable ? bow : nil,
                style: style, lineWidth: 2.4
            )
            draw(shape, color: .primary, into: context)
        }
    }
}

private extension ArrowStyle {
    var title: String {
        switch self {
        case .standard: return "Standard"
        case .fancy: return "Fancy"
        case .curved: return "Curved"
        case .double: return "Double"
        }
    }

    var help: String {
        switch self {
        case .standard: return "Standard arrow"
        case .fancy: return "Fancy arrow"
        case .curved: return "Curved arrow — drawn straight; drag its middle handle to bend it"
        case .double: return "Double-headed arrow — drawn straight; drag its middle handle to bend it"
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
    drawHandles(on: box, size: 7, stroke: .accentColor, into: context, projection: projection)
}

/// Draws the eight resize handles of `box` (image space) as small white squares. Shared by
/// the selection outline and the crop overlay so their handles stay visually identical.
private func drawHandles(
    on box: Rect, size: CGFloat, stroke: Color,
    into context: GraphicsContext, projection: CanvasProjection
) {
    drawHandles(
        at: Handle.allCases.map { handlePoint($0, in: box) }, size: size, round: false,
        stroke: stroke, into: context, projection: projection
    )
}

/// Draws a handle at each image-space point — round for a line or arrow's endpoints, square
/// for a bounding box's — so the two kinds of grab read differently at a glance.
private func drawHandles(
    at points: [Point], size: CGFloat, round: Bool, stroke: Color,
    into context: GraphicsContext, projection: CanvasProjection
) {
    for point in points {
        let p = projection.toView(point).cgPoint
        let square = CGRect(x: p.x - size / 2, y: p.y - size / 2, width: size, height: size)
        let path = Path(roundedRect: square, cornerRadius: round ? size / 2 : 1.5)
        context.fill(path, with: .color(.white))
        context.stroke(path, with: .color(stroke), lineWidth: 1)
    }
}

/// Draws the crop framing: everything outside the crop rect is dimmed so the excluded
/// area reads at a glance, the crop edge is outlined, and — while the crop tool is active —
/// eight resize handles are drawn to grab. All geometry is projected from image space, so
/// the frame stays anchored to the same pixels the export will keep.
private func drawCropOverlay(
    _ frame: Rect, imageBounds: Rect, showHandles: Bool,
    into context: GraphicsContext, projection: CanvasProjection
) {
    let full = projection.toView(imageBounds).cgRect
    let crop = projection.toView(frame).cgRect

    // Dim the ring between the image and the crop rect (even-odd fills outside the inner rect).
    var mask = Path(full)
    mask.addRect(crop)
    context.fill(mask, with: .color(.black.opacity(0.45)), style: FillStyle(eoFill: true))

    context.stroke(Path(crop), with: .color(.white), style: StrokeStyle(lineWidth: 1))

    guard showHandles else { return }
    drawHandles(on: frame, size: 8, stroke: .black.opacity(0.6), into: context, projection: projection)
}

private func segment(_ a: Point, _ b: Point) -> Path { segment(from: a.cgPoint, to: b.cgPoint) }

private func segment(from a: CGPoint, to b: CGPoint) -> Path {
    var path = Path()
    path.move(to: a)
    path.addLine(to: b)
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
