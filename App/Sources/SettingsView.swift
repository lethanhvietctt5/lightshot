import SwiftUI
import AppKit
import LightshotKit

/// The settings window (story 60), laid out like CleanShot X's (LIG-44): a sidebar of panes, each
/// with a coloured icon, and the selected pane's grouped rows, its name as the window title. A thin
/// projection of `SettingsModel` — every control binds straight to it, and it persists on change.
struct SettingsView: View {
    @Bindable var model: SettingsModel
    @State private var pane: SettingsPane = .general

    var body: some View {
        NavigationSplitView {
            SettingsSidebar(selection: $pane)
                // The column hint alone is not honoured in an AppKit-hosted split view; the
                // content's own minimum width holds the sidebar open.
                .frame(minWidth: 230, idealWidth: 240)
                .navigationSplitViewColumnWidth(240)
                .toolbar(removing: .sidebarToggle)
        } detail: {
            Group {
                switch pane {
                case .general: GeneralPane(model: model)
                case .shortcuts: ShortcutsPane(model: model)
                case .screenshots: ScreenshotsPane(model: model)
                case .recording: RecordingPane(model: model)
                case .advanced: AdvancedPane(model: model)
                case .about: AboutPane()
                }
            }
            .formStyle(.grouped)
            .navigationTitle(pane.title)
        }
        .frame(minWidth: 760, minHeight: 480)
    }
}

/// The panes, in sidebar order. Lightshot has no Quick Access, Wallpaper, Annotate or Cloud
/// settings (Cloud is out of scope: local-only), so those CleanShot panes are not here.
enum SettingsPane: String, CaseIterable, Identifiable {
    case general, shortcuts, screenshots, recording, advanced, about

    var id: Self { self }

    var title: String {
        switch self {
        case .general: return "General"
        case .shortcuts: return "Shortcuts"
        case .screenshots: return "Screenshots"
        case .recording: return "Screen Recording"
        case .advanced: return "Advanced"
        case .about: return "About"
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape.fill"
        case .shortcuts: return "command"
        case .screenshots: return "camera.fill"
        case .recording: return "video.fill"
        case .advanced: return "wrench.and.screwdriver.fill"
        case .about: return "info"
        }
    }

    var tint: Color {
        switch self {
        case .general: return .gray
        case .shortcuts: return Color(white: 0.35)
        case .screenshots: return .blue
        case .recording: return .red
        case .advanced: return .purple
        case .about: return Color(white: 0.45)
        }
    }
}

// MARK: - Sidebar

private struct SettingsSidebar: View {
    @Binding var selection: SettingsPane

    var body: some View {
        List(selection: Binding(get: { selection }, set: { if let pane = $0 { selection = pane } })) {
            AppHeader()
                .padding(.vertical, 6)
                .selectionDisabled()
            ForEach(SettingsPane.allCases.filter { $0 != .about }) { pane in
                PaneLabel(pane: pane).tag(pane)
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            // About sits apart at the bottom, as CleanShot pins it.
            Button { selection = .about } label: {
                PaneLabel(pane: .about)
                    .padding(.horizontal, 8)
                    .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(selection == .about ? Color.primary.opacity(0.1) : .clear)
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 10)
            .padding(.bottom, 12)
        }
    }
}

/// CleanShot shows the account here; Lightshot has none, so it shows the app and its version.
private struct AppHeader: View {
    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 1) {
                Text("Lightshot").font(.system(size: 13, weight: .semibold))
                Text("Version \(AppInfo.version) · Local only")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct PaneLabel: View {
    let pane: SettingsPane

    var body: some View {
        Label {
            Text(pane.title)
        } icon: {
            SettingsIcon(symbol: pane.symbol, tint: pane.tint)
        }
    }
}

/// A white glyph on a coloured rounded square, like System Settings' and CleanShot's.
private struct SettingsIcon: View {
    let symbol: String
    let tint: Color

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 22, height: 22)
            .background(RoundedRectangle(cornerRadius: 6).fill(tint.gradient))
    }
}

enum AppInfo {
    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }

    static var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
    }
}

// MARK: - General (stories 42, 59; spec 0006 story 33)

private struct GeneralPane: View {
    @Bindable var model: SettingsModel

    var body: some View {
        Form {
            Section("Startup") {
                Toggle("Launch Lightshot at login", isOn: $model.launchAtLogin)
            }
            Section {
                Toggle("Play sounds", isOn: $model.recordingDefaults.playSounds)
            } header: {
                Text("Sounds")
            } footer: {
                Text("Countdown ticks and the recording start, stop and pause cues.")
                    .foregroundStyle(.secondary)
            }
            Section {
                LabeledContent("Export location") {
                    HStack(spacing: 8) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: model.saveLocation.path))
                            .resizable()
                            .frame(width: 16, height: 16)
                        Text(FileManager.default.displayName(atPath: model.saveLocation.path))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .help(model.saveLocation.path)
                        Button("Choose…") { chooseSaveLocation() }
                    }
                }
            } header: {
                Text("Export")
            } footer: {
                Text("Set the default save location used when saving screenshots and recordings.")
                    .foregroundStyle(.secondary)
            }
            Section {
                AfterCaptureTable(model: model)
            } header: {
                VStack(alignment: .leading, spacing: 2) {
                    Text("After Capture")
                    Text("Decide what should happen after taking a screenshot or recording a video.")
                        .font(.caption)
                        .fontWeight(.regular)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func chooseSaveLocation() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = model.saveLocation
        WindowPresenter.activateApp()
        if panel.runModal() == .OK, let url = panel.url {
            model.saveLocation = url
        }
    }
}

/// CleanShot's action × kind grid. Lightshot takes one action per column: a screenshot opens in
/// the editor or shows the capture toolbar (`openInEditor`); a recording shows the overlay, saves
/// silently or opens the video editor (`afterRecording`). A dash marks an action that does not
/// apply to that kind.
private struct AfterCaptureTable: View {
    @Bindable var model: SettingsModel

    private struct Row {
        let title: String
        /// The `openInEditor` value this row selects for screenshots; nil when it does not apply.
        let screenshot: Bool?
        let recording: AfterRecordingAction?
    }

    private let rows = [
        Row(title: "Show Quick Access Overlay", screenshot: false, recording: .showOverlay),
        Row(title: "Save", screenshot: nil, recording: .saveSilently),
        Row(title: "Open Annotate tool", screenshot: true, recording: nil),
        Row(title: "Open Video Editor", screenshot: nil, recording: .openEditor),
    ]

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 10) {
            GridRow {
                Text("Action")
                Text("Screenshot").gridColumnAlignment(.center)
                Text("Recording").gridColumnAlignment(.center)
            }
            .foregroundStyle(.secondary)
            ForEach(rows, id: \.title) { row in
                Divider().gridCellUnsizedAxes(.horizontal)
                GridRow {
                    Text(row.title)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    cell(row.screenshot.map { value in
                        Binding(get: { model.openInEditor == value }, set: { if $0 { model.openInEditor = value } })
                    })
                    .frame(width: 90)
                    cell(row.recording.map { action in
                        Binding(
                            get: { model.recordingDefaults.afterRecording == action },
                            set: { if $0 { model.recordingDefaults.afterRecording = action } }
                        )
                    })
                    .frame(width: 90)
                }
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func cell(_ binding: Binding<Bool>?) -> some View {
        if let binding {
            Toggle("", isOn: binding)
                .toggleStyle(.checkbox)
                .labelsHidden()
        } else {
            Text("—").foregroundStyle(.tertiary)
        }
    }
}

// MARK: - Shortcuts (story 56)

private struct ShortcutsPane: View {
    @Bindable var model: SettingsModel

    var body: some View {
        Form {
            Section {
                ForEach(CaptureAction.allCases) { action in
                    // One line per action, the recorder at the trailing edge: a `LabeledContent`
                    // drops the AppKit recorder onto a second line.
                    HStack(spacing: 8) {
                        Text(action.title)
                        Spacer()
                        Group {
                            if isConflicted(action) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.orange)
                                    .help("This shortcut is also assigned to another action.")
                            } else if model.unregisterableActions.contains(action) {
                                Image(systemName: "exclamationmark.circle.fill")
                                    .foregroundStyle(.red)
                                    .help("The system or another app already uses this shortcut.")
                            }
                        }
                        HotkeyRecorderView(binding: model.hotkeys[action]) { newBinding in
                            model.setBinding(newBinding, for: action)
                        }
                        .frame(width: 140, height: 24)
                    }
                }
            } header: {
                Text("Global Shortcuts")
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    if !model.conflicts.isEmpty {
                        Label(conflictSummary, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                    HStack {
                        Text("Click a field and press a key combination. Press Delete to clear.")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Restore Defaults") { model.resetHotkeysToDefaults() }
                    }
                }
            }
        }
    }

    private func isConflicted(_ action: CaptureAction) -> Bool {
        model.conflicts.contains { $0.actions.contains(action) }
    }

    private var conflictSummary: String {
        let names = model.conflicts.flatMap { conflict in
            conflict.actions.map { "\($0.title) (\(conflict.binding.displayString))" }
        }
        return "Shortcut conflict: " + names.joined(separator: ", ")
    }
}

// MARK: - Screenshots (stories 12, 13, 42–43)

private struct ScreenshotsPane: View {
    @Bindable var model: SettingsModel

    var body: some View {
        Form {
            Section("Capture") {
                Toggle("Include the mouse cursor", isOn: $model.includeCursor)
                Picker("Self-timer", selection: $model.captureDelay) {
                    Text("Off").tag(TimeInterval(0))
                    Text("3 seconds").tag(TimeInterval(3))
                    Text("5 seconds").tag(TimeInterval(5))
                    Text("10 seconds").tag(TimeInterval(10))
                }
                .help("Wait before the shot fires, so you can open menus or hover states first.")
            }
            Section("Format") {
                Picker("File format", selection: $model.formatIsJPEG) {
                    Text("PNG").tag(false)
                    Text("JPEG").tag(true)
                }
                if model.formatIsJPEG {
                    LabeledContent("JPEG quality") {
                        HStack {
                            Slider(value: $model.jpegQuality, in: 0.1...1.0)
                            Text("\(Int((model.jpegQuality * 100).rounded()))%")
                                .monospacedDigit()
                                .frame(width: 40, alignment: .trailing)
                        }
                    }
                }
            }
            Section {
                TextField("File name", text: $model.filenamePattern)
            } header: {
                Text("File Name")
            } footer: {
                Text("Tokens: %Y %m %d %H %M %S — e.g. \"Screenshot %Y-%m-%d at %H.%M.%S\".")
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Advanced (story 54)

private struct AdvancedPane: View {
    @Bindable var model: SettingsModel

    var body: some View {
        Form {
            Section {
                Stepper(value: $model.historyRetention, in: 0...500) {
                    Text(model.historyRetention == 0
                         ? "Don't keep any captures"
                         : "Keep the last ^[\(model.historyRetention) capture](inflect: true)")
                }
            } header: {
                Text("History")
            } footer: {
                Text("Screenshots and recordings kept in Capture History, on this Mac only. Older ones are removed as new ones arrive.")
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - About

private struct AboutPane: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
            Text("Lightshot").font(.system(size: 22, weight: .semibold))
            Text("Version \(AppInfo.version) (\(AppInfo.build))")
                .foregroundStyle(.secondary)
            Text("Screenshots, annotations and screen recordings that never leave your Mac — no account, no cloud.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 360)
                .padding(.top, 6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
    }
}
