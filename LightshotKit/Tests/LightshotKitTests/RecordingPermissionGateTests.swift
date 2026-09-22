import Testing
import Foundation
@testable import LightshotKit

// The lazy permission gate behind the recording toggles (spec 0006, story 41): nothing prompts
// until a feature is switched on; a first ask requests right then; a standing denial is routed to
// recovery, never re-prompted.

private final class FakePermission: PermissionAuthorizing, @unchecked Sendable {
    var status: CaptureAuthorizationStatus
    let afterRequest: CaptureAuthorizationStatus
    private(set) var requests = 0
    init(_ status: CaptureAuthorizationStatus, afterRequest: CaptureAuthorizationStatus = .authorized) {
        self.status = status
        self.afterRequest = afterRequest
    }
    func authorizationStatus() async -> CaptureAuthorizationStatus { status }
    func requestAuthorization() async -> CaptureAuthorizationStatus { requests += 1; status = afterRequest; return afterRequest }
}

@Test func aStandingGrantPassesWithoutPrompting() async {
    let mic = FakePermission(.authorized)
    #expect(await RecordingPermissionGate.ensure(mic) == .granted)
    #expect(mic.requests == 0)
}

@Test func aFirstAskPromptsAndPassesWhenTheUserGrants() async {
    let camera = FakePermission(.notDetermined, afterRequest: .authorized)   // AVFoundation waits for the answer
    #expect(await RecordingPermissionGate.ensure(camera) == .granted)
    #expect(camera.requests == 1)
}

@Test func aFirstAskThatReturnsBeforeTheAnswerIsPromptingNotDenied() async {
    let screen = FakePermission(.notDetermined, afterRequest: .denied)   // Screen Recording returns at once
    #expect(await RecordingPermissionGate.ensure(screen) == .prompting)
}

@Test func aStandingDenialIsNeverRePromptedAndRoutesToRecovery() async {
    let keys = FakePermission(.denied)
    #expect(await RecordingPermissionGate.ensure(keys) == .denied)
    #expect(keys.requests == 0)
}

@Test func eachToggleNamesTheGrantItNeeds() {
    #expect(RecordingToggle.microphone.requiredPermission == .microphone)
    #expect(RecordingToggle.camera.requiredPermission == .camera)
    #expect(RecordingToggle.showKeystrokes.requiredPermission == .inputMonitoring)
    #expect(RecordingToggle.computerAudio.requiredPermission == nil)
    #expect(RecordingToggle.highlightClicks.requiredPermission == nil)
    #expect(PermissionKind.allCases.count == 4)
}
