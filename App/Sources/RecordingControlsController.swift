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

    func show(position: RecordingControlsPosition, isPaused: Bool, elapsed: @escaping () -> TimeInterval, actions: Actions) {
        if let model {
            model.isPaused = isPaused
            return
        }
        let model = RecordingControlsModel(isPaused: isPaused, elapsed: elapsed, actions: actions)
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
    let actions: RecordingControlsController.Actions

    init(isPaused: Bool, elapsed: @escaping () -> TimeInterval, actions: RecordingControlsController.Actions) {
        self.isPaused = isPaused
        self.elapsed = elapsed
        self.actions = actions
    }
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
