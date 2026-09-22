import CoreGraphics
import Foundation
import LightshotKit

/// The one view of the Screen Recording grant shared by the screenshot and recording services, so
/// first-run onboarding and both capture paths agree on it.
///
/// macOS's preflight (`CGPreflightScreenCaptureAccess`) is only two-state — it can't tell a
/// never-asked first run from a standing denial — so a persisted "have we ever asked?" flag
/// recovers the `.notDetermined` case that drives onboarding (story 57). `request()` triggers the
/// one-time system prompt and reports the status as of returning: the OS doesn't wait for the
/// user, so a first ask is always un-authorized here with the prompt still on screen.
enum ScreenRecordingPermission {
    static let hasRequestedDefaultsKey = "com.lightshot.hasRequestedScreenRecordingAccess"

    static func status() -> CaptureAuthorizationStatus {
        if CGPreflightScreenCaptureAccess() {
            return .authorized
        }
        return UserDefaults.standard.bool(forKey: hasRequestedDefaultsKey) ? .denied : .notDetermined
    }

    @discardableResult
    static func request() -> CaptureAuthorizationStatus {
        let granted = CGRequestScreenCaptureAccess()
        UserDefaults.standard.set(true, forKey: hasRequestedDefaultsKey)
        return granted ? .authorized : .denied
    }
}
