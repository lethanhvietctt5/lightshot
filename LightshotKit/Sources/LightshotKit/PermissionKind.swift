import Foundation

/// A macOS permission Lightshot must hold for a capability to work — the unit first-run onboarding
/// (LIG-21) guides the user to grant.
///
/// Only permissions the shipped code **actually** requires appear here. Today that is **Screen
/// Recording** alone: it gates every capture path. **Accessibility / Input Monitoring is deliberately
/// absent** — the global hotkeys use Carbon `RegisterEventHotKey` (see `CarbonHotkeyService`), which
/// claims a system-wide chord *without* it. Add a case only when a shipped feature genuinely needs
/// the grant, so the onboarding never asks for a permission the app doesn't use.
public enum PermissionKind: String, CaseIterable, Sendable, Identifiable {
    /// Screen Recording — required for every capture path; without it captures come back black/empty.
    case screenRecording

    public var id: String { rawValue }
}
