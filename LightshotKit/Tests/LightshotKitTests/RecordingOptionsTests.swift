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

@Test func everyOverrideBeatsItsDefault() {
    let overrides = RecordingOverrides(
        microphone: false, computerAudio: false, camera: false,
        highlightClicks: false, showKeystrokes: false, showCursor: false, countdown: false
    )
    let o = RecordingOptions.resolve(region: region, output: .video, defaults: allOnDefaults, overrides: overrides)
    #expect(o.microphone == .off)
    #expect(!o.computerAudio)
    #expect(o.camera == .off)
    #expect(!o.highlightClicks)
    #expect(!o.showKeystrokes)
    #expect(!o.showCursor)
    #expect(o.countdownSeconds == 0)
    #expect(!o.hasCountdown)
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
        overrides: RecordingOverrides(microphone: true, countdown: false)
    )
    #expect(defaults == .standard)
    #expect(RecordingOverrides.none == RecordingOverrides())
}

@Test func countdownOffInDefaultsMeansNoCountdownEvenWithSeconds() {
    let defaults = RecordingDefaults(countdownEnabled: false, countdownSeconds: 3)
    let o = RecordingOptions.resolve(region: region, output: .video, defaults: defaults)
    #expect(o.countdownSeconds == 0)
    // …and the toolbar can switch it back on for this recording.
    let on = RecordingOptions.resolve(
        region: region, output: .video, defaults: defaults, overrides: RecordingOverrides(countdown: true)
    )
    #expect(on.countdownSeconds == 3)
}

@Test func gifQualityIsClampedAndNegativeCountdownsAreZero() {
    #expect(GIFSettings(fps: 15, quality: 1.7, maxWidth: nil, optimize: true).quality == 1)
    #expect(GIFSettings(fps: 15, quality: -1, maxWidth: nil, optimize: true).quality == 0)
    #expect(RecordingOptions(region: region, output: .gif(.standard), countdownSeconds: -4).countdownSeconds == 0)
    #expect(MaxResolution.p1080.maxLongestEdge == 1920)
    #expect(MaxResolution.original.maxLongestEdge == nil)
}
