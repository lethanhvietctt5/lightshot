import Testing
import Foundation
@testable import LightshotKit

// Every recording is a studio take (spec 0007, S8 / LIG-57): a take shared without the editor is
// rendered with the recording's own look, and stays linked to its editable project.

private func options(
    output: RecordingOutput = .video(VideoSettings(codec: .hevc, fps: 30, maxResolution: .original, scaleRetinaTo1x: false)),
    showCursor: Bool = true, highlightClicks: Bool = false, showKeystrokes: Bool = false, camera: Bool = false
) -> RecordingOptions {
    RecordingOptions(
        region: .display(id: 1), output: output,
        camera: camera ? .device(id: nil) : .off,
        cameraBubble: CameraBubbleSettings(size: .large, shape: .rounded, mirror: false),
        highlightClicks: highlightClicks,
        clickHighlight: ClickHighlightSettings(style: .ring, size: .medium, color: .red, animateClicks: true),
        showKeystrokes: showKeystrokes, keystrokeOverlay: KeystrokeOverlaySettings(position: .topRight),
        showCursor: showCursor
    )
}

@Test func theRenderedLookIsTheRecordingAsItWasSetUpWithNoStudioDecoration() {
    let edits = StudioEdits.flattenLook(options: options(), sourceDuration: 12)
    #expect(edits.sourceDuration == 12 && edits.clips.count == 1 && edits.zooms.isEmpty)
    #expect(edits.background == .none && edits.canvas.padding == 0 && edits.canvas.cornerRadius == 0)
    #expect(edits.cursor.visible && edits.cursor.size == 1 && edits.cursor.smoothing == 0 && edits.cursor.motionBlur == 0)
    #expect(edits.cursor.clickEffect == .none)
    #expect(!edits.keystrokes.visible && edits.captions.lines.isEmpty && edits.annotations.isEmpty)
    #expect(edits.output.resolution == .source && edits.output.fps == 30 && edits.output.codec == .hevc && edits.output.format == .mp4)
}

@Test func theToolbarsTogglesDecideCursorClicksKeysAndCamera() {
    let edits = StudioEdits.flattenLook(options: options(showCursor: false, highlightClicks: true, showKeystrokes: true, camera: true), sourceDuration: 5)
    #expect(!edits.cursor.visible)
    #expect(edits.cursor.clickEffect == .ripple)
    #expect(edits.cursor.clickColor.red > 0.9 && edits.cursor.clickColor.green < 0.5)
    #expect(edits.keystrokes.visible && edits.keystrokes.overlay.position == .topRight)
    #expect(edits.camera.visible && edits.camera.bubble.size == .large && edits.camera.bubble.shape == .rounded)
}

@Test func aGIFTakeIsRenderedAsAMovieFirst() {
    let edits = StudioEdits.flattenLook(options: options(output: .gif(.standard)), sourceDuration: 3)
    #expect(edits.output.format == .mp4)
}

@Test func everyTakeRecordsItsIngredients() {
    let video = RecordingOptions.resolve(region: .display(id: 1), output: .video, defaults: RecordingDefaults())
    let gif = RecordingOptions.resolve(region: .display(id: 1), output: .gif, defaults: RecordingDefaults())
    #expect(video.studio && gif.studio)
}
