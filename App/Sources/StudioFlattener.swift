import AVFoundation
import LightshotKit

/// Renders a take's studio project into a finished movie for sharing without the editor
/// (spec 0007, S8 / LIG-57): the same renderer and exporter as a Studio export, with the look the
/// coordinator derived from the take's own settings.
@MainActor
final class StudioFlattener: StudioFlattening {
    private let store: StudioProjectStore

    init(store: StudioProjectStore) {
        self.store = store
    }

    func flatten(_ project: StudioProject, edits: StudioEdits, to output: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        let sources = try await StudioComposition.Sources.load(screen: project.screenURL, camera: project.cameraURL)
        // The session clock and the movie can differ by a frame or two: render the whole movie.
        var edits = edits
        edits.sourceDuration = sources.duration
        edits.clips = [StudioClip(start: 0, end: sources.duration)]
        edits = edits.normalized()
        let state = StudioRenderState(
            edits: edits, input: store.loadInput(project), sourceSize: sources.pixelSize,
            assetURL: { project.assetURL(named: $0) }, context: StudioCompositor.context
        )
        try await StudioExporter.export(sources, state: state, to: output, progress: progress)
    }
}
