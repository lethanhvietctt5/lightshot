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
    /// Keyboard focus of the font-size field. It must not hold focus while the user draws or
    /// presses ⌫ / ⌘Z, so the canvas and the tool buttons take it back.
    @FocusState private var fontSizeFocused: Bool

    init(
        document: AnnotationDocument,
        onCopy: @escaping (AnnotationDocument) -> Void,
        onDone: @escaping (AnnotationDocument) -> Void,
        onSaveAs: @escaping (AnnotationDocument) -> Void
    ) {
        _model = State(initialValue: EditorModel(document: document, copy: onCopy, done: onDone, saveAs: onSaveAs))
    }

    var body: some View {
        canvas
            .background { editingShortcuts }
            .frame(minWidth: 760, minHeight: 520)
            .toolbar { editorToolbar }
    }

    // MARK: - Toolbar

    /// One row in the window's toolbar, beside the traffic lights, as CleanShot lays it out
    /// (LIG-46): Crop, the drawing tools, the options for the active tool or selection, and the
    /// output actions at the trailing edge. On macOS 26 each item is a glass group.
    @ToolbarContentBuilder
    private var editorToolbar: some ToolbarContent {
        if #available(macOS 26.0, *) {
            // Spacers split the row into CleanShot's separate glass groups and push the actions to
            // the trailing edge. `.navigation` items would merge into one group, so these stay
            // `.automatic`, which keeps their order.
            ToolbarItem { toolButton(.crop).padding(.horizontal, Self.groupInset) }
            ToolbarSpacer(.fixed)
            ToolbarItem { toolPalette }
            if showsOptions {
                ToolbarSpacer(.fixed)
                ToolbarItem { options }
            }
            ToolbarSpacer(.flexible)
            // Save As… and Copy as icons sharing one glass group; Done on its own, prominent.
            ToolbarItemGroup {
                saveAsButton.labelStyle(.iconOnly)
                copyButton.labelStyle(.iconOnly)
            }
            ToolbarSpacer(.fixed)
            ToolbarItem {
                doneButton
                    .buttonStyle(.glassProminent)
                    .tint(.accentColor)
            }
        } else {
            ToolbarItem(placement: .navigation) { toolButton(.crop) }
            ToolbarItem(placement: .navigation) { toolPalette }
            if showsOptions {
                ToolbarItem(placement: .navigation) { options }
            }
            ToolbarItemGroup(placement: .primaryAction) {
                saveAsButton
                copyButton
                doneButton.buttonStyle(.borderedProminent)
            }
        }
    }

    /// Room between a group's glass edge and the blue pill of a selected tool at either end, so
    /// the pill never runs into the group's rounded edge.
    private static let groupInset: CGFloat = 4

    private var toolPalette: some View {
        HStack(spacing: 2) {
            ForEach(EditorModel.Tool.allCases.filter { $0 != .crop }) { toolButton($0) }
        }
        .padding(.horizontal, Self.groupInset)
    }

    private func toolButton(_ tool: EditorModel.Tool) -> some View {
        let selected = model.tool == tool
        return Button {
            fontSizeFocused = false
            model.selectTool(tool)
        } label: {
            Image(systemName: tool.symbol)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(selected ? Color.white : Color.primary)
                .frame(width: 32, height: 26)
                .background(Capsule().fill(selected ? Color.accentColor : .clear))
                // The whole button is the target, not just the glyph's painted pixels.
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(tool.title)
        .accessibilityLabel(tool.title)
        .accessibilityHint(tool.help)
    }

    private var showsOptions: Bool { !model.styleFields.isEmpty || model.canResetCrop }

    /// Only what applies to the active tool or the selected element (`EditorModel.styleFields`).
    private var options: some View {
        let fields = model.styleFields
        return HStack(spacing: 10) {
            if fields.contains(.color) { colorControl }
            if fields.contains(.strokeWidth) { strokeWidthControl }
            if fields.contains(.arrowStyle) { arrowControls }
            if fields.contains(.fontSize) { fontSizeControl }
            if fields.contains(.redaction) { redactionControls }
            if model.canResetCrop {
                Button("Reset Crop") { model.resetCrop() }
                    .help("Restore the full image (⌘Z also reverses)")
            }
        }
        .padding(.horizontal, 6)
    }

    /// The number typed into the font-size field; applied on Return, clamped to `fontSizeRange`.
    @State private var fontSizeEntry: Double = Style.default.fontSize
    @State private var initialFocusSettled = false
    private static let fontSizeRange: ClosedRange<Double> = 6...200
    private static let strokeWidths: [Double] = [1, 2, 3, 4, 6, 8, 12, 16, 24]

    private func commitFontSizeEntry() {
        let size = min(max(fontSizeEntry.rounded(), Self.fontSizeRange.lowerBound), Self.fontSizeRange.upperBound)
        fontSizeEntry = size
        model.setFontSize(size)
        model.commitStyleEdit()
        fontSizeFocused = false
    }

    /// A small swatch of the current colour; its menu offers CleanShot-like presets and the
    /// system colour panel for anything else.
    private var colorControl: some View {
        Menu {
            ForEach(Self.palette, id: \.name) { swatch in
                Button {
                    model.setColor(swatch.color)
                    model.commitStyleEdit()
                } label: {
                    Label { Text(swatch.name) } icon: { Image(nsImage: Self.swatchImage(swatch.color, diameter: 12)) }
                }
            }
            Divider()
            Button("Custom…") {
                colorPanel.show(model.style.color) { model.setColor($0) }
            }
        } label: {
            Label { Text("Color") } icon: { Image(nsImage: Self.swatchImage(model.style.color, diameter: 16)) }
                .labelStyle(.iconOnly)
        }
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Color")
    }

    @State private var colorPanel = ColorPanelBridge()

    private static let palette: [(name: String, color: RGBAColor)] = [
        ("Red", RGBAColor(red: 1, green: 0.23, blue: 0.19)),
        ("Orange", RGBAColor(red: 1, green: 0.58, blue: 0)),
        ("Yellow", RGBAColor(red: 1, green: 0.8, blue: 0)),
        ("Green", RGBAColor(red: 0.2, green: 0.78, blue: 0.35)),
        ("Blue", RGBAColor(red: 0, green: 0.48, blue: 1)),
        ("Purple", RGBAColor(red: 0.69, green: 0.32, blue: 0.87)),
        ("Pink", RGBAColor(red: 1, green: 0.18, blue: 0.33)),
        ("Black", RGBAColor(red: 0, green: 0, blue: 0)),
        ("White", RGBAColor(red: 1, green: 1, blue: 1)),
    ]

    /// A filled circle with a thin edge, drawn as a non-template image so menus and the toolbar
    /// keep its colour.
    private static func swatchImage(_ color: RGBAColor, diameter: CGFloat) -> NSImage {
        let image = NSImage(size: NSSize(width: diameter, height: diameter), flipped: false) { rect in
            let circle = NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5))
            NSColor(srgbRed: color.red, green: color.green, blue: color.blue, alpha: color.alpha).setFill()
            circle.fill()
            NSColor.black.withAlphaComponent(0.25).setStroke()
            circle.lineWidth = 1
            circle.stroke()
            return true
        }
        image.isTemplate = false
        return image
    }

    /// The stroke width as a compact menu of sizes; the current one is ticked.
    private var strokeWidthControl: some View {
        Menu {
            Picker("Stroke width", selection: Binding(
                get: { model.style.strokeWidth },
                set: { model.setStrokeWidth($0); model.commitStyleEdit() }
            )) {
                ForEach(Array(Set(Self.strokeWidths + [model.style.strokeWidth])).sorted(), id: \.self) { width in
                    Text("\(Self.points(width)) pt").tag(width)
                }
            }
            .pickerStyle(.inline)
        } label: {
            Label("\(Self.points(model.style.strokeWidth)) pt", systemImage: "lineweight")
                .labelStyle(.titleAndIcon)
        }
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Stroke width")
    }

    private static func points(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)
    }

    private var fontSizeControl: some View {
        HStack(spacing: 4) {
            Image(systemName: "textformat.size").foregroundStyle(.secondary)
            TextField("Size", value: $fontSizeEntry, format: .number.precision(.fractionLength(0)))
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(width: 44)
                .focused($fontSizeFocused)
                .onSubmit { commitFontSizeEntry() }
                .onChange(of: model.style.fontSize) { _, size in fontSizeEntry = size }
                .onAppear { fontSizeEntry = model.style.fontSize }
                // AppKit hands a fresh key window's focus to its first text field; give it
                // back (once) so ⌫ / ⌘Z reach the canvas until the field is clicked.
                .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
                    guard !initialFocusSettled else { return }
                    initialFocusSettled = true
                    DispatchQueue.main.async { fontSizeFocused = false }
                }
        }
        .help("Font size (points in the image)")
    }

    /// The arrow styles, drawing arrows or with one selected (which they restyle in place). Each
    /// button draws its style with the same geometry as the canvas.
    private var arrowControls: some View {
        HStack(spacing: 2) {
            ForEach(ArrowStyle.allCases, id: \.self) { arrowStyle in
                let selected = model.arrowStyle == arrowStyle
                Button {
                    model.setArrowStyle(arrowStyle)
                } label: {
                    ArrowStyleIcon(style: arrowStyle, color: selected ? .white : .primary)
                        .frame(width: 26, height: 18)
                        .padding(.horizontal, 3)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(selected ? Color.accentColor : .clear))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help(arrowStyle.title)
                .accessibilityLabel(arrowStyle.title)
                .accessibilityHint(arrowStyle.help)
            }
        }
    }

    /// The redaction style and strength, drawing a redaction or with one selected (which they
    /// restyle in place). Pixelate is the default, but blackout is the only style framed as
    /// secure; blur/pixelate carry an explicit "not secure" warning so they are never mistaken for
    /// secret-safe redaction (story 24).
    @ViewBuilder
    private var redactionControls: some View {
        Picker("Redaction style", selection: Binding(
            get: { model.redactionStyle }, set: { model.setRedactionStyle($0) }
        )) {
            Text("Pixelate").tag(RedactionStyle.pixelate)
            Text("Blur").tag(RedactionStyle.blur)
            Text("Blackout").tag(RedactionStyle.blackout)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .help(redactionHelp)

        if model.redactionStyle != .blackout {
            Slider(
                value: Binding(get: { model.redactionStrength }, set: { model.setRedactionStrength($0) }),
                in: 0...1,
                onEditingChanged: { editing in if !editing { model.commitStyleEdit() } }
            )
            .frame(width: 80)
            .help("Intensity")
        }

        if model.redactionStyle == .blackout {
            Label("Secure", systemImage: "lock.fill")
                .labelStyle(.titleAndIcon)
                .foregroundStyle(.secondary)
                .help("Blackout is the secure redaction: the covered pixels are replaced on export.")
        } else {
            Label("Not secure", systemImage: "exclamationmark.triangle.fill")
                .labelStyle(.titleAndIcon)
                .foregroundStyle(.orange)
                .help("Visual only — can be reversed or inferred. Use Blackout to hide secrets.")
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

    // MARK: - Output actions (spec 0004): Save As…, Copy, Done

    private var saveAsButton: some View {
        Button { model.saveToDiskAs() } label: {
            Label("Save As…", systemImage: "square.and.arrow.down")
        }
        .keyboardShortcut("s", modifiers: [.command, .shift])
        .help("Save As… (⇧⌘S)")
    }

    private var copyButton: some View {
        Button { model.copyToClipboard() } label: {
            Label("Copy", systemImage: "doc.on.doc")
        }
        .keyboardShortcut("c", modifiers: .command)
        .help("Copy to clipboard (⌘C)")
    }

    /// ⌘S is the finishing gesture (LIG-23): the image lands on the clipboard and the editor gets
    /// out of the way. It never writes a file — that's Save As….
    private var doneButton: some View {
        Button { model.copyAndClose() } label: {
            Text("Done").fontWeight(.semibold).padding(.horizontal, 6)
        }
        .keyboardShortcut("s", modifiers: .command)
        .help("Copy to clipboard and close (⌘S)")
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
                    drawFocusDim(
                        (model.displayElements + [model.draftElement].compactMap { $0 }).compactMap(\.kind.focusRect),
                        over: fitted, into: context, projection: projection
                    )
                    for (index, element) in model.displayElements.enumerated() where element.id != model.editingTextID {
                        // The label being typed into is shown by its text field instead.
                        draw(element, redactionPatch: model.redactionPatch(at: index), into: context, projection: projection)
                    }
                    if let draft = model.draftElement {
                        draw(draft, redactionPatch: model.draftRedactionPatch, into: context, projection: projection)
                    }
                    if let box = model.selectionBox {
                        drawSelection(box, into: context, projection: projection)
                    }
                    if let box = model.textBox {
                        drawTextChrome(box, into: context, projection: projection)
                    }
                    if let box = model.focusBox {
                        let radius = focusCornerRadius(for: box) * projection.scale
                        context.stroke(Path(roundedRect: projection.toView(box).cgRect, cornerRadius: radius), with: .color(.accentColor), lineWidth: 1.5)
                        drawHandles(on: box, size: 7, stroke: .accentColor, into: context, projection: projection)
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
                .onContinuousHover { phase in
                    switch phase {
                    case let .active(location):
                        updateCursor(at: projection.toImage(Point(location)))
                    case .ended:
                        NSCursor.arrow.set()
                    }
                }
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
                if fontSizeFocused { fontSizeFocused = false }
                model.gestureChanged(at: projection.toImage(Point(value.location)))
                updateCursor(at: projection.toImage(Point(value.location)))
            }
            .onEnded { value in
                model.gestureEnded(at: projection.toImage(Point(value.location)))
                // AppKit resets the pointer on mouse-up and no hover follows until the mouse
                // moves, so the crop's cursor is re-applied a moment later.
                let point = projection.toImage(Point(value.location))
                DispatchQueue.main.async { updateCursor(at: point) }
                model.syncStyleToSelection()
                if model.editingTextID != nil { textFieldFocused = true }
            }
    }

    /// The crop's pointer (resize arrows on its border, hands over it), else the arrow.
    private func updateCursor(at point: Point) {
        (model.cropCursor(at: point) ?? .arrow).nsCursor.set()
    }

    private func doubleClickGesture(projection: CanvasProjection) -> some Gesture {
        SpatialTapGesture(count: 2)
            .onEnded { value in
                if model.doubleClick(at: projection.toImage(Point(value.location))) {
                    textFieldFocused = true
                }
            }
    }

    /// The label being typed into, as a text field laid over its box's padded content, in the
    /// label's own font so the text doesn't jump when editing ends.
    @ViewBuilder
    private func textEditor(projection: CanvasProjection) -> some View {
        if let id = model.editingTextID,
           let box = model.document.element(id: id)?.kind.boundingBox,
           let style = model.document.element(id: id)?.style {
            let pad = TextLayout.padding(for: style.fontSize) * projection.scale
            let content = projection.toView(box).cgRect.insetBy(dx: pad, dy: pad)
            TextField("", text: Bindable(model).editingText, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.custom(TextLayout.fontName, size: style.fontSize * projection.scale))
                .foregroundStyle(style.color.color)
                // A caret's width of slack so the field never wraps a line the layout keeps; the
                // box refits as the text changes, so the frame follows it.
                .frame(width: content.width + 4, height: content.height, alignment: .topLeading)
                .position(x: content.midX + 2, y: content.midY)
                // CoreText sets the first line lower than the field does, by about a quarter of
                // the type size in Helvetica: match it, so ending the edit doesn't shift the text.
                .offset(y: style.fontSize * projection.scale * Self.fieldBaselineShift)
                .focused($textFieldFocused)
                .onSubmit { model.endTextEditing() }
        }
    }

    private var nsImage: NSImage? { NSImage(data: model.document.baseImage.data) }

    /// How far the edit field sits above CoreText's first line, as a fraction of the type size.
    private static let fieldBaselineShift = 0.24
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
        // The export's own layout (`TextLayout`), scaled to the view, so wrapping matches.
        let fontSize = element.style.fontSize * projection.scale
        let content = projection.toView(box.standardized).cgRect
            .insetBy(dx: TextLayout.padding(for: element.style.fontSize) * projection.scale,
                     dy: TextLayout.padding(for: element.style.fontSize) * projection.scale)
        let cgColor = NSColor(srgbRed: element.style.color.red, green: element.style.color.green,
                              blue: element.style.color.blue, alpha: element.style.color.alpha).cgColor
        context.withCGContext { cg in
            // CoreText draws y-up; flip about the content rect so the text stands upright in it.
            cg.translateBy(x: 0, y: content.minY + content.maxY)
            cg.scaleBy(x: 1, y: -1)
            TextLayout.draw(string, fontSize: fontSize, color: cgColor, in: content, context: cg)
        }

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

    case let .focus(rect):
        // The dim itself is drawn once for every area (`drawFocusDim`); in the editor the area
        // also shows a solid, slightly rounded edge so it can be found and grabbed.
        let radius = focusCornerRadius(for: rect) * projection.scale
        context.stroke(
            Path(roundedRect: projection.toView(rect).cgRect, cornerRadius: radius),
            with: .color(.white.opacity(0.85)), lineWidth: 1.5
        )

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

/// Dims the image outside the union of the focus `areas` (image space), as the export does
/// (`render`'s `focusDimAlpha`): a dim layer with every area cleared out of it, so overlapping
/// areas never dim each other. Drawn under the marks.
private func drawFocusDim(_ areas: [Rect], over image: CGRect, into context: GraphicsContext, projection: CanvasProjection) {
    guard !areas.isEmpty else { return }
    context.drawLayer { layer in
        layer.fill(Path(image), with: .color(.black.opacity(focusDimAlpha)))
        layer.blendMode = .clear
        for area in areas {
            let radius = focusCornerRadius(for: area) * projection.scale
            layer.fill(Path(roundedRect: projection.toView(area).cgRect, cornerRadius: radius), with: .color(.black))
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

/// A toolbar glyph for an arrow style, drawn with the canvas's own arrow geometry.
private struct ArrowStyleIcon: View {
    let style: ArrowStyle
    var color: Color = .primary

    var body: some View {
        Canvas { context, size in
            let tail = Point(x: 3, y: Double(size.height) - 3)
            let tip = Point(x: Double(size.width) - 3, y: 3)
            // New bendable arrows start straight; the glyph still bows so the style reads as bendable.
            let mid = arrowMidpoint(tail, tip)
            let bow = Point(x: mid.x - (tip.y - tail.y) * 0.18, y: mid.y + (tip.x - tail.x) * 0.18)
            let shape = arrowShape(
                from: tail, to: tip, bend: style.isBendable ? bow : nil,
                style: style, lineWidth: 1.6
            )
            draw(shape, color: color, into: context)
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

/// A label's chrome, like CleanShot's (LIG-47): a thin rounded border around its padded box,
/// round handles on the side edges (they set the wrap width) and a small square at the
/// bottom-right corner (it scales the text).
private func drawTextChrome(_ box: Rect, into context: GraphicsContext, projection: CanvasProjection) {
    let rect = projection.toView(box).cgRect
    context.stroke(Path(roundedRect: rect, cornerRadius: 6), with: .color(.accentColor.opacity(0.85)), lineWidth: 1.25)
    drawHandles(
        at: [handlePoint(.left, in: box), handlePoint(.right, in: box)], size: 11, round: true,
        stroke: .accentColor, into: context, projection: projection
    )
    let corner = projection.toView(handlePoint(.bottomRight, in: box)).cgPoint
    context.fill(Path(roundedRect: CGRect(x: corner.x - 4, y: corner.y - 4, width: 8, height: 8), cornerRadius: 1.5), with: .color(.accentColor))
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

/// Draws the crop framing like CleanShot's (LIG-47): everything outside the crop rect is dimmed
/// so the excluded area reads at a glance and the crop edge is a thin white line; while the crop
/// tool is active, a rule-of-thirds grid sits inside and the recorder's corner brackets and
/// edge bars mark the eight handles. All geometry is projected from image space, so the frame
/// stays anchored to the same pixels the export will keep.
private func drawCropOverlay(
    _ frame: Rect, imageBounds: Rect, showHandles: Bool,
    into context: GraphicsContext, projection: CanvasProjection
) {
    var context = context
    let full = projection.toView(imageBounds).cgRect
    let crop = projection.toView(frame).cgRect

    // Dim the ring between the image and the crop rect (even-odd fills outside the inner rect).
    var mask = Path(full)
    mask.addRect(crop)
    context.fill(mask, with: .color(.black.opacity(0.5)), style: FillStyle(eoFill: true))

    context.stroke(Path(crop), with: .color(.white.opacity(0.9)), style: StrokeStyle(lineWidth: 1))

    guard showHandles else { return }
    var thirds = Path()
    for step in 1...2 {
        let x = crop.minX + crop.width * CGFloat(step) / 3
        let y = crop.minY + crop.height * CGFloat(step) / 3
        thirds.move(to: CGPoint(x: x, y: crop.minY)); thirds.addLine(to: CGPoint(x: x, y: crop.maxY))
        thirds.move(to: CGPoint(x: crop.minX, y: y)); thirds.addLine(to: CGPoint(x: crop.maxX, y: y))
    }
    context.stroke(thirds, with: .color(.white.opacity(0.45)), lineWidth: 0.75)
    OverlayCanvas.drawSelectionChrome(&context, around: crop)
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

/// Opens the shared colour panel on a colour and reports every change the user makes in it —
/// the editor's "Custom…" colour (LIG-46).
@MainActor
final class ColorPanelBridge: NSObject {
    private var onChange: ((RGBAColor) -> Void)?

    func show(_ color: RGBAColor, onChange: @escaping (RGBAColor) -> Void) {
        self.onChange = onChange
        let panel = NSColorPanel.shared
        panel.showsAlpha = false
        panel.color = NSColor(srgbRed: color.red, green: color.green, blue: color.blue, alpha: color.alpha)
        panel.setTarget(self)
        panel.setAction(#selector(colorChanged(_:)))
        panel.orderFront(nil)
    }

    @objc private func colorChanged(_ panel: NSColorPanel) {
        guard let rgb = panel.color.usingColorSpace(.sRGB) else { return }
        onChange?(RGBAColor(red: rgb.redComponent, green: rgb.greenComponent, blue: rgb.blueComponent, alpha: rgb.alphaComponent))
    }
}
