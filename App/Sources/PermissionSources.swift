import AVFoundation
import CoreGraphics
import LightshotKit

/// The OS side of the recording permissions (spec 0006, story 41): one `PermissionAuthorizing` per
/// grant, each requested lazily by the feature that needs it. Screen Recording keeps its own
/// (`ScreenRecordingPermission`, shared with the screenshot path).
///
/// Microphone and camera go through AVFoundation, whose `requestAccess` **waits** for the user's
/// answer, so a first ask resolves to the real decision (`requestWaitsForAnswer`). Input Monitoring
/// goes through the CoreGraphics event-access API; like Screen Recording its request returns
/// immediately with the prompt still on screen, and its `.notDetermined` is recovered from a
/// persisted "asked once" flag — a belief `PermissionGate` re-checks by asking again anyway.
struct AVCapturePermission: PermissionAuthorizing {
    let mediaType: AVMediaType

    static let microphone = AVCapturePermission(mediaType: .audio)
    static let camera = AVCapturePermission(mediaType: .video)

    var requestWaitsForAnswer: Bool { true }

    func authorizationStatus() async -> CaptureAuthorizationStatus {
        switch AVCaptureDevice.authorizationStatus(for: mediaType) {
        case .authorized: return .authorized
        case .notDetermined: return .notDetermined
        case .denied, .restricted: return .denied
        @unknown default: return .denied
        }
    }

    @discardableResult
    func requestAuthorization() async -> CaptureAuthorizationStatus {
        await AVCaptureDevice.requestAccess(for: mediaType) ? .authorized : .denied
    }
}

struct InputMonitoringPermission: PermissionAuthorizing {
    static let hasRequestedDefaultsKey = "com.lightshot.hasRequestedInputMonitoringAccess"

    func authorizationStatus() async -> CaptureAuthorizationStatus {
        if CGPreflightListenEventAccess() { return .authorized }
        return UserDefaults.standard.bool(forKey: Self.hasRequestedDefaultsKey) ? .denied : .notDetermined
    }

    @discardableResult
    func requestAuthorization() async -> CaptureAuthorizationStatus {
        let granted = CGRequestListenEventAccess()
        UserDefaults.standard.set(true, forKey: Self.hasRequestedDefaultsKey)
        return granted ? .authorized : .denied
    }
}

/// The System Settings pane where each grant is flipped by hand, and the words the recovery alert
/// and onboarding use for it.
extension PermissionKind {
    var systemSettingsURL: URL {
        let pane: String
        switch self {
        case .screenRecording: pane = "Privacy_ScreenCapture"
        case .microphone: pane = "Privacy_Microphone"
        case .camera: pane = "Privacy_Camera"
        case .inputMonitoring: pane = "Privacy_ListenEvent"
        }
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!
    }

    /// The user-facing name of the grant, as System Settings labels it.
    var settingsTitle: String {
        switch self {
        case .screenRecording: return "Screen Recording"
        case .microphone: return "Microphone"
        case .camera: return "Camera"
        case .inputMonitoring: return "Input Monitoring"
        }
    }

    /// One sentence on what stops working without it, for the recovery alert.
    var recoveryReason: String {
        switch self {
        case .screenRecording: return "Lightshot needs Screen Recording permission to capture your screen."
        case .microphone: return "Lightshot needs Microphone permission to record your narration."
        case .camera: return "Lightshot needs Camera permission to show you in the recording."
        case .inputMonitoring: return "Lightshot needs Input Monitoring permission to show the keys you press."
        }
    }
}
