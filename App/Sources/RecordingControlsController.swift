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

    /// `audioLevel` is `nil` when the take has no microphone; otherwise the meter polls it (story 23).
    func show(
        position: RecordingControlsPosition, isPaused: Bool, elapsed: @escaping () -> TimeInterval,
        audioLevel: (() -> Float)?, actions: Actions
    ) {
        if let model {
            model.isPaused = isPaused
            return
        }
        let model = RecordingControlsModel(isPaused: isPaused, elapsed: elapsed, audioLevel: audioLevel, actions: actions)
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
    let actions: RecordingControlsController.Actions

    /// The meter's latest reading, `0...1`.
    var level: Float = 0
    /// "Your microphone might be muted" (story 24): shown when the first seconds of the take stay
    /// silent, hidden for good once any sound arrives.
    private(set) var showsMutedHint = false
    private var silentTicks = 0
    private var heardSound = false

    init(isPaused: Bool, elapsed: @escaping () -> TimeInterval, audioLevel: (() -> Float)?, actions: RecordingControlsController.Actions) {
        self.isPaused = isPaused
        self.elapsed = elapsed
        self.audioLevel = audioLevel
        self.actions = actions
    }

    /// Called ten times a second by the meter's timeline.
    func sample() {
        guard let audioLevel else { return }
        level = audioLevel()
        if level > Self.silence {
            heardSound = true
            showsMutedHint = false
        } else if !heardSound, !isPaused {
            silentTicks += 1
            if silentTicks >= Self.mutedAfterTicks { showsMutedHint = true }
        }
    }

    private static let silence: Float = 0.04
    private static let mutedAfterTicks = 30   // three seconds at 10 Hz
}

private struct RecordingControlsView: View {
    @State private var model: RecordingControlsModel

    init(model: RecordingControlsModel) {
        _model = State(initialValue: model)
    }

    var body: some View {
        HStack(spacing: 6) {
            // Ticks once a second; the elapsed value itself freezes while paused (RecordingSession).
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                Text(Self.format(model.elapsed()))
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .foregroundStyle(model.isPaused ? .secondary : .primary)
                    .frame(width: 52)
            }
            if model.audioLevel != nil {
                levelMeter
            }
            control(model.isPaused ? "play.fill" : "pause.fill", help: model.isPaused ? "Resume" : "Pause") {
                model.actions.pauseResume()
            }
            control("stop.fill", help: "Stop", tint: .red) { model.actions.stop() }
            control("arrow.counterclockwise", help: "Restart") { model.actions.restart() }
            control("trash", help: "Discard") { model.actions.discard() }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: Capsule())
        .padding(8)
    }

    /// A small bar that follows the microphone level (story 23), with the muted hint beneath it.
    private var levelMeter: some View {
        TimelineView(.periodic(from: .now, by: 0.1)) { context in
            VStack(spacing: 2) {
                HStack(spacing: 4) {
                    Image(systemName: "mic.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(model.showsMutedHint ? Color.orange : Color.secondary)
                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.secondary.opacity(0.25))
                            Capsule()
                                .fill(model.level > 0.9 ? Color.red : Color.green)
                                .frame(width: geometry.size.width * CGFloat(model.level))
                        }
                    }
                    .frame(width: 44, height: 6)
                }
                if model.showsMutedHint {
                    Text("Mic may be muted")
                        .font(.system(size: 9))
                        .foregroundStyle(Color.orange)
                }
            }
            .onChange(of: context.date) { _, _ in model.sample() }
        }
        .help("Microphone level")
    }

    private func control(_ symbol: String, help: String, tint: Color = .primary, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 28, height: 28)
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private static func format(_ seconds: TimeInterval) -> String {
        let whole = Int(seconds.rounded(.down))
        return String(format: "%02d:%02d", whole / 60, whole % 60)
    }
}
