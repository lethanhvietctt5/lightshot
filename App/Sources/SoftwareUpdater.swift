import AppKit
import Observation
import Sparkle

/// In-app software updates (spec 0015): a thin owner of Sparkle's standard updater.
///
/// Sparkle does the work: it reads the update feed published with each GitHub Release, verifies the
/// DMG's EdDSA signature against `SUPublicEDKey`, replaces the app in place and relaunches it. It
/// also persists the update preferences in the app's user defaults (`SUEnableAutomaticChecks`,
/// `SUAutomaticallyUpdate`), so the settings here are a live view of Sparkle's, never a copy
/// (story 31). With no `SUEnableAutomaticChecks` key in `Info.plist`, Sparkle asks on the second
/// launch whether to check automatically (stories 2–3). Update checks are the app's only network
/// access (ADR 0002).
@MainActor
@Observable
final class SoftwareUpdater: NSObject {
    /// Whether a manual check can start now; false while an update session is already running.
    private(set) var canCheckForUpdates = false
    /// When the feed was last checked; `nil` before the first check.
    private(set) var lastCheckDate: Date?
    /// The version a scheduled check found while Lightshot was in the background (story 9). The
    /// menu-bar icon wears a dot and the menu offers it until the update session ends.
    private(set) var pendingUpdateVersion: String? {
        didSet { if pendingUpdateVersion != oldValue { onPendingUpdateChange?() } }
    }
    /// Called when `pendingUpdateVersion` changes, so the status item can redraw its icon.
    @ObservationIgnored var onPendingUpdateChange: (() -> Void)?

    /// Check the feed about once a day (`SUScheduledCheckInterval`).
    var automaticallyChecks: Bool {
        didSet {
            guard automaticallyChecks != oldValue, !isRefreshing else { return }
            updater?.automaticallyChecksForUpdates = automaticallyChecks
            refresh()
        }
    }
    /// Download updates in the background and install them when Lightshot quits (stories 26–27).
    /// Sparkle ignores it while automatic checks are off (story 28).
    var automaticallyInstalls: Bool {
        didSet {
            guard automaticallyInstalls != oldValue, !isRefreshing else { return }
            updater?.automaticallyDownloadsUpdates = automaticallyInstalls
            refresh()
        }
    }

    /// True while a relaunch would cut off work in progress (a take, a GIF conversion, filing into
    /// history); the relaunch waits until it turns false (story 21).
    @ObservationIgnored private let hasWorkInProgress: () -> Bool
    @ObservationIgnored private var controller: SPUStandardUpdaterController?
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    @ObservationIgnored private var postponedRelaunch: Task<Void, Never>?
    /// Set while `refresh` mirrors Sparkle's values in, so the setters don't write them back.
    @ObservationIgnored private var isRefreshing = false

    private var updater: SPUUpdater? { controller?.updater }

    init(hasWorkInProgress: @escaping () -> Bool) {
        self.hasWorkInProgress = hasWorkInProgress
        automaticallyChecks = false
        automaticallyInstalls = false
        super.init()
    }

    /// Start the updater. Called once at launch; the first scheduled check follows Sparkle's
    /// schedule, never this call.
    func start() {
        guard controller == nil else { return }
        let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: self)
        self.controller = controller
        let updater = controller.updater
        // Sparkle's KVO-compliant state: a session starting or ending, and the preferences changing
        // behind the settings' back (its second-launch question).
        let keyPaths: [KeyPath<SPUUpdater, Bool>] = [
            \.canCheckForUpdates, \.automaticallyChecksForUpdates, \.automaticallyDownloadsUpdates,
        ]
        observations = keyPaths.map { keyPath in
            updater.observe(keyPath, options: [.new]) { [weak self] _, _ in
                Task { @MainActor in self?.refresh() }
            }
        }
        refresh()
    }

    /// A user-initiated check (the menu, the About pane, Settings): Sparkle's window always shows,
    /// brought to the front like every other Lightshot window. It says so when Lightshot is up to
    /// date, and when the check fails (stories 5–8).
    func checkForUpdates() {
        WindowPresenter.activateApp()
        controller?.checkForUpdates(nil)
    }

    /// Re-read Sparkle's state into the observable properties.
    func refresh() {
        guard let updater else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        canCheckForUpdates = updater.canCheckForUpdates
        lastCheckDate = updater.lastUpdateCheckDate
        automaticallyChecks = updater.automaticallyChecksForUpdates
        automaticallyInstalls = updater.automaticallyDownloadsUpdates
    }

    #if DEBUG
    /// Development aid: a scheduled-style check now, to see the gentle reminder (story 9). Sparkle
    /// refuses a background check until automatic checks are on, so this turns them on (persisted in
    /// the running build's defaults — use the `.verify` bundle id).
    func debugCheckInBackground() {
        automaticallyChecks = true
        updater?.checkForUpdatesInBackground()
    }

    /// Development aid: show the menu-bar reminder for `version` without a feed.
    func debugShowPendingUpdate(_ version: String) {
        pendingUpdateVersion = version
    }
    #endif

    /// Hold the relaunch until the work in progress is done, checking once a second (story 21).
    private func relaunchWhenIdle(_ relaunch: @escaping () -> Void) {
        postponedRelaunch?.cancel()
        postponedRelaunch = Task { @MainActor [hasWorkInProgress] in
            while hasWorkInProgress() {
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { return }
            }
            relaunch()
        }
    }
}

// MARK: - SPUUpdaterDelegate

// Sparkle calls its delegates on the main thread, which is what makes `MainActor.assumeIsolated`
// and the `nonisolated(unsafe)` hand-offs below sound.
extension SoftwareUpdater: SPUUpdaterDelegate {
    #if DEBUG
    /// Development aid: `-updateFeedURL <url>` points Sparkle at a local feed, for the manual
    /// end-to-end check in spec 0015.
    nonisolated func feedURLString(for updater: SPUUpdater) -> String? {
        UserDefaults.standard.string(forKey: "updateFeedURL")
    }
    #endif

    nonisolated func updater(
        _ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
        untilInvokingBlock installHandler: @escaping () -> Void
    ) -> Bool {
        nonisolated(unsafe) let relaunch = installHandler
        return MainActor.assumeIsolated {
            guard hasWorkInProgress() else { return false }
            relaunchWhenIdle(relaunch)
            return true
        }
    }

    nonisolated func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: (any Error)?) {
        MainActor.assumeIsolated { refresh() }
    }
}

// MARK: - SPUStandardUserDriverDelegate (gentle reminders, story 9)

extension SoftwareUpdater: SPUStandardUserDriverDelegate {
    /// A menu-bar app has no Dock icon to badge; Sparkle's gentle reminders let a scheduled check
    /// wait in the menu instead of opening a window over the user's work.
    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    /// Sparkle shows the window itself only when the update comes up in immediate focus (a manual
    /// check, or right after launch); a background find becomes the menu-bar dot instead.
    nonisolated func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
        immediateFocus
    }

    nonisolated func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState
    ) {
        let version = update.displayVersionString
        MainActor.assumeIsolated {
            if !handleShowingUpdate { pendingUpdateVersion = version }
        }
    }

    nonisolated func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        MainActor.assumeIsolated { pendingUpdateVersion = nil }
    }

    nonisolated func standardUserDriverWillFinishUpdateSession() {
        MainActor.assumeIsolated {
            pendingUpdateVersion = nil
            refresh()
        }
    }
}
