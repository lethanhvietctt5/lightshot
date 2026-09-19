import SwiftUI
import AppKit
import LightshotKit

/// First-run onboarding (LIG-21): a checklist that walks the user through granting every permission
/// Lightshot needs *before* they capture, so a missing grant never shows up as a broken app.
///
/// A thin projection of `PermissionOnboardingModel` — each row shows a permission's live status with
/// a contextual action (trigger the system prompt, or deep-link to System Settings for a standing
/// denial), and the whole surface re-checks when the app returns to the foreground after a visit to
/// System Settings, so a grant made there lands without a restart. All the decision logic lives in
/// the (tested, framework-free) model; this file is only AppKit/SwiftUI.
struct PermissionOnboardingView: View {
    let model: PermissionOnboardingModel
    /// Opens the System Settings pane for a permission the user must grant by hand (a standing denial).
    let openSettings: (PermissionKind) -> Void
    /// Dismisses the onboarding window.
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            header
            VStack(spacing: 0) {
                ForEach(Array(model.requirements.enumerated()), id: \.element.id) { index, requirement in
                    if index > 0 { Divider() }
                    row(for: requirement)
                }
            }
            .padding(.vertical, 4)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
            footer
        }
        .padding(24)
        .frame(width: 460)
        // Read the real statuses on appear…
        .task { await model.refresh() }
        // …and again whenever the app comes back to the front (e.g. returning from System Settings),
        // so a grant made outside the app is reflected without a restart.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await model.refresh() }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Welcome to Lightshot")
                .font(.title2.bold())
            Text("Lightshot needs a few permissions to capture your screen. Grant them here to get set up.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func row(for requirement: PermissionOnboardingModel.Requirement) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: requirement.isGranted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .font(.title3)
                .foregroundStyle(requirement.isGranted ? Color.green : Color.orange)
                .accessibilityLabel(requirement.isGranted ? "Granted" : "Not granted")

            VStack(alignment: .leading, spacing: 2) {
                Text(requirement.title).font(.headline)
                Text(requirement.rationale)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 12)

            action(for: requirement)
        }
        .padding(12)
    }

    /// The trailing control, chosen by the permission's live status:
    /// - granted → a static "Enabled" confirmation, no action needed;
    /// - denied → the OS won't re-prompt, so deep-link to System Settings;
    /// - not-yet-asked → trigger the one-time system prompt.
    @ViewBuilder
    private func action(for requirement: PermissionOnboardingModel.Requirement) -> some View {
        switch requirement.status {
        case .authorized:
            Label("Enabled", systemImage: "checkmark")
                .labelStyle(.titleAndIcon)
                .font(.callout)
                .foregroundStyle(.green)
        case .denied:
            Button("Open System Settings") { openSettings(requirement.kind) }
        case .notDetermined:
            Button("Enable") { Task { await model.enable(requirement.kind) } }
                .buttonStyle(.borderedProminent)
        }
    }

    private var footer: some View {
        HStack {
            if model.isSatisfied {
                Label("All set — you're ready to capture.", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green)
                    .font(.callout)
            } else {
                Text("You can grant these later, but capture won't work until Screen Recording is on.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 12)

            if model.isSatisfied {
                Button("Done") { onClose() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            } else {
                Button("Skip for Now") { onClose() }
            }
        }
    }
}
