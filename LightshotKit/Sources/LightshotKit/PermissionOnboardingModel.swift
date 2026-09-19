import Foundation
import Observation

/// The first-run onboarding state machine (LIG-21): a checklist of the permissions Lightshot needs,
/// each with its live authorization status, driven purely through the `PermissionAuthorizing` seam.
///
/// It owns no OS/TCC calls of its own — every status read and prompt goes through an injected
/// `PermissionAuthorizing` source — so the whole thing is a pure state machine, unit-tested against
/// a fake without a real Screen Recording grant (per AGENTS.md: no ScreenCaptureKit/AppKit here).
/// The app shell supplies the concrete sources (Screen Recording is wired to the same
/// `SCCaptureService` the coordinator uses) and renders `requirements` as a checklist; the *decision*
/// logic — what's granted, whether onboarding is done — lives here.
///
/// This is the proactive, first-run counterpart to LIG-19's reactive, mid-capture recovery: this
/// model guides the user to grant permission *before* they capture; LIG-19 still catches a permission
/// revoked later, at capture time.
@MainActor
@Observable
public final class PermissionOnboardingModel {
    /// One row of the checklist: a required permission, why it's needed, the source that reports it,
    /// and its live status. The `source` is carried on the row itself (not a parallel array), so a
    /// requirement and the seam it reads through never fall out of alignment; it stays `internal`, so
    /// the view sees only the user-facing fields.
    public struct Requirement: Identifiable, Sendable {
        /// Which permission this row represents.
        public let kind: PermissionKind
        /// The user-facing name shown in the checklist (e.g. "Screen Recording").
        public let title: String
        /// One line explaining *why* the app needs it, so the ask is never unexplained.
        public let rationale: String
        /// The live authorization status, refreshed from the source.
        public internal(set) var status: CaptureAuthorizationStatus
        /// The seam this row reads/requests through — injected, so the model needs no real TCC state.
        let source: any PermissionAuthorizing

        public var id: PermissionKind { kind }

        /// Whether the user has granted this permission.
        public var isGranted: Bool { status == .authorized }

        /// Describe a required permission. Status starts `.notDetermined` and is filled in by the
        /// first `refresh()`.
        public init(
            kind: PermissionKind,
            title: String,
            rationale: String,
            source: any PermissionAuthorizing
        ) {
            self.kind = kind
            self.title = title
            self.rationale = rationale
            self.status = .notDetermined
            self.source = source
        }
    }

    /// The checklist, in the order supplied at construction. Each row tracks its own live status.
    public private(set) var requirements: [Requirement]

    /// Opens the System Settings pane for a permission the user must grant by hand. Injected so the
    /// decision of *when* to send the user there lives here, tested, rather than in the view.
    private let openSettings: (PermissionKind) -> Void

    /// Build the onboarding over a set of required permissions.
    public init(requirements: [Requirement], openSettings: @escaping (PermissionKind) -> Void = { _ in }) {
        self.requirements = requirements
        self.openSettings = openSettings
    }

    /// True once every required permission is granted — the point at which onboarding can be
    /// dismissed and need not reappear on later launches. Empty requirements count as satisfied.
    public var isSatisfied: Bool {
        requirements.allSatisfy(\.isGranted)
    }

    /// Re-read every permission's status from its source. Call on appearance and whenever the app
    /// returns to the foreground (e.g. after the user visited System Settings), so the checklist
    /// reflects a grant made *outside* the app — without a restart.
    public func refresh() async {
        for index in requirements.indices {
            requirements[index].status = await requirements[index].source.authorizationStatus()
        }
    }

    /// The row's one action: ask the OS for the permission, fold the result back into the row, and —
    /// for a row we believed was a standing denial — take the user to System Settings.
    ///
    /// The OS is asked **even when the row reads `.denied`**. That status is only a best guess (a
    /// two-state preflight plus a remembered "we asked once" flag), and it goes stale whenever the OS
    /// forgets the app — a TCC reset, or a re-signed build. Asking is free (the OS prompts at most
    /// once per app identity) and it is what lists the app in System Settings, so skipping it can
    /// strand the user in a pane with nothing to switch on.
    ///
    /// A `.notDetermined` row does *not* open System Settings: the system prompt it raises already
    /// offers that, and the request returns immediately rather than waiting for the user's answer.
    public func enable(_ kind: PermissionKind) async {
        guard let index = requirements.firstIndex(where: { $0.kind == kind }) else { return }
        let believedDenied = requirements[index].status == .denied
        let status = await requirements[index].source.requestAuthorization()
        requirements[index].status = status
        if believedDenied, status != .authorized {
            openSettings(kind)
        }
    }
}
