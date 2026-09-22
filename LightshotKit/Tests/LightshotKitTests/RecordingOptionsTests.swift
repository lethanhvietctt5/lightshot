import Testing
import Foundation
@testable import LightshotKit

// `RecordingOptions.resolve` (spec 0006, story 9): Settings defaults seed every value; a toolbar
// override wins wherever one is given, and never leaks back into the defaults.

private let region = CaptureRegion.rect(Rect(x: 0, y: 0, width: 100, height: 50))

private let allOnDefaults = RecordingDefaults(
    video: VideoSettings(codec: .hevc, fps: 60, maxResolution: .p1080, scaleRetinaTo1x: true),
    gif: GIFSettings(fps: 10, quality: 0.5, maxWidth: 480, optimize: false),
    recordMicrophone: true, microphoneDeviceID: "mic-1",
    recordComputerAudio: true,
    recordCamera: true, cameraDeviceID: "cam-1",
    highlightClicks: true, showKeystrokes: true, showCursor: true,
    countdownEnabled: true, countdownSeconds: 5
)

@Test func withNoOverridesEveryValueComesFromDefaults() {
    let o = RecordingOptions.resolve(region: region, output: .video, defaults: allOnDefaults)
    #expect(o.region == region)
    #expect(o.output == .video(allOnDefaults.video))
    #expect(o.microphone == .device(id: "mic-1"))
    #expect(o.computerAudio)
    #expect(o.camera == .device(id: "cam-1"))
    #expect(o.highlightClicks)
    #expect(o.showKeystrokes)
    #expect(o.showCursor)
    #expect(o.countdownSeconds == 5)
    #expect(o.hasCountdown)
}

@Test func startGIFPicksTheGIFSettings() {
    let o = RecordingOptions.resolve(region: region, output: .gif, defaults: allOnDefaults)
    #expect(o.output == .gif(allOnDefaults.gif))
    #expect(o.output.kind == .gif)
}

@Test func everyOverrideBeatsItsDefaultInBothDirections() {
    let allOff = RecordingOverrides(
        microphone: false, computerAudio: false, camera: false, highlightClicks: false, showKeystrokes: false
    )
    let off = RecordingOptions.resolve(region: region, output: .video, defaults: allOnDefaults, overrides: allOff)
    #expect(off.microphone == .off)
    #expect(!off.computerAudio)
    #expect(off.camera == .off)
    #expect(!off.highlightClicks)
    #expect(!off.showKeystrokes)
    // Settings-only values are untouched by overrides (stories 10, 19).
    #expect(off.showCursor)
    #expect(off.countdownSeconds == 5)

    let allOn = RecordingOverrides(
        microphone: true, computerAudio: true, camera: true, highlightClicks: true, showKeystrokes: true
    )
    let on = RecordingOptions.resolve(region: region, output: .video, defaults: .standard, overrides: allOn)
    #expect(on.microphone == .device(id: nil))
    #expect(on.computerAudio)
    #expect(on.camera == .device(id: nil))
    #expect(on.highlightClicks)
    #expect(on.showKeystrokes)
}

@Test func turningASourceOnByOverrideUsesTheDefaultDevice() {
    // Defaults have mic/camera off but a remembered device; the toolbar toggle turns them on.
    let defaults = RecordingDefaults(microphoneDeviceID: "mic-2", cameraDeviceID: nil)
    let o = RecordingOptions.resolve(
        region: region, output: .video, defaults: defaults,
        overrides: RecordingOverrides(microphone: true, camera: true)
    )
    #expect(o.microphone == .device(id: "mic-2"))
    #expect(o.camera == .device(id: nil))     // nil id = the system default camera
    #expect(o.camera.isOn)
    #expect(!InputDeviceSelection.off.isOn)
}

@Test func overridesAreValuesAndNeverMutateTheDefaults() {
    let defaults = RecordingDefaults.standard
    _ = RecordingOptions.resolve(
        region: region, output: .video, defaults: defaults,
        overrides: RecordingOverrides(microphone: true, computerAudio: true)
    )
    #expect(defaults == .standard)
    #expect(RecordingOverrides.none == RecordingOverrides())
    #expect(RecordingDefaults.standard.countdownEnabled)    // 3-2-1 with sounds by default
    #expect(RecordingDefaults.standard.playSounds)
}

@Test func aStoredBlobFromBeforePlaySoundsStillDecodes() throws {
    // Encode the current shape, strip the newer key, decode: the field takes its default.
    var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(RecordingDefaults(playSounds: false))) as! [String: Any]
    json.removeValue(forKey: "playSounds")
    let decoded = try JSONDecoder().decode(RecordingDefaults.self, from: JSONSerialization.data(withJSONObject: json))
    #expect(decoded.playSounds)
    #expect(decoded == RecordingDefaults())

    // The R5 controls fields too.
    for key in ["showRecordingControls", "controlsPosition", "dimScreenWhileRecording", "confirmBeforeDiscard", "showRecordingTimeInMenuBar", "microphoneVolume", "monoAudio", "computerAudioVolume", "separateAudioTracks", "clickHighlight", "keystrokeOverlay", "cameraBubble"] {
        json.removeValue(forKey: key)
    }
    let older = try JSONDecoder().decode(RecordingDefaults.self, from: JSONSerialization.data(withJSONObject: json))
    #expect(older.showRecordingControls && older.controlsPosition == .bottom && !older.dimScreenWhileRecording && older.confirmBeforeDiscard)
    #expect(older.showRecordingTimeInMenuBar)
    #expect(older.microphoneVolume == 1 && !older.monoAudio)
    #expect(older.computerAudioVolume == 1 && !older.separateAudioTracks)
    #expect(older.clickHighlight == .standard)
    #expect(older.keystrokeOverlay == .standard)
    #expect(older.cameraBubble == .standard)
}

@Test func cameraBubbleSettingsReachTheOptions() {
    let look = CameraBubbleSettings(size: .huge, shape: .square, mirror: false, anchor: Point(x: 0.1, y: 0.2))
    let o = RecordingOptions.resolve(region: region, output: .video, defaults: RecordingDefaults(cameraDeviceID: "cam", cameraBubble: look),
                                     overrides: RecordingOverrides(camera: true))
    #expect(o.camera == .device(id: "cam") && o.cameraBubble == look)
}

@Test func toggleSubscriptsReadDefaultsAndWriteOverrides() {
    let defaults = RecordingDefaults(recordMicrophone: true, recordCamera: true)
    #expect(defaults[.microphone] && defaults[.camera] && !defaults[.computerAudio])
    var overrides = RecordingOverrides.none
    overrides[.microphone] = false
    overrides[.showKeystrokes] = true
    #expect(overrides == RecordingOverrides(microphone: false, showKeystrokes: true))
    #expect(overrides[.camera] == nil)
    let choice = RecordingChoice(region: .display(id: 1), output: .gif, overrides: overrides)
    #expect(RecordingOptions.resolve(region: choice.region, output: choice.output, defaults: defaults, overrides: choice.overrides).microphone == .off)
}

@Test func countdownOffInDefaultsMeansNoCountdownEvenWithSeconds() {
    let defaults = RecordingDefaults(countdownEnabled: false, countdownSeconds: 3)
    let o = RecordingOptions.resolve(region: region, output: .video, defaults: defaults)
    #expect(o.countdownSeconds == 0)
    #expect(!o.hasCountdown)
}

@Test func clickHighlightSettingsReachTheOptions() {
    let look = ClickHighlightSettings(style: .outline, size: .large, color: .red, animateClicks: false)
    let o = RecordingOptions.resolve(region: region, output: .video, defaults: RecordingDefaults(clickHighlight: look),
                                     overrides: RecordingOverrides(highlightClicks: true))
    #expect(o.highlightClicks && o.clickHighlight == look)
}

@Test func keystrokeOverlaySettingsReachTheOptions() {
    let look = KeystrokeOverlaySettings(mode: .commandOnly, position: .topRight, size: .large, appearance: .dark, blurBackground: false)
    let o = RecordingOptions.resolve(region: region, output: .video, defaults: RecordingDefaults(keystrokeOverlay: look),
                                     overrides: RecordingOverrides(showKeystrokes: true))
    #expect(o.showKeystrokes && o.keystrokeOverlay == look)
    #expect(!RecordingOptions.resolve(region: region, output: .video, defaults: RecordingDefaults(keystrokeOverlay: look)).showKeystrokes)
}

@Test func computerAudioSettingsReachTheOptions() {
    let defaults = RecordingDefaults(recordComputerAudio: true, computerAudioVolume: 0.5, separateAudioTracks: true)
    let o = RecordingOptions.resolve(region: region, output: .video, defaults: defaults)
    #expect(o.computerAudio && o.computerAudioVolume == 0.5 && o.separateAudioTracks)
    #expect(RecordingDefaults(computerAudioVolume: 9).computerAudioVolume == 2)
}

@Test func microphoneVolumeIsClampedToTwiceUnity() {
    #expect(RecordingDefaults(microphoneVolume: 5).microphoneVolume == 2)
    #expect(RecordingDefaults(microphoneVolume: -1).microphoneVolume == 0)
    #expect(RecordingOptions(region: region, output: .video(.standard), microphoneVolume: 3).microphoneVolume == 2)
}

@Test func gifQualityIsClampedAndNegativeCountdownsAreZero() {
    #expect(GIFSettings(fps: 15, quality: 1.7, maxWidth: nil, optimize: true).quality == 1)
    #expect(GIFSettings(fps: 15, quality: -1, maxWidth: nil, optimize: true).quality == 0)
    #expect(RecordingOptions(region: region, output: .gif(.standard), countdownSeconds: -4).countdownSeconds == 0)
    #expect(MaxResolution.p1080.maxLongestEdge == 1920)
    #expect(MaxResolution.original.maxLongestEdge == nil)
}
