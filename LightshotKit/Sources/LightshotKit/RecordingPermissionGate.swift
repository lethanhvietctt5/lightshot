import Foundation

/// What a lazy permission ask concluded (spec 0006, story 41).
public enum PermissionOutcome: Equatable, Sendable {
    /// A standing grant, or the user granted it in the prompt: the feature can switch on.
    case granted
    /// The OS raised its one-time prompt and returned before the user answered (Screen Recording
    /// behaves this way): the feature stays off for now; the user grants and toggles again.
    case prompting
    /// A standing denial: the feature stays off and the caller shows the recovery path.
    case denied
}

/// The lazy permission gate behind every recording toggle that needs a grant (story 41).
///
/// Pure sequencing over the `PermissionAuthorizing` seam, so it is unit-tested with a fake: nothing
/// prompts until the feature is first switched on; a never-asked permission is requested right then;
/// a standing denial is never re-prompted (the OS would not show a second prompt anyway) but routed
/// to recovery instead.
public enum RecordingPermissionGate {
    public static func ensure(_ source: any PermissionAuthorizing) async -> PermissionOutcome {
        switch await source.authorizationStatus() {
        case .authorized:
            return .granted
        case .denied:
            return .denied
        case .notDetermined:
            return await source.requestAuthorization() == .authorized ? .granted : .prompting
        }
    }
}
