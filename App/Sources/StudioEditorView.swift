import AppKit
import AVFoundation
import SwiftUI
import LightshotKit

/// The Studio editor's colours: one canvas, hairline dividers, dimmed secondary text — theme
/// tokens, so the editor is light or dark with the appearance (spec 0008).
enum StudioStyle {
    static let canvas = Color.theme(.studioCanvas)
    static let divider = Color.theme(.studioDivider)
    static let secondary = Color.theme(.textSecondary)
    static let control = Color.theme(.studioControl)
    static let playhead = Color.theme(.playhead)
    static let clip = Color.theme(.studioClip)
    static let selection = Color.theme(.timelineSelection)
    static let zoom = Color.theme(.zoomAccent)
    static let blue = Color.theme(.accentBlue)
    /// Text and glyphs on an accent fill (the blue, the zoom purple, the text-pill orange).
    static let onAccent = Color.theme(.onAccent)
}

/// The Studio editor (spec 0007, S4): rail · inspector · preview + transport over the timeline,
/// the LIG-43 shell kept.
struct StudioEditorView: View {
    @Bindable var model: StudioEditorModel

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                StudioTitle(model: model)
                    .frame(maxWidth: .infinity)
                    .frame(height: geometry.safeAreaInsets.top)
                    .allowsHitTesting(false)
                StudioStyle.divider.frame(height: 1)
                content
            }
            .ignoresSafeArea(.container, edges: .top)
        }
        .background(StudioStyle.canvas)
        .foregroundStyle(Color.theme(.textPrimary))
        .background { shortcuts }
    }

    private var content: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                StudioRail(model: model)
                StudioStyle.divider.frame(width: 1)
                StudioInspector(model: model)
                    .frame(width: 300)
                StudioStyle.divider.frame(width: 1)
                VStack(spacing: 0) {
                    StudioPreview(model: model)
                    StudioStyle.divider.frame(height: 1)
                    StudioTransport(model: model)
                }
            }
            StudioStyle.divider.frame(height: 1)
            StudioTimelineView(model: model)
                .frame(height: 262)
        }
    }

    /// Keyboard commands (stories 6, 9): hidden buttons carry the shortcuts.
    private var shortcuts: some View {
        ZStack {
            Button("Export") { model.presentExport?() }.keyboardShortcut("e", modifiers: .command)
            Button("Undo") { model.undo() }.keyboardShortcut("z", modifiers: .command)
            Button("Redo") { model.redo() }.keyboardShortcut("z", modifiers: [.command, .shift])
            Button("Split") { model.splitAtPlayhead() }.keyboardShortcut("b", modifiers: .command)
            // Single-key shortcuts stand down while a text field has focus, so typing stays typing.
            Group {
                Button("Split") { model.splitAtPlayhead() }.keyboardShortcut("s", modifiers: [])
                Button("Delete") { model.deleteSelection() }.keyboardShortcut(.delete, modifiers: [])
                Button("Play") { model.togglePlay() }.keyboardShortcut(.space, modifiers: [])
            }
            .disabled(model.isEditingText)
            Button("Deselect") { model.selection = nil; model.isPickingFocus = false }.keyboardShortcut(.escape, modifiers: [])
        }
        .opacity(0)
        .accessibilityHidden(true)
    }
}

/// The project or file name, and **Edited** once something changed.
private struct StudioTitle: View {
    let model: StudioEditorModel

    var body: some View {
        HStack(spacing: 10) {
            Text(model.title)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)
            if model.canUndo {
                Text("Edited").font(.system(size: 13)).foregroundStyle(StudioStyle.secondary)
            }
        }
        .frame(maxWidth: 520)
    }
}

// MARK: - Rail

private struct StudioRail: View {
    @Bindable var model: StudioEditorModel

    var body: some View {
        VStack(spacing: 10) {
            ForEach(StudioEditorModel.Panel.allCases, id: \.self) { panel in
                StudioRailButton(symbol: panel.symbol, title: panel.title, isSelected: model.panel == panel) {
                    model.panel = panel
                }
            }
            Spacer()
        }
        .padding(.vertical, 14)
        .frame(width: 68)
    }
}

struct StudioRailButton: View {
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
                .foregroundStyle(isSelected ? StudioStyle.onAccent : Color.theme(hovered ? .textStrong : .textSecondary))
                .background(RoundedRectangle(cornerRadius: 10).fill(isSelected ? StudioStyle.blue : hovered ? StudioStyle.control : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(title)
        .accessibilityLabel(title)
    }
}

// MARK: - Preview and transport

/// The rendered canvas; a click toggles playback, or sets the selected zoom's focus while picking.
private struct StudioPreview: View {
    let model: StudioEditorModel
    private enum DragTarget { case camera, annotation }
    @State private var dragTarget: DragTarget?

    var body: some View {
        ZStack {
            if let state = model.previewState {
                let canvas = state.layout.canvas
                GeometryReader { geometry in
                    StudioPlayerSurface(player: model.player)
                        .contentShape(Rectangle())
                        // Drag the camera bubble (story 33) or a selected text annotation (story 32)
                        // around the card; one drag, one undo step.
                        .gesture(
                            DragGesture(minimumDistance: 3)
                                .onChanged { value in
                                    let size = geometry.size
                                    let point = CGPoint(x: value.location.x / size.width, y: value.location.y / size.height)
                                    if dragTarget == nil {
                                        let start = CGPoint(x: value.startLocation.x / size.width, y: value.startLocation.y / size.height)
                                        if model.cameraFraction?.contains(start) == true {
                                            dragTarget = .camera
                                        } else if model.selectedAnnotation != nil {
                                            dragTarget = .annotation
                                        } else {
                                            return
                                        }
                                        model.beginChange()
                                    }
                                    switch dragTarget {
                                    case .camera: model.dragCamera(toCanvas: point)
                                    case .annotation: model.dragSelectedAnnotation(toCanvas: point)
                                    case nil: break
                                    }
                                }
                                .onEnded { _ in
                                    if dragTarget != nil { dragTarget = nil; model.endChange() }
                                }
                        )
                        .onTapGesture(coordinateSpace: .local) { location in
                            if model.isPickingFocus {
                                model.pickFocus(atCanvas: CGPoint(x: location.x / geometry.size.width, y: location.y / geometry.size.height))
                            } else {
                                model.togglePlay()
                            }
                        }
                        .overlay {
                            if model.isPickingFocus {
                                RoundedRectangle(cornerRadius: 4).strokeBorder(StudioStyle.zoom, lineWidth: 2)
                                    .allowsHitTesting(false)
                            }
                        }
                        .onHover { inside in
                            if model.isPickingFocus, inside { NSCursor.crosshair.push() } else { NSCursor.pop() }
                        }
                }
                .aspectRatio(CGSize(width: max(canvas.width, 1), height: max(canvas.height, 1)), contentMode: .fit)
                .shadow(color: .theme(.previewShadow), radius: 16, y: 6)
            } else if let error = model.loadError {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(StudioStyle.secondary)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .padding(.horizontal, 32)
        .padding(.top, 28)
        .padding(.bottom, 44)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .bottom) {
            if model.isPickingFocus {
                Text("Click the preview where the zoom should look · Esc to cancel")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(StudioStyle.onAccent)
                    .padding(.horizontal, 10).frame(height: 24)
                    .background(Capsule().fill(StudioStyle.zoom.opacity(0.85)))
                    .padding(.bottom, 12)
            } else if model.sources != nil {
                StudioOutputSummary(model: model).padding(.bottom, 12)
            }
        }
    }
}

/// What the export will produce, under the preview.
private struct StudioOutputSummary: View {
    let model: StudioEditorModel

    var body: some View {
        HStack(spacing: 6) {
            if let size = model.outputSize {
                chip("\(Int(size.width)) × \(Int(size.height))", systemImage: "aspectratio")
            }
            chip("\(model.edits.output.fps) fps · \(model.edits.output.codec.title)", systemImage: "film")
            chip(model.edits.output.format.title, systemImage: "doc")
            chip("≈ \(model.estimateText)", systemImage: "internaldrive")
        }
    }

    private func chip(_ text: String, systemImage: String) -> some View {
        Label(text, systemImage: systemImage)
            .font(.system(size: 11, weight: .medium).monospacedDigit())
            .foregroundStyle(StudioStyle.secondary)
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(Capsule().fill(StudioStyle.control))
    }
}

private struct StudioTransport: View {
    @Bindable var model: StudioEditorModel

    var body: some View {
        ZStack {
            HStack(spacing: 0) {
                HStack(spacing: 6) {
                    Text(TimelineScale.label(model.currentTime))
                    Text("/").foregroundStyle(StudioStyle.secondary)
                    Text(TimelineScale.label(model.duration)).foregroundStyle(StudioStyle.secondary)
                }
                .font(.system(size: 14, weight: .medium).monospacedDigit())
                Spacer()
                HStack(spacing: 8) {
                    iconButton("minus", help: "Zoom out the timeline") { model.timelineZoom = max(1, model.timelineZoom / 1.5) }
                    Slider(value: $model.timelineZoom, in: 1...8).controlSize(.small).frame(width: 110)
                    iconButton("plus", help: "Zoom in the timeline") { model.timelineZoom = min(8, model.timelineZoom * 1.5) }
                }
            }
            HStack(spacing: 26) {
                transportButton("backward.end.fill", title: "Go to start", size: 17) { model.skipToStart() }
                transportButton(model.isPlaying ? "pause.fill" : "play.fill", title: model.isPlaying ? "Pause" : "Play", size: 22) { model.togglePlay() }
                transportButton("forward.end.fill", title: "Go to end", size: 17) { model.skipToEnd() }
            }
        }
        .padding(.horizontal, 20)
        .frame(height: 60)
        .disabled(model.sources == nil)
    }

    private func transportButton(_ symbol: String, title: String, size: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: size)).frame(width: 32, height: 32).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(title)
        .accessibilityLabel(title)
    }

    private func iconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 11, weight: .semibold)).foregroundStyle(StudioStyle.secondary)
                .frame(width: 18, height: 18).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// An `AVPlayerLayer` filling the view.
struct StudioPlayerSurface: NSViewRepresentable {
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
            // Content, not chrome (spec 0008): the video's letterbox is black in either appearance.
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

// MARK: - Export

/// Format and destination, progress with Cancel, and Revert for a replaced plain movie.
struct StudioExportPanel: View {
    @Bindable var model: StudioEditorModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Export").font(.system(size: 14, weight: .semibold))
            Picker("Format", selection: Binding(get: { model.edits.output.format }, set: { model.set(\.output.format, $0) })) {
                ForEach(StudioOutputFormat.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            if !model.isProject {
                Picker("Save", selection: $model.saveMode) {
                    Text("As a new file").tag(StudioEditorModel.SaveMode.newFile)
                    Text("Replace the original").tag(StudioEditorModel.SaveMode.replace)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            HStack {
                if let size = model.outputSize {
                    Text("\(Int(size.width)) × \(Int(size.height)) · \(model.edits.output.fps) fps").foregroundStyle(.secondary)
                }
                Spacer()
                Text("≈ \(model.estimateText)").monospacedDigit()
            }
            .font(.system(size: 12))
            Text(model.isProject
                 ? "Saved to your recordings folder and History, like any recording."
                 : "Output size, frame rate, codec and quality are in the Output panel.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Export") { model.export() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.isExporting || model.sources == nil)
            }
            if model.isExporting {
                HStack {
                    ProgressView(value: model.progress)
                    Button("Cancel") { model.cancelExport() }
                }
            }
            if let message = model.message { Text(message).font(.system(size: 11)).foregroundStyle(.secondary) }
            if let error = model.error { Text(error).font(.system(size: 11)).foregroundStyle(.red) }
            if model.backup != nil {
                Button("Revert to Original") { model.revert() }.disabled(model.isExporting)
            }
        }
        .padding(16)
        .frame(width: 320)
    }
}
