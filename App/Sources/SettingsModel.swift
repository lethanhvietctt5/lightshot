import Foundation
import Observation
import LightshotKit

/// The observable bridge between the `SettingsStore` and the settings window (stories 12, 42–43, 54,
/// 56, 59, 60).
///
/// Each edit writes straight through to the store (so persistence is immediate, no "Apply" button)
/// and, for hotkeys, re-registers them via the injected `applyHotkeys` — whose return value is the
/// set the OS refused, surfaced to the user rather than silently dropped. Launch-at-login is written
/// through `SMAppService` and then re-read, so the toggle snaps back if the system rejected it.
@MainActor
@Observable
final class SettingsModel {
    private let store: SettingsStore
    private let applyHotkeys: (HotkeyBindings) -> [CaptureAction]
    private let applyRetention: (Int) -> Void
    private var suppressLaunchWrite = false

    var hotkeys: HotkeyBindings {
        didSet {
            store.hotkeys = hotkeys
            unregisterableActions = applyHotkeys(hotkeys)
        }
    }

    var formatIsJPEG: Bool { didSet { persistFormat() } }
    var jpegQuality: Double { didSet { persistFormat() } }

    var saveLocation: URL { didSet { store.saveLocation = saveLocation } }
    var filenamePattern: String { didSet { store.filenamePattern = filenamePattern } }
    var openInEditor: Bool { didSet { store.openInEditor = openInEditor } }
    var includeCursor: Bool { didSet { store.includeCursor = includeCursor } }
    var captureDelay: TimeInterval { didSet { store.captureDelay = captureDelay } }
    var rememberLastRecordingArea: Bool { didSet { store.rememberLastRecordingArea = rememberLastRecordingArea } }
    /// The recording baseline (spec 0006), edited as a unit; each row binds one field of it.
    var recordingDefaults: RecordingDefaults { didSet { store.recordingDefaults = recordingDefaults } }
    var historyRetention: Int {
        didSet {
            let clamped = max(0, historyRetention)
            store.historyRetention = clamped
            applyRetention(clamped)
        }
    }

    var launchAtLogin: Bool {
        didSet {
            guard !suppressLaunchWrite else { return }
            store.launchAtLogin = launchAtLogin
            // Re-read: if the OS refused the (un)registration the toggle reflects reality, not intent.
            let actual = store.launchAtLogin
            if actual != launchAtLogin {
                suppressLaunchWrite = true
                launchAtLogin = actual
                suppressLaunchWrite = false
            }
        }
    }

    /// Actions the OS could not bind (the chord is already claimed) — surfaced next to the recorder.
    private(set) var unregisterableActions: [CaptureAction] = []

    /// In-app chord clashes (two actions on the same shortcut), a pure function of the bindings.
    var conflicts: [HotkeyConflict] { hotkeys.conflicts }

    private let permissionGate: (RecordingToggle) async -> Bool

    init(
        store: SettingsStore,
        applyHotkeys: @escaping (HotkeyBindings) -> [CaptureAction],
        applyRetention: @escaping (Int) -> Void,
        permissionGate: @escaping (RecordingToggle) async -> Bool = { _ in true }
    ) {
        self.store = store
        self.applyHotkeys = applyHotkeys
        self.applyRetention = applyRetention
        self.permissionGate = permissionGate

        // Seed from the store. Assigning in init does not fire `didSet`, so this reads without
        // writing back or re-registering.
        self.hotkeys = store.hotkeys
        if case let .jpeg(quality) = store.defaultFormat {
            self.formatIsJPEG = true
            self.jpegQuality = quality
        } else {
            self.formatIsJPEG = false
            self.jpegQuality = 0.9
        }
        self.saveLocation = store.saveLocation
        self.filenamePattern = store.filenamePattern
        self.openInEditor = store.openInEditor
        self.includeCursor = store.includeCursor
        self.captureDelay = store.captureDelay
        self.rememberLastRecordingArea = store.rememberLastRecordingArea
        self.recordingDefaults = store.recordingDefaults
        self.historyRetention = store.historyRetention
        self.launchAtLogin = store.launchAtLogin
    }

    /// A recording feature switched on in Settings asks for its grant right then, like the toolbar
    /// toggle does (story 41); a decline (which shows the recovery alert) switches it back off.
    func featureTurnedOn(_ toggle: RecordingToggle) {
        guard toggle.requiredPermission != nil else { return }
        Task { @MainActor in
            if await !permissionGate(toggle) { recordingDefaults[toggle] = false }
        }
    }

    /// Assign (or clear) a chord for one action, then persist + re-register through `hotkeys`' setter.
    func setBinding(_ binding: HotkeyBinding?, for action: CaptureAction) {
        hotkeys[action] = binding
    }

    /// Restore the shipped default chords.
    func resetHotkeysToDefaults() {
        hotkeys = .defaults
    }

    private func persistFormat() {
        store.defaultFormat = formatIsJPEG ? .jpeg(clamping: jpegQuality) : .png
    }
}
