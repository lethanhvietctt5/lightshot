import SwiftUI
import AppKit
import LightshotKit

/// The settings window (story 60): rebindable global hotkeys with conflict surfacing, save defaults,
/// capture defaults, history retention, and launch-at-login. A thin projection of `SettingsModel` —
/// every control binds straight to it, and it persists on change.
struct SettingsView: View {
    @Bindable var model: SettingsModel

    var body: some View {
        Form {
            shortcutsSection
            savingSection
            captureSection
            recordingSection
            historySection
            generalSection
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Shortcuts (stories 56)

    private var shortcutsSection: some View {
        Section {
            ForEach(CaptureAction.allCases) { action in
                LabeledContent(action.title) {
                    HStack(spacing: 8) {
                        if isConflicted(action) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                                .help("This shortcut is also assigned to another action.")
                        } else if model.unregisterableActions.contains(action) {
                            Image(systemName: "exclamationmark.circle.fill")
                                .foregroundStyle(.red)
                                .help("The system or another app already uses this shortcut.")
                        }
                        HotkeyRecorderView(binding: model.hotkeys[action]) { newBinding in
                            model.setBinding(newBinding, for: action)
                        }
                        .frame(width: 140, height: 24)
                    }
                }
            }
        } header: {
            Text("Global Shortcuts")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                if !model.conflicts.isEmpty {
                    Label(conflictSummary, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.callout)
                }
                HStack {
                    Text("Click a field and press a key combination. Press Delete to clear.")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Restore Defaults") { model.resetHotkeysToDefaults() }
                        .controlSize(.small)
                }
            }
        }
    }

    private func isConflicted(_ action: CaptureAction) -> Bool {
        model.conflicts.contains { $0.actions.contains(action) }
    }

    private var conflictSummary: String {
        let names = model.conflicts
            .flatMap { conflict in
                conflict.actions.map { "\($0.title) (\(conflict.binding.displayString))" }
            }
        return "Shortcut conflict: " + names.joined(separator: ", ")
    }

    // MARK: - Saving (stories 42–43)

    private var savingSection: some View {
        Section("Saving") {
            Picker("Default format", selection: $model.formatIsJPEG) {
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
            LabeledContent("Save location") {
                HStack {
                    Text(model.saveLocation.path)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Choose…") { chooseSaveLocation() }
                        .controlSize(.small)
                }
            }
            TextField("Filename pattern", text: $model.filenamePattern)
                .help("Tokens: %Y %m %d %H %M %S — e.g. \"Screenshot %Y-%m-%d at %H.%M.%S\".")
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

    // MARK: - Capture (stories 12, 13)

    private var captureSection: some View {
        Section("Capture") {
            // `includeCursor` and `captureDelay` are live (read by SCCaptureService / AppCoordinator);
            // `openInEditor` is persisted but not yet wired — the editor-vs-toolbar default is a
            // spec-flagged decision (see SettingsStore).
            Toggle("Open captures in the editor", isOn: $model.openInEditor)
            Toggle("Include the mouse cursor", isOn: $model.includeCursor)
            Picker("Self-timer", selection: $model.captureDelay) {
                Text("Off").tag(TimeInterval(0))
                Text("3 seconds").tag(TimeInterval(3))
                Text("5 seconds").tag(TimeInterval(5))
                Text("10 seconds").tag(TimeInterval(10))
            }
            .help("Wait before the shot fires, so you can open menus or hover states first.")
        }
    }

    // MARK: - Recording (spec 0006)

    /// The Recording section grows with each recording ticket: R6 the video rows, R3 the
    /// remembered-area toggle, R4 the countdown and sounds, R5 the controls.
    private var recordingSection: some View {
        Section("Recording") {
            Picker("After recording", selection: $model.recordingDefaults.afterRecording) {
                ForEach(AfterRecordingAction.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .help("What happens when a recording stops: the overlay with copy / save / delete, a silent save to the default location, or the video editor.")
            Picker("Frame rate", selection: $model.recordingDefaults.video.fps) {
                ForEach(VideoSettings.fpsChoices, id: \.self) { Text("\($0) fps").tag($0) }
            }
            .help("Higher frame rates are smoother but make larger files; 30 suits most screen recordings.")
            Picker("Maximum resolution", selection: $model.recordingDefaults.video.maxResolution) {
                Text("Original").tag(MaxResolution.original)
                Text("1080p").tag(MaxResolution.p1080)
                Text("720p").tag(MaxResolution.p720)
            }
            .help("Cap the longest edge to keep files small.")
            Picker("Encoder", selection: $model.recordingDefaults.video.codec) {
                Text("H.264 (most compatible)").tag(VideoCodec.h264)
                Text("HEVC (smaller files)").tag(VideoCodec.hevc)
            }
            .help("HEVC halves the file size; H.264 plays everywhere.")
            Toggle("Scale Retina recordings to 1x", isOn: $model.recordingDefaults.video.scaleRetinaTo1x)
                .help("Record at half the pixel size on a Retina display.")
            Picker("GIF frame rate", selection: $model.recordingDefaults.gif.fps) {
                // A persisted rate outside the list still shows, rather than a blank picker.
                ForEach(Array(Set([10, 15, 20, 30, model.recordingDefaults.gif.fps])).sorted(), id: \.self) { Text("\($0) fps").tag($0) }
            }
            .help("Fewer frames per second make a smaller GIF; 15 suits most screen recordings.")
            HStack {
                Text("GIF quality")
                Slider(value: $model.recordingDefaults.gif.quality, in: 0...1, step: 0.1)
                Text("\(Int((model.recordingDefaults.gif.quality * 100).rounded()))%")
                    .monospacedDigit()
                    .frame(width: 44, alignment: .trailing)
            }
            .help("Lower quality uses fewer colours, which shrinks the file but can band gradients.")
            Picker("GIF maximum width", selection: $model.recordingDefaults.gif.maxWidth) {
                ForEach([200, 256, 320, 480, 500, 640, 800, 960, 1200], id: \.self) { Text("\($0) px").tag(Optional($0)) }
                Text("Original").tag(Int?.none)
            }
            .help("Wider recordings are scaled down to this width, keeping their aspect.")
            Toggle("Optimise GIFs", isOn: $model.recordingDefaults.gif.optimize)
                .help("Only write what changed between frames. Much smaller for mostly-static recordings.")
            Toggle("Show the cursor", isOn: $model.recordingDefaults.showCursor)
            Toggle("Highlight clicks", isOn: $model.recordingDefaults.highlightClicks)
                .help("Draw a halo under the pointer in recordings, with a ring on every click.")
            Picker("Highlight style", selection: $model.recordingDefaults.clickHighlight.style) {
                ForEach(CursorHighlightStyle.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .disabled(!model.recordingDefaults.highlightClicks)
            Picker("Highlight size", selection: $model.recordingDefaults.clickHighlight.size) {
                ForEach(CursorHighlightSize.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .disabled(!model.recordingDefaults.highlightClicks)
            Picker("Highlight colour", selection: $model.recordingDefaults.clickHighlight.color) {
                ForEach(CursorHighlightColor.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .disabled(!model.recordingDefaults.highlightClicks)
            Toggle("Animate clicks", isOn: $model.recordingDefaults.clickHighlight.animateClicks)
                .disabled(!model.recordingDefaults.highlightClicks)
            ClickHighlightPreview(settings: model.recordingDefaults.clickHighlight)
                .disabled(!model.recordingDefaults.highlightClicks)
                .opacity(model.recordingDefaults.highlightClicks ? 1 : 0.5)
            Toggle("Show keystrokes", isOn: $model.recordingDefaults.showKeystrokes)
                .help("Show the keys you press as a pill in the recording. Needs Input Monitoring; asked for the first time you switch it on.")
                .onChange(of: model.recordingDefaults.showKeystrokes) { _, on in
                    if on { model.featureTurnedOn(.showKeystrokes) }
                }
            Picker("Keys to show", selection: $model.recordingDefaults.keystrokeOverlay.mode) {
                ForEach(KeystrokeDisplayMode.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .disabled(!model.recordingDefaults.showKeystrokes)
            Picker("Keystroke position", selection: $model.recordingDefaults.keystrokeOverlay.position) {
                ForEach(KeystrokeOverlayPosition.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .disabled(!model.recordingDefaults.showKeystrokes)
            Picker("Keystroke size", selection: $model.recordingDefaults.keystrokeOverlay.size) {
                ForEach(KeystrokeOverlaySize.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .disabled(!model.recordingDefaults.showKeystrokes)
            Picker("Keystroke appearance", selection: $model.recordingDefaults.keystrokeOverlay.appearance) {
                ForEach(KeystrokeOverlayAppearance.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .disabled(!model.recordingDefaults.showKeystrokes)
            Toggle("Blur behind keystrokes", isOn: $model.recordingDefaults.keystrokeOverlay.blurBackground)
                .disabled(!model.recordingDefaults.showKeystrokes)
                .help("Blur the recording behind the pill instead of a flat tint. Keys typed into password fields are never shown.")
            Picker("Camera size", selection: $model.recordingDefaults.cameraBubble.size) {
                ForEach(CameraBubbleSize.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .help("How big the camera bubble is, relative to the recording area. Switch the camera on in the recorder toolbar.")
            Picker("Camera shape", selection: $model.recordingDefaults.cameraBubble.shape) {
                ForEach(CameraBubbleShape.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            Toggle("Mirror the camera", isOn: $model.recordingDefaults.cameraBubble.mirror)
                .help("Flip the bubble horizontally so it reads like a mirror.")
            if model.recordingDefaults.cameraBubble.anchor != nil {
                Button("Reset Camera Position") { model.recordingDefaults.cameraBubble.anchor = nil }
                    .help("Put the bubble back in the bottom-right corner.")
            }
            HStack {
                Text("Microphone volume")
                Slider(value: $model.recordingDefaults.microphoneVolume, in: 0...2, step: 0.1)
                Text("\(Int((model.recordingDefaults.microphoneVolume * 100).rounded()))%")
                    .monospacedDigit()
                    .frame(width: 44, alignment: .trailing)
            }
            .help("Gain applied to your narration; 100% leaves it as the microphone delivers it.")
            HStack {
                Text("Computer audio volume")
                Slider(value: $model.recordingDefaults.computerAudioVolume, in: 0...2, step: 0.1)
                Text("\(Int((model.recordingDefaults.computerAudioVolume * 100).rounded()))%")
                    .monospacedDigit()
                    .frame(width: 44, alignment: .trailing)
            }
            .help("Gain applied to the sound other apps play.")
            Picker("Audio merging", selection: $model.recordingDefaults.separateAudioTracks) {
                Text("Record on a single track").tag(false)
                Text("Record on separate tracks").tag(true)
            }
            .help("Separate tracks keep your voice and the computer's sound apart for editing.")
            Toggle("Record audio in mono", isOn: $model.recordingDefaults.monoAudio)
            Picker("Countdown", selection: Binding(
                get: {
                    guard model.recordingDefaults.countdownEnabled else { return 0 }
                    // Snap a hand-edited value to the offered choices so the picker always matches a tag.
                    return [3, 5, 10].contains(model.recordingDefaults.countdownSeconds) ? model.recordingDefaults.countdownSeconds : 3
                },
                set: { seconds in
                    model.recordingDefaults.countdownEnabled = seconds > 0
                    if seconds > 0 { model.recordingDefaults.countdownSeconds = seconds }
                }
            )) {
                Text("Off").tag(0)
                Text("3 seconds").tag(3)
                Text("5 seconds").tag(5)
                Text("10 seconds").tag(10)
            }
            .help("Count down before a recording starts, so you can get your hands in position.")
            Toggle("Play sounds", isOn: $model.recordingDefaults.playSounds)
                .help("Countdown ticks and the start, stop and pause cues.")
            Toggle("Show recording time in the menu bar", isOn: $model.recordingDefaults.showRecordingTimeInMenuBar)
            Toggle("Show controls while recording", isOn: $model.recordingDefaults.showRecordingControls)
            Picker("Controls position", selection: $model.recordingDefaults.controlsPosition) {
                Text("Top").tag(RecordingControlsPosition.top)
                Text("Bottom").tag(RecordingControlsPosition.bottom)
            }
            .disabled(!model.recordingDefaults.showRecordingControls)
            Toggle("Dim screen while recording", isOn: $model.recordingDefaults.dimScreenWhileRecording)
                .help("Darken everything outside the recording area so you can see what's in frame.")
            Toggle("Confirm before discarding a recording", isOn: $model.recordingDefaults.confirmBeforeDiscard)
            Toggle("Remember last recording area", isOn: $model.rememberLastRecordingArea)
                .help("Pre-fill the recording overlay with the area, window or display you recorded last time.")
        }
    }

    // MARK: - History (story 54)

    private var historySection: some View {
        // Retention persists here; enforcement and a "Clear history" button arrive with the
        // HistoryStore seam (stories 50–54), which isn't in the app yet. `0` already expresses the
        // "keep nothing" policy, so no dead Clear button is shipped in the meantime.
        Section("History") {
            Stepper(value: $model.historyRetention, in: 0...500) {
                Text(model.historyRetention == 0
                     ? "Don't keep any captures"
                     : "Keep the last ^[\(model.historyRetention) capture](inflect: true)")
            }
        }
    }

    // MARK: - General (story 59)

    private var generalSection: some View {
        Section("General") {
            Toggle("Launch Lightshot at login", isOn: $model.launchAtLogin)
        }
    }
}
