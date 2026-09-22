import Foundation

/// What a permission ask concluded.
public enum PermissionOutcome: Equatable, Sendable {
    /// A standing grant, or the user granted it in the prompt: the feature can switch on.
    case granted
    /// The OS raised its one-time prompt and returned before the user answered (Screen Recording,
    /// Input Monitoring): the feature stays off for now; the user grants and toggles again.
    case prompting
    /// The user declined — now, or earlier: the feature stays off and the caller shows recovery.
    case denied
}

/// The one permission-asking policy, shared by first-run onboarding (`PermissionOnboardingModel`)
/// and the recording toggles' lazy gate (spec 0006, story 41).
///
/// Pure sequencing over the `PermissionAuthorizing` seam, unit-tested with a fake. The rules:
/// a standing grant passes without a prompt; otherwise the OS is **always asked** — even when we
/// believe the grant was denied, because that belief is a best guess (a two-state preflight plus a
/// remembered "we asked once" flag) that goes stale whenever the OS forgets the app (a TCC reset, a
/// re-signed build), asking is free (the OS prompts at most once per app identity), and asking is
/// what lists the app in System Settings. The result is then read: granted if the ask (or the
/// grant it triggered) authorised; `denied` when we already believed so or the ask waited for the
/// user and they declined; `prompting` when the ask returned before the answer.
public enum PermissionGate {
    public static func ensure(_ source: any PermissionAuthorizing) async -> PermissionOutcome {
        let before = await source.authorizationStatus()
        if before == .authorized { return .granted }
        let after = await source.requestAuthorization()
        if after == .authorized { return .granted }
        if before == .denied || source.requestWaitsForAnswer { return .denied }
        return .prompting
    }
}
