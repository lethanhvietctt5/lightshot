import AppKit
import AVFoundation
import SwiftUI
import LightshotKit

/// The studio editor's colours (LIG-43): one dark canvas, hairline dividers, dimmed secondary text.
private enum Studio {
    static let canvas = Color(white: 0.12)
    static let divider = Color.white.opacity(0.08)
    static let secondary = Color.white.opacity(0.55)
    static let control = Color.white.opacity(0.08)
    static let playhead = Color(red: 1, green: 0.27, blue: 0.23)
    static let trim = Color(red: 1, green: 0.8, blue: 0.2)
    static let blue = Color(red: 0.04, green: 0.52, blue: 1)
}

/// CleanShot's studio layout (LIG-43): rail · panel · preview + transport over the timeline.
struct VideoEditorView: View {
    @Bindable var model: VideoEditorModel

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                // The title sits in the transparent toolbar's band; the toolbar keeps the drag and
                // the Export button, so the title takes no clicks.
                VideoEditorTitle(model: model)
                    .frame(maxWidth: .infinity)
                    .frame(height: geometry.safeAreaInsets.top)
                    .allowsHitTesting(false)
                Studio.divider.frame(height: 1)
                content
            }
            .ignoresSafeArea(.container, edges: .top)
        }
        .background(Studio.canvas)
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
        .background {
            Button("Export") { model.presentExport?() }
                .keyboardShortcut("e", modifiers: .command)
                .opacity(0)
                .accessibilityHidden(true)
        }
    }

    private var content: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                EditorRail(model: model)
                Studio.divider.frame(width: 1)
                EditorPanel(model: model)
                    .frame(width: 300)
                Studio.divider.frame(width: 1)
                VStack(spacing: 0) {
                    EditorPreview(model: model)
                    Studio.divider.frame(height: 1)
                    EditorTransport(model: model)
                }
            }
            Studio.divider.frame(height: 1)
            EditorTimeline(model: model)
                .frame(height: 220)
        }
    }
}

// MARK: - Toolbar

/// The file name centred in the title band, and **Edited** once a setting has moved.
private struct VideoEditorTitle: View {
    let model: VideoEditorModel

    var body: some View {
        HStack(spacing: 10) {
            Text(model.url.lastPathComponent)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)
            if model.isEdited {
                Text("Edited").font(.system(size: 13)).foregroundStyle(Studio.secondary)
            }
        }
        .frame(maxWidth: 520)
    }
}

/// Save mode, the two estimates, **Trim Only** / **Trim & Convert**, progress, and Revert.
struct VideoEditorExportPanel: View {
    @Bindable var model: VideoEditorModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Export").font(.system(size: 14, weight: .semibold))
            Picker("Save", selection: $model.saveMode) {
                Text("As a new video").tag(VideoEditorModel.SaveMode.newFile)
                Text("Replace the original").tag(VideoEditorModel.SaveMode.replace)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            VStack(spacing: 6) {
                estimateRow("Trim & Convert", value: model.estimateText, note: "Applies size, quality and audio")
                estimateRow("Trim Only", value: model.trimOnlyEstimateText, note: "Cuts without re-encoding — fast, same quality")
            }
            HStack {
                Button("Trim Only") { model.trimOnly() }
                    .disabled(model.isExporting)
                Spacer()
                Button("Trim & Convert") { model.trimAndConvert() }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isExporting)
                    .keyboardShortcut(.defaultAction)
            }
            if model.isExporting {
                HStack {
                    ProgressView(value: model.progress)
                    Button("Cancel") { model.cancelExport() }
                }
            }
            if let message = model.message {
                Text(message).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            if let error = model.error {
                Text(error).font(.system(size: 11)).foregroundStyle(.red)
            }
            if model.backup != nil {
                Button("Revert to Original") { model.revert() }
                    .disabled(model.isExporting)
            }
        }
        .padding(16)
        .frame(width: 320)
        .environment(\.colorScheme, .dark)
    }

    private func estimateRow(_ title: String, value: String, note: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 12, weight: .medium))
                Text(note).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            Text("≈ \(value)").font(.system(size: 12).monospacedDigit())
        }
    }
}

// MARK: - Rail and panels

/// The icon rail: one square per section, the selected one blue.
private struct EditorRail: View {
    @Bindable var model: VideoEditorModel

    var body: some View {
        VStack(spacing: 10) {
            ForEach(VideoEditorModel.Panel.allCases, id: \.self) { panel in
                RailButton(symbol: Self.symbol(for: panel), title: panel.title, isSelected: model.panel == panel) {
                    model.panel = panel
                }
            }
            Spacer()
        }
        .padding(.vertical, 14)
        .frame(width: 68)
    }

    private static func symbol(for panel: VideoEditorModel.Panel) -> String {
        switch panel {
        case .trim: return "scissors"
        case .size: return "aspectratio.fill"
        case .quality: return "sparkles"
        case .audio: return "speaker.wave.2.fill"
        }
    }
}

private struct RailButton: View {
    let symbol: String
    let title: String
    let isSelected: Bool
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .medium))
                .frame(width: 44, height: 44)
                .foregroundStyle(isSelected ? Color.white : Color.white.opacity(hovered ? 0.85 : 0.55))
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(isSelected ? Studio.blue : hovered ? Studio.control : .clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(title)
        .accessibilityLabel(title)
    }
}

/// The selected section's settings.
private struct EditorPanel: View {
    @Bindable var model: VideoEditorModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                switch model.panel {
                case .trim: trim
                case .size: size
                case .quality: quality
                case .audio: audio
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.never)
    }

    private var trim: some View {
        VStack(alignment: .leading, spacing: 22) {
            section("Trim") {
                VStack(spacing: 8) {
                    valueRow("Start", Self.time(model.trim.start))
                    valueRow("End", Self.time(model.trim.end))
                    valueRow("Length", Self.time(model.trim.length))
                }
            }
            VStack(spacing: 8) {
                panelButton("Set Start to Playhead") { model.setIn(model.currentTime) }
                panelButton("Set End to Playhead") { model.setOut(model.currentTime) }
                panelButton("Reset Trim") { model.resetTrim() }
                    .disabled(model.trim.isWholeClip)
            }
            Text("Drag the yellow handles on the timeline to cut the start and end.")
                .font(.system(size: 12))
                .foregroundStyle(Studio.secondary)
        }
    }

    private var size: some View {
        VStack(alignment: .leading, spacing: 22) {
            section("Size") {
                Picker("Size", selection: $model.preset) {
                    ForEach(DimensionPreset.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .onChange(of: model.preset) { _, _ in model.customWidth = ""; model.customHeight = "" }
            }
            section("Custom") {
                HStack(spacing: 8) {
                    TextField("Width", text: $model.customWidth).textFieldStyle(.roundedBorder)
                    Text("×").foregroundStyle(Studio.secondary)
                    TextField("Height", text: $model.customHeight).textFieldStyle(.roundedBorder)
                }
            }
            valueRow("Output", "\(Int(model.dimensions.width)) × \(Int(model.dimensions.height)) px")
            Text("The picture keeps its aspect and is never scaled up. Applies to Trim & Convert.")
                .font(.system(size: 12))
                .foregroundStyle(Studio.secondary)
        }
    }

    private var quality: some View {
        VStack(alignment: .leading, spacing: 22) {
            section("Video Quality", value: "\(Int((model.quality * 100).rounded()))%") {
                VStack(spacing: 4) {
                    Slider(value: $model.quality, in: 0...1)
                    HStack {
                        Text("Smaller file")
                        Spacer()
                        Text("Sharper")
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(Studio.secondary)
                }
            }
            section("Estimated File Size") {
                VStack(spacing: 8) {
                    valueRow("Trim & Convert", model.estimateText)
                    valueRow("Trim Only", model.trimOnlyEstimateText)
                }
            }
        }
    }

    @ViewBuilder
    private var audio: some View {
        if model.hasAudio {
            VStack(alignment: .leading, spacing: 22) {
                section("Audio") {
                    Picker("Audio", selection: $model.audioChoice) {
                        ForEach(VideoEditorModel.AudioChoice.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.radioGroup)
                    .labelsHidden()
                }
                if model.audioChoice == .volume {
                    section("Volume", value: "\(Int((model.volume * 100).rounded()))%") {
                        Slider(value: $model.volume, in: 0...2)
                    }
                }
                Text("The preview plays with this applied (volume above 100% is heard at 100%).")
                    .font(.system(size: 12))
                    .foregroundStyle(Studio.secondary)
            }
        } else {
            section("Audio") {
                Label {
                    Text("This recording has no sound, so there is nothing to change. Turn on the microphone or computer audio in the recorder toolbar to record some.")
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "speaker.slash")
                }
                .font(.system(size: 13))
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(Studio.control))
            }
        }
    }

    private func section<Content: View>(_ title: String, value: String? = nil, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(Studio.secondary)
                Spacer()
                if let value { Text(value).font(.system(size: 13, weight: .medium).monospacedDigit()) }
            }
            content()
        }
    }

    private func valueRow(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title).foregroundStyle(Studio.secondary)
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
                .background(RoundedRectangle(cornerRadius: 7).fill(Studio.control))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// `0:04.2` — the trim readouts show tenths.
    static func time(_ seconds: TimeInterval) -> String {
        let tenthsTotal = Int((max(seconds, 0) * 10).rounded(.down))
        return String(format: "%d:%02d.%d", tenthsTotal / 600, tenthsTotal / 10 % 60, tenthsTotal % 10)
    }
}

// MARK: - Preview and transport

/// The video framed on the canvas — no inline player controls.
private struct EditorPreview: View {
    let model: VideoEditorModel

    var body: some View {
        ZStack {
            if let source = model.source {
                PlayerSurface(player: model.player)
                    .aspectRatio(CGSize(width: max(source.size.width, 1), height: max(source.size.height, 1)), contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .shadow(color: .black.opacity(0.4), radius: 16, y: 6)
                    .onTapGesture { model.togglePlay() }
            } else if let error = model.error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(Studio.secondary)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .padding(.horizontal, 32)
        .padding(.top, 28)
        .padding(.bottom, 48)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .bottom) {
            if model.source != nil {
                OutputSummary(model: model).padding(.bottom, 12)
            }
        }
    }
}

/// What the export will produce, under the preview — each setting that differs from the
/// recording highlighted, so a change in any panel shows at once.
private struct OutputSummary: View {
    let model: VideoEditorModel

    var body: some View {
        let size = model.dimensions
        HStack(spacing: 6) {
            chip("\(Int(size.width)) × \(Int(size.height))", systemImage: "aspectratio", changed: size != model.source?.size)
            chip("Quality \(Int((model.quality * 100).rounded()))%", systemImage: "sparkles", changed: model.quality != VideoBitRate.defaultQuality)
            if model.hasAudio {
                chip(model.audioChoice == .unchanged ? "Audio" : model.audioChoice.title, systemImage: "speaker.wave.2", changed: model.audioChoice != .unchanged)
            } else {
                chip("No audio", systemImage: "speaker.slash", changed: false)
            }
            chip("≈ \(model.estimateText)", systemImage: "doc", changed: false)
        }
    }

    private func chip(_ text: String, systemImage: String, changed: Bool) -> some View {
        Label(text, systemImage: systemImage)
            .font(.system(size: 11, weight: .medium).monospacedDigit())
            .foregroundStyle(changed ? Color.white : Studio.secondary)
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(Capsule().fill(changed ? Studio.blue.opacity(0.45) : Studio.control))
    }
}

/// `current / duration`, skip to the in point, play / pause, skip to the out point, timeline zoom.
private struct EditorTransport: View {
    @Bindable var model: VideoEditorModel

    var body: some View {
        ZStack {
            HStack(spacing: 0) {
                HStack(spacing: 6) {
                    Text(TimelineScale.label(model.currentTime))
                    Text("/").foregroundStyle(Studio.secondary)
                    Text(TimelineScale.label(model.trim.duration)).foregroundStyle(Studio.secondary)
                }
                .font(.system(size: 14, weight: .medium).monospacedDigit())
                Spacer()
                HStack(spacing: 8) {
                    zoomButton("minus") { model.timelineZoom = max(1, model.timelineZoom / 1.5) }
                    Slider(value: $model.timelineZoom, in: 1...8)
                        .controlSize(.small)
                        .frame(width: 110)
                    zoomButton("plus") { model.timelineZoom = min(8, model.timelineZoom * 1.5) }
                }
                .help("Zoom the timeline")
            }
            HStack(spacing: 26) {
                transportButton("backward.end.fill", title: "Go to start", size: 17) { model.skipToStart() }
                transportButton(model.isPlaying ? "pause.fill" : "play.fill", title: model.isPlaying ? "Pause" : "Play", size: 22) { model.togglePlay() }
                    .keyboardShortcut(.space, modifiers: [])
                transportButton("forward.end.fill", title: "Go to end", size: 17) { model.skipToEnd() }
            }
        }
        .padding(.horizontal, 20)
        .frame(height: 64)
        .disabled(model.source == nil)
    }

    private func transportButton(_ symbol: String, title: String, size: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size))
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(title)
        .accessibilityLabel(title)
    }

    private func zoomButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Studio.secondary)
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// An `AVPlayerLayer` filling the view, aspect-fit.
private struct PlayerSurface: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> PlayerLayerView {
        let view = PlayerLayerView()
        view.playerLayer.player = player
        return view
    }

    func updateNSView(_ view: PlayerLayerView, context: Context) {
        view.playerLayer.player = player
    }

    final class PlayerLayerView: NSView {
        let playerLayer = AVPlayerLayer()

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer?.backgroundColor = NSColor.black.cgColor
            playerLayer.videoGravity = .resizeAspect
            layer?.addSublayer(playerLayer)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            playerLayer.frame = bounds
            CATransaction.commit()
        }
    }
}

// MARK: - Timeline

/// The ruler, the playhead, and the filmstrip with the trim handles; scrolls sideways when zoomed.
private struct EditorTimeline: View {
    @Bindable var model: VideoEditorModel
    private static let inset: CGFloat = 28

    var body: some View {
        GeometryReader { geometry in
            let width = max(1, (geometry.size.width - Self.inset * 2) * model.timelineZoom)
            ScrollView(.horizontal) {
                TimelineTrack(model: model, scale: TimelineScale(duration: model.trim.duration, width: width))
                    .frame(width: width, height: geometry.size.height)
                    .padding(.horizontal, Self.inset)
            }
            .scrollIndicators(model.timelineZoom > 1 ? .automatic : .never)
        }
    }
}

private struct TimelineTrack: View {
    let model: VideoEditorModel
    let scale: TimelineScale

    private static let rulerHeight: CGFloat = 36
    private static let stripTop: CGFloat = 92
    private static let stripHeight: CGFloat = 64
    private static let handleWidth: CGFloat = 12

    var body: some View {
        let startX = scale.x(for: model.trim.start)
        let endX = scale.x(for: model.trim.end)
        ZStack(alignment: .topLeading) {
            ruler
            filmstrip
                .frame(width: scale.width, height: Self.stripHeight)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .offset(y: Self.stripTop)
            // The cut-away ends, dimmed.
            Rectangle().fill(Color.black.opacity(0.6))
                .frame(width: startX, height: Self.stripHeight)
                .offset(y: Self.stripTop)
            Rectangle().fill(Color.black.opacity(0.6))
                .frame(width: max(0, scale.width - endX), height: Self.stripHeight)
                .offset(x: endX, y: Self.stripTop)
            // The kept part, framed in yellow between its two handles.
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(Studio.trim, lineWidth: 3)
                .frame(width: max(0, endX - startX), height: Self.stripHeight)
                .offset(x: startX, y: Self.stripTop)
                .allowsHitTesting(false)
            trimHandle(chevron: "chevron.compact.left") { model.setIn($0); model.seek(to: model.trim.start) }
                .offset(x: startX, y: Self.stripTop)
            trimHandle(chevron: "chevron.compact.right") { model.setOut($0); model.seek(to: model.trim.end) }
                .offset(x: endX - Self.handleWidth, y: Self.stripTop)
            playhead
                .offset(x: scale.x(for: model.currentTime) - 7, y: Self.rulerHeight + 4)
                .allowsHitTesting(false)
        }
        .frame(width: scale.width, alignment: .topLeading)
        .frame(maxHeight: .infinity, alignment: .top)
        .contentShape(Rectangle())
        .coordinateSpace(name: "track")
        // Click or drag anywhere but a handle to move the playhead.
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .named("track"))
                .onChanged { model.seek(to: scale.time(at: $0.location.x)) }
        )
        .disabled(model.source == nil)
    }

    /// Drawn `rulerOverhang` wider than the track each side, so the end labels are not cut in half.
    private static let rulerOverhang: CGFloat = 40

    private var ruler: some View {
        Canvas { context, size in
            for tick in scale.ticks() {
                let x = scale.x(for: tick) + Self.rulerOverhang
                context.draw(
                    Text(TimelineScale.label(tick)).font(.system(size: 12, weight: .medium).monospacedDigit()).foregroundStyle(Color.white.opacity(0.8)),
                    at: CGPoint(x: x, y: 16)
                )
                var line = Path()
                line.move(to: CGPoint(x: x, y: Self.rulerHeight))
                line.addLine(to: CGPoint(x: x, y: size.height))
                context.stroke(line, with: .color(Studio.divider), lineWidth: 1)
            }
        }
        .frame(width: scale.width + Self.rulerOverhang * 2)
        .frame(maxHeight: .infinity)
        .offset(x: -Self.rulerOverhang)
        .allowsHitTesting(false)
    }

    /// Thumbnails tiled at the clip's aspect, each slot showing the frame nearest its middle.
    private var filmstrip: some View {
        GeometryReader { geometry in
            let aspect = model.source.map { $0.size.width / max($0.size.height, 1) } ?? 16 / 9
            let slots = max(1, Int((geometry.size.width / (Self.stripHeight * aspect)).rounded(.up)))
            let slotWidth = geometry.size.width / CGFloat(slots)
            let frames = TimelineScale.filmstripFrames(slots: slots, frames: model.thumbnails.count)
            HStack(spacing: 0) {
                if frames.isEmpty {
                    Studio.control
                } else {
                    ForEach(Array(frames.enumerated()), id: \.offset) { _, index in
                        Image(decorative: model.thumbnails[index], scale: 1)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: slotWidth, height: Self.stripHeight)
                            .clipped()
                    }
                }
            }
        }
    }

    /// A yellow grip on the strip's edge; dragging it moves that end of the cut.
    private func trimHandle(chevron: String, move: @escaping (TimeInterval) -> Void) -> some View {
        Image(systemName: chevron)
            .font(.system(size: 12, weight: .heavy))
            .foregroundStyle(Color.black.opacity(0.7))
            .frame(width: Self.handleWidth, height: Self.stripHeight)
            .background(RoundedRectangle(cornerRadius: 4).fill(Studio.trim))
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named("track"))
                    .onChanged { move(scale.time(at: $0.location.x)) }
            )
    }

    /// The red line with its pin, from under the ruler to the bottom.
    private var playhead: some View {
        VStack(spacing: 0) {
            Circle().fill(Studio.playhead).frame(width: 14, height: 14)
            Rectangle().fill(Studio.playhead).frame(width: 2)
        }
        .frame(width: 14)
        .frame(maxHeight: .infinity)
    }
}
