import Testing
import Foundation
@testable import LightshotKit

// The one permission-asking policy (spec 0006, story 41; LIG-21): a standing grant passes without a
// prompt; otherwise the OS is always asked, and the outcome tells a decline from a prompt still on
// screen.

private final class FakePermission: PermissionAuthorizing, @unchecked Sendable {
    var status: CaptureAuthorizationStatus
    let afterRequest: CaptureAuthorizationStatus
    let requestWaitsForAnswer: Bool
    private(set) var requests = 0
    init(_ status: CaptureAuthorizationStatus, afterRequest: CaptureAuthorizationStatus = .authorized, waits: Bool = false) {
        self.status = status
        self.afterRequest = afterRequest
        self.requestWaitsForAnswer = waits
    }
    func authorizationStatus() async -> CaptureAuthorizationStatus { status }
    func requestAuthorization() async -> CaptureAuthorizationStatus { requests += 1; status = afterRequest; return afterRequest }
}

@Test func aStandingGrantPassesWithoutPrompting() async {
    let mic = FakePermission(.authorized)
    #expect(await PermissionGate.ensure(mic) == .granted)
    #expect(mic.requests == 0)
}

@Test func aFirstAskThatWaitsReportsTheUsersDecision() async {
    let granted = FakePermission(.notDetermined, afterRequest: .authorized, waits: true)
    #expect(await PermissionGate.ensure(granted) == .granted)
    #expect(granted.requests == 1)

    let declined = FakePermission(.notDetermined, afterRequest: .denied, waits: true)   // "Don't Allow"
    #expect(await PermissionGate.ensure(declined) == .denied)                        // → recovery, not silence
}

@Test func aFirstAskThatReturnsBeforeTheAnswerIsPromptingNotDenied() async {
    let screen = FakePermission(.notDetermined, afterRequest: .denied)   // Screen Recording returns at once
    #expect(await PermissionGate.ensure(screen) == .prompting)
}

@Test func aBelievedDenialIsStillAskedSoAForgottenAppGetsListedAgain() async {
    // The "denied" belief is a stale flag after a TCC reset: asking is free and re-lists the app.
    let reset = FakePermission(.denied, afterRequest: .authorized)
    #expect(await PermissionGate.ensure(reset) == .granted)
    #expect(reset.requests == 1)

    let still = FakePermission(.denied, afterRequest: .denied)
    #expect(await PermissionGate.ensure(still) == .denied)
    #expect(still.requests == 1)
}

@Test func eachToggleNamesTheGrantItNeeds() {
    #expect(RecordingToggle.microphone.requiredPermission == .microphone)
    #expect(RecordingToggle.camera.requiredPermission == .camera)
    #expect(RecordingToggle.showKeystrokes.requiredPermission == .inputMonitoring)
    #expect(RecordingToggle.computerAudio.requiredPermission == nil)
    #expect(RecordingToggle.highlightClicks.requiredPermission == nil)
    // Speech Recognition (spec 0007, round 2) is the Studio editor's, not a recorder toggle's.
    #expect(PermissionKind.allCases == [.screenRecording, .microphone, .camera, .inputMonitoring, .speechRecognition])
}
