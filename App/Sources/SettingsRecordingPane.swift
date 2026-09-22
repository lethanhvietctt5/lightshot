import SwiftUI
import LightshotKit

/// Settings → Screen Recording (spec 0006; LIG-44): the recording defaults, grouped like CleanShot's
/// pane. What happens after a recording lives in General's After Capture table; Play sounds lives
/// under General → Sounds.
struct RecordingPane: View {
    @Bindable var model: SettingsModel

    var body: some View {
        Form {
            video
            gif
            audio
            camera
            cursor
            keystrokes
            whileRecording
        }
    }

    // MARK: - Video (story 40)

    private var video: some View {
        Section("Video") {
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
        }
    }

    // MARK: - GIF (story 37)

    private var gif: some View {
        Section("GIF") {
            Picker("Frame rate", selection: $model.recordingDefaults.gif.fps) {
                // A persisted rate outside the list still shows, rather than a blank picker.
                ForEach(Array(Set([10, 15, 20, 30, model.recordingDefaults.gif.fps])).sorted(), id: \.self) { Text("\($0) fps").tag($0) }
            }
            .help("Fewer frames per second make a smaller GIF; 15 suits most screen recordings.")
            percentSlider("Quality", value: $model.recordingDefaults.gif.quality, range: 0...1)
                .help("Lower quality uses fewer colours, which shrinks the file but can band gradients.")
            Picker("Maximum width", selection: $model.recordingDefaults.gif.maxWidth) {
                ForEach([200, 256, 320, 480, 500, 640, 800, 960, 1200], id: \.self) { Text("\($0) px").tag(Optional($0)) }
                Text("Original").tag(Int?.none)
            }
            .help("Wider recordings are scaled down to this width, keeping their aspect.")
            Toggle("Optimise GIFs", isOn: $model.recordingDefaults.gif.optimize)
                .help("Only write what changed between frames. Much smaller for mostly-static recordings.")
        }
    }

    // MARK: - Audio (stories 20–25)

    private var audio: some View {
        Section("Audio") {
            Toggle("Record the microphone", isOn: $model.recordingDefaults.recordMicrophone)
                .help("Start every recording with narration on. The toolbar can still switch it off for one take.")
                .onChange(of: model.recordingDefaults.recordMicrophone) { _, on in
                    if on { model.featureTurnedOn(.microphone) }
                }
            Toggle("Record computer audio", isOn: $model.recordingDefaults.recordComputerAudio)
                .help("Start every recording with the sound other apps play.")
            percentSlider("Microphone volume", value: $model.recordingDefaults.microphoneVolume, range: 0...2)
                .help("Gain applied to your narration; 100% leaves it as the microphone delivers it.")
            percentSlider("Computer audio volume", value: $model.recordingDefaults.computerAudioVolume, range: 0...2)
                .help("Gain applied to the sound other apps play.")
            Picker("Audio tracks", selection: $model.recordingDefaults.separateAudioTracks) {
                Text("Single track").tag(false)
                Text("Separate tracks").tag(true)
            }
            .help("Separate tracks keep your voice and the computer's sound apart for editing.")
            Toggle("Record audio in mono", isOn: $model.recordingDefaults.monoAudio)
        }
    }

    // MARK: - Camera (stories 26–28)

    private var camera: some View {
        Section("Camera") {
            Toggle("Record the camera", isOn: $model.recordingDefaults.recordCamera)
                .help("Start every recording with the camera bubble on. Needs Camera access; asked for the first time you switch it on.")
                .onChange(of: model.recordingDefaults.recordCamera) { _, on in
                    if on { model.featureTurnedOn(.camera) }
                }
            Picker("Size", selection: $model.recordingDefaults.cameraBubble.size) {
                ForEach(CameraBubbleSize.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .help("How big the camera bubble is, relative to the recording area.")
            Picker("Shape", selection: $model.recordingDefaults.cameraBubble.shape) {
                ForEach(CameraBubbleShape.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            Toggle("Mirror the camera", isOn: $model.recordingDefaults.cameraBubble.mirror)
                .help("Flip the bubble horizontally so it reads like a mirror.")
            if model.recordingDefaults.cameraBubble.anchor != nil {
                LabeledContent("Position") {
                    Button("Reset") { model.recordingDefaults.cameraBubble.anchor = nil }
                        .help("Put the bubble back in the bottom-right corner.")
                }
            }
        }
    }

    // MARK: - Cursor & clicks (stories 19, 29)

    private var cursor: some View {
        Section("Cursor & Clicks") {
            Toggle("Show the cursor", isOn: $model.recordingDefaults.showCursor)
            Toggle("Highlight clicks", isOn: $model.recordingDefaults.highlightClicks)
                .help("Draw a halo under the pointer in recordings, with a ring on every click.")
            Group {
                Picker("Style", selection: $model.recordingDefaults.clickHighlight.style) {
                    ForEach(CursorHighlightStyle.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Picker("Size", selection: $model.recordingDefaults.clickHighlight.size) {
                    ForEach(CursorHighlightSize.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Picker("Colour", selection: $model.recordingDefaults.clickHighlight.color) {
                    ForEach(CursorHighlightColor.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Toggle("Animate clicks", isOn: $model.recordingDefaults.clickHighlight.animateClicks)
                ClickHighlightPreview(settings: model.recordingDefaults.clickHighlight)
                    .opacity(model.recordingDefaults.highlightClicks ? 1 : 0.5)
            }
            .disabled(!model.recordingDefaults.highlightClicks)
        }
    }

    // MARK: - Keystrokes (stories 30–31)

    private var keystrokes: some View {
        Section("Keystrokes") {
            Toggle("Show keystrokes", isOn: $model.recordingDefaults.showKeystrokes)
                .help("Show the keys you press as a pill in the recording. Needs Input Monitoring; asked for the first time you switch it on.")
                .onChange(of: model.recordingDefaults.showKeystrokes) { _, on in
                    if on { model.featureTurnedOn(.showKeystrokes) }
                }
            Group {
                Picker("Keys to show", selection: $model.recordingDefaults.keystrokeOverlay.mode) {
                    ForEach(KeystrokeDisplayMode.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Picker("Position", selection: $model.recordingDefaults.keystrokeOverlay.position) {
                    ForEach(KeystrokeOverlayPosition.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Picker("Size", selection: $model.recordingDefaults.keystrokeOverlay.size) {
                    ForEach(KeystrokeOverlaySize.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Picker("Appearance", selection: $model.recordingDefaults.keystrokeOverlay.appearance) {
                    ForEach(KeystrokeOverlayAppearance.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Toggle("Blur behind keystrokes", isOn: $model.recordingDefaults.keystrokeOverlay.blurBackground)
                    .help("Blur the recording behind the pill instead of a flat tint. Keys typed into password fields are never shown.")
            }
            .disabled(!model.recordingDefaults.showKeystrokes)
        }
    }

    // MARK: - While recording (stories 7, 10–16)

    private var whileRecording: some View {
        Section("While Recording") {
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

    private func percentSlider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        LabeledContent(title) {
            HStack {
                Slider(value: value, in: range, step: 0.1)
                Text("\(Int((value.wrappedValue * 100).rounded()))%")
                    .monospacedDigit()
                    .frame(width: 44, alignment: .trailing)
            }
        }
    }
}
