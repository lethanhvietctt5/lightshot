import AppKit
import SwiftUI
import LightshotKit

/// The floating controls pill shown while recording (spec 0006, stories 12–14): pause / resume,
/// stop, restart, discard and the elapsed time, at the top or bottom of the main screen. A
/// non-activating panel, so clicking it never takes focus from the app being recorded; Lightshot's
/// own window, so the content filter keeps it out of the file (story 15).
@MainActor
final class RecordingControlsController {
    struct Actions {
        let pauseResume: () -> Void
        let stop: () -> Void
        let restart: () -> Void
        let discard: () -> Void
    }

    private var panel: NSPanel?
    private var model: RecordingControlsModel?

    /// `audioLevel` is `nil` when the take has no microphone and `systemAudioLevel` when it has no
    /// computer audio; otherwise the meters poll them (stories 23, 25).
    func show(
        position: RecordingControlsPosition, isPaused: Bool, elapsed: @escaping () -> TimeInterval,
        audioLevel: (() -> Float)?, systemAudioLevel: (() -> Float)?, actions: Actions
    ) {
        if let model {
            model.isPaused = isPaused
            return
        }
        let model = RecordingControlsModel(
            isPaused: isPaused, elapsed: elapsed, audioLevel: audioLevel, systemAudioLevel: systemAudioLevel, actions: actions
        )
        self.model = model

        let hosting = NSHostingView(rootView: RecordingControlsView(model: model))
        hosting.layoutSubtreeIfNeeded()
        let size = hosting.fittingSize

        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .screenSaver
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        // Hover highlights and tips need pointer moves even while another app is active.
        panel.acceptsMouseMovedEvents = true
        panel.contentView = hosting

        let screen = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let x = screen.midX - size.width / 2
        let y = position == .top ? screen.maxY - size.height - 16 : screen.minY + 16
        panel.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
        self.panel = panel
        panel.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
        panel = nil
        model = nil
    }
}

@MainActor
@Observable
private final class RecordingControlsModel {
    var isPaused: Bool
    let elapsed: () -> TimeInterval
    let audioLevel: (() -> Float)?
    let systemAudioLevel: (() -> Float)?
    let actions: RecordingControlsController.Actions

    /// The meters' latest readings, `0...1`.
    var level: Float = 0
    var systemLevel: Float = 0
    /// "Your microphone might be muted" (story 24), decided by the pure detector from the readings.
    var showsMutedHint: Bool { detector.showsWarning }
    private var detector = MutedMicrophoneDetector()

    init(
        isPaused: Bool, elapsed: @escaping () -> TimeInterval, audioLevel: (() -> Float)?,
        systemAudioLevel: (() -> Float)?, actions: RecordingControlsController.Actions
    ) {
        self.isPaused = isPaused
        self.elapsed = elapsed
        self.audioLevel = audioLevel
        self.systemAudioLevel = systemAudioLevel
        self.actions = actions
    }

    /// Called ten times a second by the meters' timeline.
    func sample() {
        if let audioLevel {
            level = audioLevel()
            detector.observe(level: level, over: 0.1, paused: isPaused)
        }
        if let systemAudioLevel { systemLevel = systemAudioLevel() }
    }
}

private struct RecordingControlsView: View {
    @State private var model: RecordingControlsModel

    init(model: RecordingControlsModel) {
        _model = State(initialValue: model)
    }

    /// The same chrome as the recorder toolbar (LIG-42): a dark panel, every action in a bordered
    /// box that lights on hover with its title shown at once.
    var body: some View {
        HStack(spacing: 8) {
            // Ticks once a second; the elapsed value itself freezes while paused (RecordingSession).
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                Text(Self.format(model.elapsed()))
                    .font(.system(size: 14, weight: .medium, design: .monospaced))
                    .foregroundStyle(model.isPaused ? Color.white.opacity(0.5) : Color.white)
                    .frame(width: 60, height: ToolbarChrome.controlHeight)
            }
            .toolbarControl(model.isPaused ? "Paused" : "Recording")
            if model.audioLevel != nil || model.systemAudioLevel != nil {
                levelMeters
            }
            control(model.isPaused ? "play.fill" : "pause.fill", title: model.isPaused ? "Resume" : "Pause") {
                model.actions.pauseResume()
            }
            control("stop.fill", title: "Stop", tint: .red) { model.actions.stop() }
            control("arrow.counterclockwise", title: "Restart") { model.actions.restart() }
            control("trash", title: "Discard") { model.actions.discard() }
        }
        .padding(10)
        .toolbarPanel()
        // Room for the tips above and the panel's shadow around it.
        .padding(.top, 44)
        .padding([.horizontal, .bottom], 8)
    }

    /// Small bars that follow the microphone and computer-audio levels (stories 23, 25), with the
    /// muted hint beneath.
    private var levelMeters: some View {
        TimelineView(.periodic(from: .now, by: 0.1)) { context in
            VStack(spacing: 2) {
                if model.audioLevel != nil {
                    meter("mic.fill", level: model.level, warning: model.showsMutedHint)
                        .accessibilityLabel("Microphone level")
                }
                if model.systemAudioLevel != nil {
                    meter("speaker.wave.2.fill", level: model.systemLevel, warning: false)
                        .accessibilityLabel("Computer audio level")
                }
                if model.showsMutedHint {
                    Text("Your microphone might be muted")
                        .font(.system(size: 9))
                        .foregroundStyle(Color.orange)
                }
            }
            .onChange(of: context.date) { _, _ in model.sample() }
        }
    }

    private func meter(_ symbol: String, level: Float, warning: Bool) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.system(size: 11))
                .foregroundStyle(warning ? Color.orange : Color.white.opacity(0.6))
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.25))
                    Capsule()
                        .fill(level > 0.9 ? Color.red : Color.green)
                        .frame(width: geometry.size.width * CGFloat(level))
                }
            }
            .frame(width: 44, height: 6)
        }
    }

    private func control(_ symbol: String, title: String, tint: Color = .white, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: ToolbarChrome.controlWidth, height: ToolbarChrome.controlHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .toolbarControl(title)
    }

    private static func format(_ seconds: TimeInterval) -> String {
        let whole = Int(seconds.rounded(.down))
        return String(format: "%02d:%02d", whole / 60, whole % 60)
    }
}
