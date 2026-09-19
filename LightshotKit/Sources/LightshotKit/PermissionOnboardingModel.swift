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

    /// Build the onboarding over a set of required permissions.
    public init(requirements: [Requirement]) {
        self.requirements = requirements
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

    /// Trigger the system prompt for one permission and fold the result back into its row.
    ///
    /// For a `.notDetermined` permission this shows the OS prompt; for a standing `.denied` the OS
    /// won't re-prompt (the user must re-enable it in System Settings), and the returned status
    /// reflects that — so the row stays un-granted and the view keeps offering the settings deep link.
    public func enable(_ kind: PermissionKind) async {
        guard let index = requirements.firstIndex(where: { $0.kind == kind }) else { return }
        requirements[index].status = await requirements[index].source.requestAuthorization()
    }
}
