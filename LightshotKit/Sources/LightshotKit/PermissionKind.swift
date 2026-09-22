import Foundation

/// A macOS permission Lightshot must hold for a capability to work.
///
/// Only permissions the shipped code **actually** requires appear here. **Screen Recording** gates
/// every capture and recording path and is the one first-run onboarding (LIG-21) asks for up
/// front. The recording features (spec 0006) add three more, each requested **lazily** the first
/// time its feature is switched on — never at launch — so the app never asks for a grant the user
/// doesn't use: **Microphone** for narration (R7), **Camera** for the webcam bubble (R9), and
/// **Input Monitoring** for the keystroke overlay's listen-only event tap (R11). Accessibility is
/// deliberately absent: the Carbon global hotkeys claim a chord without it (`CarbonHotkeyService`),
/// and the mouse tap for click highlighting needs no grant at all.
public enum PermissionKind: String, CaseIterable, Sendable, Identifiable {
    /// Screen Recording — required for every capture path; without it captures come back black/empty.
    case screenRecording
    /// Microphone — narration in recordings (story 20).
    case microphone
    /// Camera — the webcam bubble (story 26).
    case camera
    /// Input Monitoring — the keystroke overlay's listen-only `CGEvent` tap (story 30).
    case inputMonitoring

    public var id: String { rawValue }
}
