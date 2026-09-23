import AppKit
import SwiftUI
import LightshotKit

/// The selected panel's settings (spec 0007, stories 10–28). Every control writes through the
/// model's commands; sliders bracket a drag with `beginChange` / `endChange` so one drag is one undo.
struct StudioInspector: View {
    @Bindable var model: StudioEditorModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text(model.panel.title).font(.system(size: 15, weight: .semibold))
                switch model.panel {
                case .background: background
                case .cursor: cursor
                case .zoom: zoom
                case .captions: StudioCaptionsPanel(model: model)
                case .text: StudioTextPanel(model: model)
                case .camera: camera
                case .keys: keys
                case .audio: audio
                case .output: output
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.never)
        .disabled(model.sources == nil)
    }

    // MARK: - Background (stories 20–22)

    private enum BackgroundKind: String, CaseIterable {
        case none, color, gradient, wallpaper, image
        var title: String { rawValue.capitalized }
    }

    private var backgroundKind: BackgroundKind {
        switch model.edits.background {
        case .none: return .none
        case .color: return .color
        case .gradient: return .gradient
        case .wallpaper: return .wallpaper
        case .image: return .image
        }
    }

    @ViewBuilder
    private var background: some View {
        section("Background") {
            Picker("Background", selection: Binding(get: { backgroundKind }, set: { kind in
                switch kind {
                case .none: model.set(\.background, .none)
                case .color: model.set(\.background, .color(RGBAColor(red: 0.1, green: 0.1, blue: 0.12)))
                case .gradient: model.set(\.background, .gradient(.ocean))
                case .wallpaper: model.set(\.background, .wallpaper(.aurora))
                case .image: model.chooseBackgroundImage()
                }
            })) {
                ForEach(BackgroundKind.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .labelsHidden()
        }
        switch model.edits.background {
        case .wallpaper(let selected):
            swatches(WallpaperPreset.allCases, selected: selected, title: \.title) { model.set(\.background, .wallpaper($0)) } fill: { preset in
                AnyShapeStyle(LinearGradient(colors: preset.base.stops.map(\.color) + preset.blobs.map { $0.color.color }, startPoint: .topLeading, endPoint: .bottomTrailing))
            }
        case .gradient(let selected):
            swatches(GradientPreset.allCases, selected: selected, title: \.title) { model.set(\.background, .gradient($0)) } fill: { preset in
                AnyShapeStyle(LinearGradient(colors: preset.stops.map(\.color), startPoint: .topLeading, endPoint: .bottomTrailing))
            }
        case .color(let color):
            ColorPicker("Colour", selection: Binding(get: { color.color }, set: { model.set(\.background, .color(RGBAColor($0))) }), supportsOpacity: false)
                .font(.system(size: 13))
        case .image:
            panelButton("Choose Another Image…") { model.chooseBackgroundImage() }
        case .none:
            EmptyView()
        }
        if case .wallpaper = model.edits.background { blurSlider }
        if case .image = model.edits.background { blurSlider }
        slider("Padding", value: \.canvas.padding, in: 0...CanvasStyle.maximumPadding, percent: true)
        slider("Corner Radius", value: \.canvas.cornerRadius, in: 0...0.1, percent: true)
        slider("Shadow", value: \.canvas.shadow, in: 0...1, percent: true)
        section("Aspect Ratio") {
            Picker("Aspect", selection: Binding(get: { model.edits.canvas.aspect }, set: { model.set(\.canvas.aspect, $0) })) {
                ForEach(StudioAspect.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
    }

    private var blurSlider: some View {
        slider("Background Blur", value: \.canvas.backgroundBlur, in: 0...1, percent: true)
    }

    private func swatches<Item: Hashable>(
        _ items: [Item], selected: Item, title: KeyPath<Item, String>, choose: @escaping (Item) -> Void,
        fill: @escaping (Item) -> AnyShapeStyle
    ) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
            ForEach(items, id: \.self) { item in
                Button { choose(item) } label: {
                    RoundedRectangle(cornerRadius: 7)
                        .fill(fill(item))
                        .frame(height: 38)
                        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(item == selected ? Color.white : .clear, lineWidth: 2))
                }
                .buttonStyle(.plain)
                .help(item[keyPath: title])
            }
        }
    }

    // MARK: - Cursor (stories 14–19)

    @ViewBuilder
    private var cursor: some View {
        if !model.hasCursorData {
            unavailable("This recording has no cursor data. Record in Studio Mode to restyle the cursor after the take.", symbol: "cursorarrow.slash")
        } else {
            toggle("Show Cursor", \.cursor.visible)
            if model.edits.cursor.visible {
                slider("Size", value: \.cursor.size, in: CursorStyle.minimumSize...CursorStyle.maximumSize, format: { String(format: "%.1f×", $0) })
                slider("Smoothing", value: \.cursor.smoothing, in: 0...1, percent: true)
                slider("Motion Blur", value: \.cursor.motionBlur, in: 0...1, percent: true)
                toggle("Hide When Idle", \.cursor.hideWhenIdle)
                if model.edits.cursor.hideWhenIdle {
                    slider("Idle Delay", value: \.cursor.idleDelay, in: 0.5...10, format: { String(format: "%.1f s", $0) })
                }
                section("Click Effect") {
                    Picker("Click Effect", selection: Binding(get: { model.edits.cursor.clickEffect }, set: { model.set(\.cursor.clickEffect, $0) })) {
                        ForEach(ClickEffect.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
                if model.edits.cursor.clickEffect != .none {
                    ColorPicker("Click Colour", selection: Binding(
                        get: { model.edits.cursor.clickColor.color }, set: { model.set(\.cursor.clickColor, RGBAColor($0)) }
                    ), supportsOpacity: false)
                    .font(.system(size: 13))
                }
            }
        }
    }

    // MARK: - Zoom (stories 10–13)

    @ViewBuilder
    private var zoom: some View {
        HStack(spacing: 8) {
            panelButton("Add Zoom at Playhead") { model.addZoom() }
            panelButton("Auto Zoom") { model.autoZoom() }
                .disabled(!model.hasClicks)
                .help(model.hasClicks ? "One zoom per burst of clicks" : "Needs click data from a Studio Mode take")
        }
        if let zoom = model.selectedZoom {
            section("Selected Zoom", value: "\(TimelineScale.label(zoom.start)) – \(TimelineScale.label(zoom.end))") {
                VStack(alignment: .leading, spacing: 14) {
                    zoomScaleSlider(zoom)
                    Picker("Focus", selection: Binding(
                        get: { zoom.focus == .followCursor },
                        set: { follow in model.setZoomFocus(zoom.id, follow ? .followCursor : .point(Point(x: 0.5, y: 0.5))) }
                    )) {
                        Text("Follow Cursor").tag(true)
                        Text("Fixed Point").tag(false)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    if zoom.focus == .followCursor, !model.hasCursorData {
                        Text("No cursor data: the zoom looks at the centre.").font(.system(size: 12)).foregroundStyle(StudioStyle.secondary)
                    }
                    if case .point = zoom.focus {
                        panelButton(model.isPickingFocus ? "Click the Preview…" : "Pick Point on Preview") { model.isPickingFocus.toggle() }
                    }
                    panelButton("Delete Zoom") { model.deleteSelection() }
                }
            }
        } else {
            Text("Select a zoom on the timeline to change its scale and focus.")
                .font(.system(size: 12)).foregroundStyle(StudioStyle.secondary)
        }
        slider("Transition", value: \.zoomTransition, in: StudioEdits.transitionRange, format: { String(format: "%.1f s", $0) })
        slider("Zoom Motion Blur", value: \.zoomMotionBlur, in: 0...1, percent: true)
    }

    private func zoomScaleSlider(_ zoom: ZoomRegion) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Scale").foregroundStyle(StudioStyle.secondary)
                Spacer()
                Text(String(format: "%.1f×", zoom.scale)).monospacedDigit()
            }
            .font(.system(size: 13))
            Slider(value: Binding(get: { zoom.scale }, set: { model.setZoomScale(zoom.id, $0) }),
                   in: ZoomRegion.minimumScale...ZoomRegion.maximumScale) { editing in
                if editing { model.beginChange() } else { model.endChange() }
            }
        }
    }

    // MARK: - Camera (story 23)

    @ViewBuilder
    private var camera: some View {
        if !model.hasCamera {
            unavailable("This recording has no separate camera track. Turn the camera on and Record in Studio Mode to place it after the take.", symbol: "video.slash")
        } else {
            toggle("Show Camera", \.camera.visible)
            if model.edits.camera.visible {
                section("Size") {
                    Picker("Size", selection: Binding(get: { model.edits.camera.bubble.size }, set: { model.set(\.camera.bubble.size, $0) })) {
                        ForEach(CameraBubbleSize.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden()
                }
                section("Shape") {
                    Picker("Shape", selection: Binding(get: { model.edits.camera.bubble.shape }, set: { model.set(\.camera.bubble.shape, $0) })) {
                        ForEach(CameraBubbleShape.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden()
                }
                toggle("Mirror", \.camera.bubble.mirror)
                section("Position") {
                    HStack(spacing: 8) {
                        corner("arrow.up.left", Point(x: 0.12, y: 0.15))
                        corner("arrow.up.right", Point(x: 0.88, y: 0.15))
                        corner("arrow.down.left", Point(x: 0.12, y: 0.85))
                        corner("arrow.down.right", nil)
                    }
                }
            }
        }
    }

    private func corner(_ symbol: String, _ anchor: Point?) -> some View {
        let selected = model.edits.camera.bubble.anchor == anchor
        return Button { model.set(\.camera.bubble.anchor, anchor) } label: {
            Image(systemName: symbol)
                .frame(maxWidth: .infinity).frame(height: 30)
                .background(RoundedRectangle(cornerRadius: 7).fill(selected ? StudioStyle.blue : StudioStyle.control))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Keystrokes (story 24)

    @ViewBuilder
    private var keys: some View {
        if !model.hasKeys {
            unavailable("This recording has no keystroke data. Turn keystrokes on and Record in Studio Mode to show them after the take.", symbol: "keyboard.badge.ellipsis")
        } else {
            toggle("Show Keystrokes", \.keystrokes.visible)
            if model.edits.keystrokes.visible {
                picker("Keys", \.keystrokes.overlay.mode, KeystrokeDisplayMode.allCases, title: \.title)
                picker("Position", \.keystrokes.overlay.position, KeystrokeOverlayPosition.allCases, title: \.title)
                picker("Size", \.keystrokes.overlay.size, KeystrokeOverlaySize.allCases, title: \.title)
                picker("Appearance", \.keystrokes.overlay.appearance, KeystrokeOverlayAppearance.allCases, title: \.title)
                toggle("Blur Background", \.keystrokes.overlay.blurBackground)
            }
        }
    }

    // MARK: - Audio (story 28)

    private enum AudioChoice: String, CaseIterable {
        case unchanged, mute, volume, mono, remove
        var title: String {
            switch self {
            case .unchanged: return "Unchanged"
            case .mute: return "Mute"
            case .volume: return "Adjust Volume"
            case .mono: return "Mono"
            case .remove: return "Remove Audio"
            }
        }
    }

    @ViewBuilder
    private var audio: some View {
        if !model.hasAudio {
            unavailable("This recording has no sound. Turn on the microphone or computer audio in the recorder toolbar to record some.", symbol: "speaker.slash")
        } else {
            let choice: AudioChoice = {
                switch model.edits.audio {
                case .unchanged: return .unchanged
                case .mute: return .mute
                case .volume: return .volume
                case .mono: return .mono
                case .remove: return .remove
                }
            }()
            Picker("Audio", selection: Binding(get: { choice }, set: { new in
                switch new {
                case .unchanged: model.set(\.audio, .unchanged)
                case .mute: model.set(\.audio, .mute)
                case .volume: model.set(\.audio, .volume(1))
                case .mono: model.set(\.audio, .mono)
                case .remove: model.set(\.audio, .remove)
                }
            })) {
                ForEach(AudioChoice.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            if case let .volume(volume) = model.edits.audio {
                section("Volume", value: "\(Int((volume * 100).rounded()))%") {
                    Slider(value: Binding(get: { volume }, set: { model.set(\.audio, .volume($0)) }), in: 0...1) { editing in
                        if editing { model.beginChange() } else { model.endChange() }
                    }
                }
            }
            if model.edits.clips.contains(where: { $0.speed != 1 }) {
                Text("Sped-up and slowed clips keep their pitch.").font(.system(size: 12)).foregroundStyle(StudioStyle.secondary)
            }
        }
    }

    // MARK: - Output (stories 25–26)

    @ViewBuilder
    private var output: some View {
        picker("Resolution", \.output.resolution, OutputResolution.allCases, title: \.title)
        section("Frame Rate") {
            Picker("Frame Rate", selection: Binding(get: { model.edits.output.fps }, set: { model.set(\.output.fps, $0) })) {
                ForEach(StudioOutput.frameRates, id: \.self) { Text("\($0) fps").tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden()
        }
        picker("Codec", \.output.codec, StudioCodec.allCases, title: \.title)
        slider("Quality", value: \.output.quality, in: 0...1, percent: true)
        section("Format") {
            Picker("Format", selection: Binding(get: { model.edits.output.format }, set: { model.set(\.output.format, $0) })) {
                ForEach(StudioOutputFormat.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden()
        }
        if let size = model.outputSize { valueRow("Canvas", "\(Int(size.width)) × \(Int(size.height)) px") }
        valueRow("Length", TimelineScale.label(model.duration))
        valueRow("Estimated Size", "≈ \(model.estimateText)")
    }

    // MARK: - Building blocks

    private func section<Content: View>(_ title: String, value: String? = nil, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(StudioStyle.secondary)
                Spacer()
                if let value { Text(value).font(.system(size: 13, weight: .medium).monospacedDigit()) }
            }
            content()
        }
    }

    private func slider(
        _ title: String, value keyPath: WritableKeyPath<StudioEdits, Double>, in range: ClosedRange<Double>,
        percent: Bool = false, format: ((Double) -> String)? = nil
    ) -> some View {
        let value = model.edits[keyPath: keyPath]
        let text = format?(value) ?? (percent ? "\(Int((value / max(range.upperBound, 0.0001) * 100).rounded()))%" : String(format: "%.2f", value))
        return section(title, value: text) {
            Slider(value: Binding(get: { model.edits[keyPath: keyPath] }, set: { model.set(keyPath, $0) }), in: range) { editing in
                if editing { model.beginChange() } else { model.endChange() }
            }
        }
    }

    private func toggle(_ title: String, _ keyPath: WritableKeyPath<StudioEdits, Bool>) -> some View {
        Toggle(title, isOn: Binding(get: { model.edits[keyPath: keyPath] }, set: { model.set(keyPath, $0) }))
            .toggleStyle(.switch)
            .font(.system(size: 13))
    }

    private func picker<Value: Hashable>(
        _ title: String, _ keyPath: WritableKeyPath<StudioEdits, Value>, _ values: [Value], title label: KeyPath<Value, String>
    ) -> some View {
        section(title) {
            Picker(title, selection: Binding(get: { model.edits[keyPath: keyPath] }, set: { model.set(keyPath, $0) })) {
                ForEach(values, id: \.self) { Text($0[keyPath: label]).tag($0) }
            }
            .labelsHidden()
        }
    }

    private func valueRow(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title).foregroundStyle(StudioStyle.secondary)
            Spacer()
            Text(value).monospacedDigit()
        }
        .font(.system(size: 13))
    }

    private func panelButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .frame(maxWidth: .infinity)
                .frame(height: 30)
                .background(RoundedRectangle(cornerRadius: 7).fill(StudioStyle.control))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func unavailable(_ text: String, symbol: String) -> some View {
        Label {
            Text(text).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: symbol)
        }
        .font(.system(size: 13))
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(StudioStyle.control))
    }
}
