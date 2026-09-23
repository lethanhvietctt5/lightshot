import AppKit
import SwiftUI
import LightshotKit

/// The recording overlay surface (spec 0006, stories 3–9): a dimmed full-screen canvas with the
/// editable selection — border, corner brackets and edge bars over the eight handles, live pixel
/// readout — the hovered window's highlight before anything is selected, and the recorder toolbar
/// laid out like CleanShot's (LIG-42): a dark pill centred in the selection with settings, the
/// typed size, Fullscreen and the ratio menu on one row, the five toggles on the next, and a
/// two-row Record GIF / Record Video menu under it.
///
/// A thin projection of `RecordingOverlayModel`: drawing reads the model, gestures write to it,
/// and the pointer takes the model's `cursor` (crosshair, hands, resize arrows) on every move.
/// Escape/Return/⌥Return/arrows are handled by the hosting window. Coordinates are screen points at 1:1.
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

            controls
        }
        .ignoresSafeArea()
        .onChange(of: model.pixelSize?.width) { _, _ in syncFields() }
        .onChange(of: model.pixelSize?.height) { _, _ in syncFields() }
        .onChange(of: model.cursor) { _, cursor in cursor.nsCursor.set() }
        .onAppear {
            syncFields()
            model.cursor.nsCursor.set()
        }
    }

    // MARK: - Toolbar

    private static let toolbarWidth: CGFloat = 310
    /// Roughly the toolbar plus the two menus, for deciding whether it fits inside the selection.
    private static let toolbarHeight: CGFloat = 300
    /// The toolbar is a 5-column grid: settings · size (3 columns) · ratio over the five toggles.
    private static let cellWidth = toolbarWidth / 5
    private static let sizeRowHeight: CGFloat = 46
    private static let toggleRowHeight: CGFloat = 58
    private static let radius = ToolbarChrome.panelRadius

    /// The recorder toolbar, centred in the selection when it fits there (else just outside it),
    /// or at the screen's centre while nothing is selected.
    private var controls: some View {
        GeometryReader { geometry in
            VStack(spacing: 12) {
                toolbarPanel
                recordMenu
                studioRow
                if model.cameraWithoutMicrophone {
                    note("Camera on, no microphone — the recording will be silent", systemImage: "exclamationmark.triangle", tint: .orange)
                } else if !model.hasSelection {
                    note("Drag an area or click a window · Esc to cancel", systemImage: nil, tint: .secondary)
                }
            }
            .frame(width: Self.toolbarWidth)
            .environment(\.colorScheme, .dark)
            .position(controlsCenter(in: geometry.size))
        }
    }

    /// Row 1: settings · W × H with Fullscreen · ratio. Row 2: the toggles, each on one filled
    /// dark with a check under it. Hairlines between the cells, as CleanShot draws them.
    private var toolbarPanel: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                iconButton("slider.horizontal.3", title: "Recording settings", corners: .init(topLeading: Self.radius)) { model.openSettings() }
                HStack(spacing: 6) {
                    sizeField($widthText, title: "Width in pixels") { model.setWidth(pixels: $0) }
                    Text("×").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white.opacity(0.6))
                    sizeField($heightText, title: "Height in pixels") { model.setHeight(pixels: $0) }
                    Button { model.chooseFullscreen() } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.system(size: 10, weight: .semibold))
                            .frame(width: 24, height: 24)
                            .background(RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.35)))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white.opacity(0.85))
                    .toolbarControl("Fullscreen")
                }
                .frame(width: Self.cellWidth * 3, height: Self.sizeRowHeight)
                ratioMenu
            }
            HStack(spacing: 0) {
                ForEach(Array(model.toggles.enumerated()), id: \.element) { index, toggle in
                    let corners = RectangleCornerRadii(
                        bottomLeading: index == 0 ? Self.radius : 0,
                        bottomTrailing: index == model.toggles.count - 1 ? Self.radius : 0
                    )
                    if toggle == .microphone {
                        microphoneControl(corners)
                    } else if toggle == .camera {
                        cameraControl(corners)
                    } else {
                        Button {
                            Task { await model.toggle(toggle) }
                        } label: {
                            toggleGlyph(toggle)
                        }
                        .buttonStyle(.plain)
                        .toolbarControl(toggle.title, isOn: model.isOn(toggle), warning: model.permissionWarning(for: toggle), shape: .cell(corners))
                    }
                }
            }
        }
        .background(ToolbarGrid(cellWidth: Self.cellWidth, firstRowHeight: Self.sizeRowHeight).stroke(Color.white.opacity(0.09), lineWidth: 1))
        .toolbarPanel()
    }

    /// Record GIF (⌥↩) over Record Video (↩), CleanShot's menu under the toolbar.
    private var recordMenu: some View {
        VStack(spacing: 0) {
            RecordRow(title: "Record GIF", shortcut: "⌥ ↩", enabled: model.hasSelection, action: model.startGIF) {
                Text("GIF")
                    .font(.system(size: 9, weight: .heavy))
                    .foregroundStyle(ToolbarChrome.slate)
                    .padding(.horizontal, 3.5)
                    .padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 3).fill(Color.white))
            }
            Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1)
            RecordRow(title: "Record Video", shortcut: "↩", enabled: model.hasSelection, action: model.startVideo) {
                Image(systemName: "video.fill").font(.system(size: 15, weight: .medium))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: ToolbarChrome.panelRadius))
        .toolbarPanel(border: 0.18)
    }

    /// CleanShot's third panel: a video take that opens straight in the video editor.
    private var studioRow: some View {
        RecordRow(title: "Record in Studio Mode", shortcut: nil, enabled: model.hasSelection, action: model.startStudio) {
            Image(systemName: "movieclapper").font(.system(size: 15, weight: .medium))
        } trailing: {
            Image(systemName: "questionmark")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(Circle().fill(Color.white.opacity(0.22)))
                .toolbarControl("Records a video and opens it in the video editor as soon as it stops")
        }
        .background(
            // The pink glow CleanShot gives this row, fading out to the right.
            RoundedRectangle(cornerRadius: ToolbarChrome.panelRadius)
                .fill(LinearGradient(colors: [Self.studioPink.opacity(0.14), .clear], startPoint: .leading, endPoint: .trailing))
        )
        .clipShape(RoundedRectangle(cornerRadius: ToolbarChrome.panelRadius))
        .toolbarPanel(border: 0, tipEdge: .bottom)
        .overlay(
            RoundedRectangle(cornerRadius: ToolbarChrome.panelRadius)
                .stroke(LinearGradient(colors: [Self.studioPink, Self.studioViolet], startPoint: .leading, endPoint: .trailing).opacity(0.7), lineWidth: 1)
        )
        .shadow(color: Self.studioPink.opacity(0.35), radius: 8)
    }

    private static let studioPink = Color(red: 0.95, green: 0.4, blue: 0.6)
    private static let studioViolet = Color(red: 0.6, green: 0.45, blue: 0.95)

    private func note(_ text: String, systemImage: String?, tint: Color) -> some View {
        HStack(spacing: 4) {
            if let systemImage { Image(systemName: systemImage) }
            Text(text)
        }
        .font(.system(size: 12))
        .foregroundStyle(tint)
        .multilineTextAlignment(.center)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .toolbarPanel()
    }

    private func iconButton(_ symbol: String, title: String, corners: RectangleCornerRadii, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .light))
                .frame(width: Self.cellWidth, height: Self.sizeRowHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white.opacity(0.75))
        .toolbarControl(title, shape: .cell(corners))
    }

    /// The aspect-ratio lock as a menu behind the crop glyph (story 4).
    private var ratioMenu: some View {
        Menu {
            Picker("Ratio", selection: Binding(get: { model.ratio }, set: { model.setRatio($0) })) {
                ForEach(AspectRatio.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.inline)
        } label: {
            Image(systemName: "crop")
                .font(.system(size: 17, weight: .light))
                .frame(width: Self.cellWidth, height: Self.sizeRowHeight)
                .contentShape(Rectangle())
                .foregroundStyle(model.ratio == .freeform ? Color.white.opacity(0.75) : Color.accentColor)
        }
        .modifier(PlainMenu())
        .frame(width: Self.cellWidth, height: Self.sizeRowHeight)
        .toolbarControl("Aspect ratio: \(model.ratio.title)", shape: .cell(.init(topTrailing: Self.radius)))
    }

    /// The mic toggle (story 20): a click flips it; switched on with more than one input attached,
    /// the device picker opens under it at once, and its ▾ badge reopens the picker any time.
    private func microphoneControl(_ corners: RectangleCornerRadii) -> some View {
        deviceControl(
            .microphone, corners: corners, title: "Microphone",
            devices: model.audioInputs.map { ($0.id, $0.name) }, selected: model.microphoneDeviceID,
            select: { id in Task { await model.selectMicrophone(id) } },
            turnOff: { model.turnOffMicrophone() },
            help: model.isOn(.microphone) ? "Microphone on" : "Record the microphone"
        )
    }

    /// The camera toggle (story 27), like the microphone's.
    private func cameraControl(_ corners: RectangleCornerRadii) -> some View {
        deviceControl(
            .camera, corners: corners, title: "Camera",
            devices: model.cameras.map { ($0.id, $0.name) }, selected: model.cameraDeviceID,
            select: { id in Task { await model.selectCamera(id) } },
            turnOff: { model.turnOffCamera() },
            help: model.isOn(.camera) ? "Camera on" : "Show your camera in the recording"
        )
    }

    private func deviceControl(
        _ toggle: RecordingToggle, corners: RectangleCornerRadii, title: String,
        devices: [(id: String, name: String)], selected: String?,
        select: @escaping (String?) -> Void, turnOff: @escaping () -> Void, help: String
    ) -> some View {
        let showsChoice = model.isOn(toggle) && model.hasDeviceChoice(toggle)
        return Button {
            Task { await model.toggle(toggle) }
        } label: {
            toggleGlyph(toggle)
        }
        .buttonStyle(.plain)
        // Bottom-right, clear of the permission badge (top-right) and the on-check (bottom-centre).
        .overlay(alignment: .bottomTrailing) {
            if showsChoice {
                Button { model.devicePicker = toggle } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                        .frame(width: 16, height: 14)
                        .background(RoundedRectangle(cornerRadius: 4).fill(Color.white.opacity(0.14)))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white.opacity(0.85))
                .padding(3)
                .help("Choose the \(title.lowercased())")
                .accessibilityLabel("Choose the \(title.lowercased())")
            }
        }
        .popover(isPresented: Binding(
            get: { model.devicePicker == toggle },
            set: { if !$0, model.devicePicker == toggle { model.devicePicker = nil } }
        ), arrowEdge: .bottom) {
            DevicePickerList(title: title, devices: devices, selected: selected, select: select, turnOff: turnOff)
        }
        .frame(width: Self.cellWidth, height: Self.toggleRowHeight)
        .toolbarControl(
            showsChoice ? "\(help) — ▾ to choose" : help,
            isOn: model.isOn(toggle), warning: model.permissionWarning(for: toggle), shape: .cell(corners)
        )
    }

    /// A toggle's glyph with CleanShot's small check under it while on; off ones are dimmed.
    private func toggleGlyph(_ toggle: RecordingToggle) -> some View {
        let on = model.isOn(toggle)
        return Self.glyph(for: toggle)
            .font(.system(size: 18, weight: .light))
            .frame(width: Self.cellWidth, height: Self.toggleRowHeight)
            .overlay(alignment: .bottom) {
                Image(systemName: "checkmark")
                    .font(.system(size: 9, weight: .bold))
                    .padding(.bottom, 5)
                    .opacity(on ? 1 : 0)
            }
        .foregroundStyle(on ? Color.white : Color.white.opacity(0.6))
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private static func glyph(for toggle: RecordingToggle) -> some View {
        switch toggle {
        case .microphone: Image(systemName: "mic")
        case .computerAudio:
            // CleanShot's "display with a speaker" — SF Symbols has no such glyph, so compose it:
            // a notch cut out of the display's corner with the speaker in it, the pair centred.
            ZStack(alignment: .bottomTrailing) {
                Image(systemName: "display").padding(.trailing, 6).padding(.bottom, 3)
                RoundedRectangle(cornerRadius: 2).frame(width: 15, height: 12).blendMode(.destinationOut)
                Image(systemName: "speaker.wave.2.fill")
                    .font(.system(size: 9, weight: .semibold))
                    .frame(width: 15, height: 12)
            }
            .compositingGroup()
        case .camera: Image(systemName: "video")
        case .highlightClicks: Image(systemName: "cursorarrow.click.2")
        case .showKeystrokes: Image(systemName: "command.square")
        }
    }

    /// Fields are in native pixels, like the readout; the model converts to points.
    private func sizeField(_ text: Binding<String>, title: String, commit: @escaping (Double) -> Void) -> some View {
        TextField("", text: text)
            .textFieldStyle(.plain)
            .font(.system(size: 15, weight: .medium).monospacedDigit())
            .multilineTextAlignment(.center)
            .frame(width: 54, height: 28)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color.black.opacity(0.35)))
            .toolbarControl(title)
            .disabled(!model.hasSelection)
            .onSubmit {
                if let pixels = Double(text.wrappedValue), pixels > 0 { commit(pixels) }
                syncFields()
            }
    }

    private func syncFields() {
        if let px = model.pixelSize {
            widthText = String(px.width)
            heightText = String(px.height)
        } else {
            widthText = ""
            heightText = ""
        }
    }

    private func controlsCenter(in size: CGSize) -> CGPoint {
        guard model.hasSelection, let rect = model.selection.rect?.cgRect else {
            return CGPoint(x: size.width / 2, y: size.height / 2)
        }
        let height = Self.toolbarHeight
        if rect.width >= Self.toolbarWidth + 24, rect.height >= height + 24 {
            return CGPoint(x: rect.midX, y: rect.midY)
        }
        let below = rect.maxY + 12 + height / 2
        let y = below + height / 2 <= size.height ? below : max(height / 2, rect.minY - 12 - height / 2)
        let halfWidth = Self.toolbarWidth / 2
        return CGPoint(x: min(max(rect.midX, halfWidth), size.width - halfWidth), y: y)
    }

    // MARK: - Canvas

    private func draw(into context: inout GraphicsContext, size: CGSize) {
        // The selection — or, before one exists, the hovered window — shows through the dimming.
        let box: CGRect? = model.hasSelection ? model.selection.rect?.cgRect : model.hovered?.frame.cgRect
        OverlayCanvas.dim(&context, size: size, punchingOut: box)
        guard let box else { return }
        context.stroke(Path(box), with: .color(.white.opacity(model.hasSelection ? 0.8 : 1)), style: StrokeStyle(lineWidth: model.hasSelection ? 1 : 2))

        if model.showsHandles, let rect = model.selection.rect {
            OverlayCanvas.drawSelectionChrome(&context, around: rect.cgRect)
        }

        if let px = model.pixelSize {
            OverlayCanvas.drawReadout(&context, width: px.width, height: px.height, around: box)
        }
    }
}

/// One row of a record menu: a glyph, the title, and a shortcut or a trailing view; highlights
/// on hover.
private struct RecordRow<Glyph: View, Trailing: View>: View {
    let title: String
    let shortcut: String?
    let enabled: Bool
    let action: () -> Void
    @ViewBuilder let glyph: Glyph
    @ViewBuilder let trailing: Trailing
    @State private var isHovered = false

    init(
        title: String, shortcut: String?, enabled: Bool, action: @escaping () -> Void,
        @ViewBuilder glyph: () -> Glyph, @ViewBuilder trailing: () -> Trailing = { EmptyView() }
    ) {
        self.title = title
        self.shortcut = shortcut
        self.enabled = enabled
        self.action = action
        self.glyph = glyph()
        self.trailing = trailing()
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                glyph.frame(width: 28)
                Text(title).font(.system(size: 15, weight: .semibold))
                Spacer()
                if let shortcut {
                    Text(shortcut).font(.system(size: 14)).foregroundStyle(.white.opacity(0.85))
                }
                trailing
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
            .background(isHovered && enabled ? Color.white.opacity(0.08) : Color.clear)
        }
        .buttonStyle(.plain)
        .foregroundStyle(enabled ? Color.white : Color.white.opacity(0.35))
        .disabled(!enabled)
        .onHover { isHovered = $0 }
    }
}

/// The toolbar's hairlines: under the size row, and between the cells of each row (the size
/// group spans the middle three columns, so row 1 only splits after the first and fourth).
private struct ToolbarGrid: Shape {
    let cellWidth: CGFloat
    let firstRowHeight: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: firstRowHeight))
        path.addLine(to: CGPoint(x: rect.maxX, y: firstRowHeight))
        for column in [1, 4] {
            path.move(to: CGPoint(x: cellWidth * CGFloat(column), y: rect.minY))
            path.addLine(to: CGPoint(x: cellWidth * CGFloat(column), y: firstRowHeight))
        }
        for column in 1...4 {
            path.move(to: CGPoint(x: cellWidth * CGFloat(column), y: firstRowHeight))
            path.addLine(to: CGPoint(x: cellWidth * CGFloat(column), y: rect.maxY))
        }
        return path
    }
}

/// A `Menu` drawn as nothing but its label — no border, no chevron, no extra insets — so it sits
/// in a toolbar row exactly like the plain buttons beside it.
private struct PlainMenu: ViewModifier {
    func body(content: Content) -> some View {
        content
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
    }
}

/// The device picker under the microphone or camera cell: System Default and each attached device,
/// the current one checked, and "Do Not Record" to switch the toggle back off.
private struct DevicePickerList: View {
    let title: String
    let devices: [(id: String, name: String)]
    let selected: String?
    let select: (String?) -> Void
    let turnOff: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(0.5))
                .padding(.horizontal, 10).padding(.top, 4).padding(.bottom, 2)
            row("System Default", isSelected: selected == nil) { select(nil) }
            ForEach(devices, id: \.id) { device in
                row(device.name, isSelected: selected == device.id) { select(device.id) }
            }
            Divider().padding(.vertical, 4)
            row("Do Not Record \(title)", isSelected: false, action: turnOff)
        }
        .padding(6)
        .frame(minWidth: 240)
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
        // The toolbar's own dark slate, not the light popover material behind white text.
        .presentationBackground(ToolbarChrome.slate)
    }

    private func row(_ name: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        DevicePickerRow(name: name, isSelected: isSelected, action: action)
    }
}

private struct DevicePickerRow: View {
    let name: String
    let isSelected: Bool
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .semibold))
                    .opacity(isSelected ? 1 : 0)
                    .frame(width: 14)
                Text(name).font(.system(size: 13)).lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .frame(height: 26)
            .background(RoundedRectangle(cornerRadius: 6).fill(hovered ? Color.accentColor.opacity(0.85) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}
