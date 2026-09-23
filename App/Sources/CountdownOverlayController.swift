import AppKit
import SwiftUI
import LightshotKit

/// The 3-2-1 countdown before a take (spec 0006, story 10): a large number centred on the main
/// screen in a transparent, screen-saver-level window, ticking once a second with a sound, until
/// zero — or until Escape, which resolves `false` so the coordinator discards the take. A dark HUD
/// in either appearance (spec 0008): it is read against the screen.
///
/// A thin OS wrapper. The window is Lightshot's own, so the content filter keeps it out of the
/// recording (story 15). It ignores the mouse, so the user can click into the app they are about
/// to record while it counts; it is key only for Escape, and hands activation back when it ends.
@MainActor
final class CountdownOverlayController {
    private var window: OverlayKeyWindow?
    private var continuation: CheckedContinuation<Bool, Never>?
    private var task: Task<Void, Never>?

    /// Runs the countdown and returns whether it reached zero.
    func run(seconds: Int, playSounds: Bool) async -> Bool {
        finish(false)   // never leave a stale countdown behind
        let model = CountdownModel(remaining: seconds)
        let screen = NSScreen.main ?? NSScreen.screens.first
        let frame = screen?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)

        let window = OverlayKeyWindow.fullScreen(frame: frame)
        window.ignoresMouseEvents = true
        window.onCancel = { [weak self] in self?.finish(false) }
        window.contentView = NSHostingView(rootView: CountdownView(model: model))
        window.setFrame(frame, display: true)
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)

        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            task = Task { [weak self] in
                for remaining in stride(from: seconds, through: 1, by: -1) {
                    model.remaining = remaining
                    RecordingSounds.play(.tick, enabled: playSounds)
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    if Task.isCancelled { return }
                }
                self?.finish(true)
            }
        }
    }

    /// Dismiss a countdown that something else ended (the hotkey stopping the take). Resolves
    /// `false`; a no-op when none is running.
    func cancel() {
        finish(false)
    }

    private func finish(_ completed: Bool) {
        task?.cancel()
        task = nil
        guard let window else { return }
        window.orderOut(nil)
        self.window = nil
        // Give activation back to whatever the user was in, so the take starts with their app
        // frontmost rather than Lightshot.
        NSApp.deactivate()
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(returning: completed)
    }
}

@MainActor
@Observable
private final class CountdownModel {
    var remaining: Int
    init(remaining: Int) { self.remaining = remaining }
}

private struct CountdownView: View {
    @State private var model: CountdownModel

    init(model: CountdownModel) {
        _model = State(initialValue: model)
    }

    var body: some View {
        ZStack {
            Color.clear
            VStack(spacing: 12) {
                Text("\(model.remaining)")
                    .font(.system(size: 160, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .contentTransition(.numericText(countsDown: true))
                    .animation(.easeOut(duration: 0.2), value: model.remaining)
                Text("Esc to cancel")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.8))
            }
            .padding(48)
            .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 28))
        }
        .ignoresSafeArea()
    }
}
