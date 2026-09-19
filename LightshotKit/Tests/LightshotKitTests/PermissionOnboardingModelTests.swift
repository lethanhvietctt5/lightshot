import Testing
import Foundation
@testable import LightshotKit

// First-run permission onboarding (LIG-21): a pure state machine over a fake permission source, so
// the checklist logic — live status, "enable", and the all-granted decision — is verified without
// any real TCC / Screen Recording state. No AppKit / ScreenCaptureKit imports, by design.

// MARK: - Fake

/// A scriptable `PermissionAuthorizing` source: a mutable current `status`, the status a prompt
/// resolves to, and call counts. Narrowed to just the authorization surface `PermissionOnboarding`
/// consumes; `requestAuthorization()` flips `status` to `requestResult`, mimicking the real prompt
/// updating the world. Only ever driven from the `@MainActor` tests.
private final class FakePermission: PermissionAuthorizing, @unchecked Sendable {
    var status: CaptureAuthorizationStatus
    let requestResult: CaptureAuthorizationStatus
    private(set) var statusCount = 0
    private(set) var requestCount = 0

    init(status: CaptureAuthorizationStatus, requestResult: CaptureAuthorizationStatus? = nil) {
        self.status = status
        self.requestResult = requestResult ?? status
    }

    func authorizationStatus() async -> CaptureAuthorizationStatus {
        statusCount += 1
        return status
    }

    @discardableResult
    func requestAuthorization() async -> CaptureAuthorizationStatus {
        requestCount += 1
        status = requestResult
        return requestResult
    }
}

@MainActor
private func onboarding(_ source: FakePermission) -> PermissionOnboardingModel {
    PermissionOnboardingModel(requirements: [
        .init(kind: .screenRecording, title: "Screen Recording", rationale: "Capture your screen.", source: source)
    ])
}

// MARK: - Status & refresh

@MainActor
@Test func startsNotDeterminedThenReflectsAStandingGrantOnRefresh() async {
    // Before any refresh the checklist is optimistically-blank (.notDetermined); refresh reads the
    // real source, so a standing grant flips the row to granted and satisfies onboarding.
    let source = FakePermission(status: .authorized)
    let model = onboarding(source)

    #expect(model.requirements.first?.status == .notDetermined)   // nothing read yet
    #expect(model.isSatisfied == false)

    await model.refresh()

    #expect(source.statusCount == 1)
    #expect(model.requirements.first?.status == .authorized)
    #expect(model.requirements.first?.isGranted == true)
    #expect(model.isSatisfied)
}

@MainActor
@Test func refreshReflectsAStandingDenial() async {
    let model = onboarding(FakePermission(status: .denied))

    await model.refresh()

    #expect(model.requirements.first?.status == .denied)
    #expect(model.isSatisfied == false)   // a denial is not "set up"
}

// MARK: - Enable

@MainActor
@Test func enableTriggersThePromptAndFoldsInTheGrant() async {
    // .notDetermined is a true first run: enabling shows the system prompt, and a granted result
    // lands back on the row, satisfying onboarding.
    let source = FakePermission(status: .notDetermined, requestResult: .authorized)
    let model = onboarding(source)

    await model.enable(.screenRecording)

    #expect(source.requestCount == 1)                              // the prompt fired once
    #expect(model.requirements.first?.status == .authorized)       // …and the grant folded in
    #expect(model.isSatisfied)
}

@MainActor
@Test func enableOnAStandingDenialDoesNotProceed() async {
    // The OS won't re-prompt a standing denial; enabling reports .denied unchanged, so onboarding
    // stays unsatisfied and the view keeps steering the user to System Settings.
    let source = FakePermission(status: .denied, requestResult: .denied)
    let model = onboarding(source)

    await model.enable(.screenRecording)

    #expect(source.requestCount == 1)
    #expect(model.requirements.first?.status == .denied)
    #expect(model.isSatisfied == false)
}

// MARK: - Grant made outside the app (returning from System Settings)

@MainActor
@Test func refreshPicksUpAGrantMadeOutsideTheApp() async {
    // The user opens System Settings, flips the toggle, and returns: a later refresh must reflect the
    // new grant without a restart. Modeled by flipping the fake's status between refreshes.
    let source = FakePermission(status: .denied)
    let model = onboarding(source)

    await model.refresh()
    #expect(model.isSatisfied == false)

    source.status = .authorized      // the user granted it in System Settings
    await model.refresh()

    #expect(model.requirements.first?.status == .authorized)
    #expect(model.isSatisfied)       // re-checked on return to the foreground, no restart
}

// MARK: - Multiple requirements

@MainActor
@Test func isSatisfiedOnlyWhenEveryRequirementIsGranted() async {
    // The checklist is satisfied iff *all* rows are granted — proving the all-or-nothing gate over a
    // list, even though v1 ships a single permission. A second, synthetic requirement stands in.
    let granted = FakePermission(status: .authorized)
    let missing = FakePermission(status: .denied)
    let model = PermissionOnboardingModel(requirements: [
        .init(kind: .screenRecording, title: "Screen Recording", rationale: "Capture your screen.", source: granted),
        .init(kind: .screenRecording, title: "Second", rationale: "Stand-in.", source: missing)
    ])

    await model.refresh()
    #expect(model.isSatisfied == false)          // one row still missing gates the whole checklist

    missing.status = .authorized                 // the last one is granted…
    await model.refresh()

    let allGranted = model.requirements.allSatisfy(\.isGranted)
    #expect(allGranted)
    #expect(model.isSatisfied)                   // …only now is onboarding done
}
