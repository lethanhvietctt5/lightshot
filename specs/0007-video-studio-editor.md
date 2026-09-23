# Spec 0007 — Video Studio editor

**Status:** accepted — decisions taken at the end; sub-issues implemented in order
**Linear:** epic [LIG-49](https://linear.app/light-shot/issue/LIG-49) with sub-issues LIG-50 … LIG-53 (round 1), LIG-54 … LIG-56 (round 2) and [LIG-66](https://linear.app/light-shot/issue/LIG-66) (round 3)
**Platform:** Native macOS (Swift / SwiftUI + AppKit), macOS 14+ (ScreenCaptureKit, AVFoundation, Core Image)
**Scope:** Local-only. Turns the recording video editor (spec 0006 R14, LIG-43) into a **studio editor** on par with CleanShot X 5.0's Studio Mode and OpenScreen: smart zooms that follow the cursor, a cursor re-drawn from recorded data (size, smoothing, click effects, motion blur, hide when idle), backgrounds with padding / rounded corners / shadow, social aspect ratios, cuts and per-segment speed, the camera and keystrokes adjustable after the take, undo/redo, and a local export. No cloud, no accounts, no network, no AI agent.

Parity references: CleanShot X 5.0 changelog (Studio Mode: smart zooms following the cursor, cursor smoothing, motion blur, backgrounds, post-hoc cursor size / keystrokes / camera, landscape / square / vertical export, hardware encoding) and OpenScreen (getopenscreen.com, MIT: pointer recorded as data, auto + manual zoom pills on the timeline, cursor size / smoothing / motion blur / click bounce, image / colour / gradient backgrounds with blur, padding, rounded corners, shadow, trims and speed ramps as timeline pills, MP4 / GIF, H.264 / H.265, 24 / 30 / 60 fps).

---

## Problem Statement

A raw screen recording is hard to watch: the interesting part is small, the cursor jitters, the frame edge meets the viewer's page with no margin, and a vertical post needs a different shape. Spec 0006 burns the cursor, click halos, keystrokes and camera into the only video track at record time, so nothing about them can be changed afterwards, and the editor can only trim, resize, re-encode and adjust audio. To make a polished demo I still reach for CleanShot's Studio Mode or Screen Studio.

## Solution

**Record in Studio Mode** (the recorder toolbar's existing Studio row) captures the ingredients separately instead of a finished picture: the screen with **no cursor and nothing composited**, the pointer and clicks and keys as **timestamped data**, and the camera as **its own movie**. They land in a **studio project** folder. The **Studio editor** renders the final video from those ingredients through one Core Image compositor that drives both the live preview and the export, so every look decision — zoom, cursor, background, shape, camera, keystrokes, cuts, speed — stays editable until export. A plain MP4 (a non-studio take, or any take from history) opens in the same editor with everything except the cursor-data features, which say why they are unavailable.

## Vocabulary

- **Studio take** — a recording made in Studio Mode: clean screen + input data + optional camera movie.
- **Studio project** — the folder holding a studio take's files and its edits (`project.json`); what the Studio editor opens and saves.
- **Studio document** — the pure, undoable value of all edits (`StudioDocument` in the kit).
- **Clip** — a kept range of the source with a playback speed; the timeline is the ordered list of clips. Cutting removes a range; splitting makes two clips.
- **Zoom region** — a time range with a zoom scale and a focus (a fixed point, or *follow cursor*).
- **Canvas** — the output frame: background + padded, rounded, shadowed screen, in the chosen aspect ratio.
- **Output time / source time** — time in the edited video vs time in the recorded screen movie.

## User Stories

### Recording for the studio

1. As a user, I want **Record in Studio Mode** to record a clean screen plus my pointer, clicks and keys as data, so that I can restyle them later.
2. As a user, I want my **camera recorded as its own track** in Studio Mode, so that I can move, resize, reshape or hide it after the take.
3. As a user, I want a studio take to **open straight in the Studio editor**, and my edits to be **saved automatically** with the project, so that I can close and come back.
4. As a user, I want to **reopen recent studio projects** from the menu bar, so that a project isn't lost once its window is closed.

### Timeline

5. As a user, I want a **timeline with a clip track and a zoom track**, a ruler and a playhead, so that I can see every edit in time.
6. As a user, I want to **split at the playhead** (S / ⌘B) and **delete a selected clip** (⌫), so that I can cut mistakes out of the middle, not just the ends.
7. As a user, I want to **drag a clip's edges** to trim it, so that cuts are precise.
8. As a user, I want to set a **speed per clip** (0.25× – 4×), so that boring stretches play fast.
9. As a user, I want **undo / redo** (⌘Z / ⇧⌘Z) for every edit, so that experimenting is safe.

### Zoom

10. As a user, I want to **add a zoom at the playhead** and **drag / resize** its pill on the zoom track, so that I choose when the view pushes in.
11. As a user, I want each zoom's **scale** and **focus** — a point I click on the preview, or **follow cursor** — so that the zoom shows what matters.
12. As a user, I want **auto zoom** to place zooms where I clicked, so that a first pass takes one click.
13. As a user, I want zooms to **ease in and out smoothly** (adjustable transition), so that the camera moves feel produced, not jumpy.

### Cursor (studio takes)

14. As a user, I want to change the **cursor size**, so that it is visible in a small player.
15. As a user, I want **cursor smoothing**, so that shaky movement becomes a clean glide.
16. As a user, I want **click effects** (ripple / pulse / none, colour — yellow by default, the recorder's click-highlight colour; LIG-67), so that clicks read on video.
17. As a user, I want the cursor to **hide when idle**, so that it doesn't sit on top of content.
18. As a user, I want **motion blur** on cursor and zoom movement, so that the video feels cinematic.
19. As a user, I want to **hide the cursor** entirely, so that a clean product shot is one toggle.

### Canvas

20. As a user, I want a **background** — none, solid colour, gradient preset, built-in wallpaper, or my own image, optionally blurred — so that the recording sits on something designed.
21. As a user, I want **padding, rounded corners and a shadow** on the screen, so that it looks like a card.
22. As a user, I want the **aspect ratio** — auto (source), 16:9, 4:3, 1:1, 4:5, 9:16 — so that one take fits YouTube, a square post or Reels.

### Camera and keystrokes (studio takes)

23. As a user, I want to **move, resize, reshape, mirror and hide the camera** after recording, so that it never covers the demo.
24. As a user, I want to **show or hide keystrokes** and change their position / size / appearance after recording, so that shortcuts appear only when I want.

### Output

25. As a user, I want to pick **resolution** (source, 4K, 1440p, 1080p, 720p), **frame rate** (24 / 30 / 60), **codec** (H.264 / HEVC) and **quality**, with an **estimated size**, so that I control file size.
26. As a user, I want to export **MP4 or GIF**, with progress and cancel, so that I get the format I share.
27. As a user, I want the export **saved like any recording** (save location, history, optional copy to clipboard), so that the finished video lands where my other captures do.
28. As a user, I want the existing audio edits (mute / volume / mono / remove) to keep working, so that nothing I had is lost.

## Implementation Decisions

- **Studio take = clean screen + data, never baked.** `RecordingOptions` gains `studio: Bool` (set by Record in Studio Mode). A studio take streams with `showsCursor = false` and the `RecordingCompositor` inactive (no halos, keystrokes or camera drawn into frames); the input sources run regardless of the highlight / keystroke toggles (keys only with the Input Monitoring grant and `showKeystrokes` on; `secureInput` still suppresses them), and every event is appended to a `StudioInputRecorder` with its time in **source seconds** (host time minus the first frame's time minus paused time). The camera, when on, is written by its own `AVAssetWriter` to `camera.mov` on the same clock. At stop, the service writes `input.json` (`StudioInput`: version, region size in points, samples, clicks, key events) and returns the screen URL; the camera and input files sit beside it with the same base name. Non-studio takes are unchanged.
- **Every video take keeps its input (follow-up, 2026-09-23).** Ordinary video takes record the same pointer / click / key data as a studio take, flagged `cursorInVideo` (the cursor is drawn into their movie). The sidecar `<take>.input.json` moves into history with the take (`HistoryStore` moves and deletes it with the media) and reaches the editor through `CaptureUI.openVideoEditor(at:input:)`, so Auto Zoom and follow-cursor zooms work on any recording. The editor never draws a second cursor over one in the movie; the Cursor panel says restyling needs Record in Studio Mode. Takes made before this have no data and say so.
- **Every recording is a studio take — the OpenScreen model (S8, LIG-57, 2026-09-23).** Start Video and Start GIF capture the same ingredients as Record in Studio Mode (clean screen, input data, the camera as its own movie), and every take becomes a studio project. With *After recording → Open editor* (or Record in Studio Mode) the project opens in the Studio editor. Otherwise the coordinator renders the project through `StudioFlattening` (the Studio renderer + exporter) with the take's own look — `StudioEdits.flattenLook(options:)`: cursor if "Show cursor", a click ripple if clicks are highlighted, keystrokes, the camera bubble; no studio decoration — behind a "Preparing your recording…" popup; the rendered movie (or GIF) then goes through history / the overlay / save as before, carrying a `<take>.lightshot-project` link that `HistoryStore` moves and deletes with it, so Open Video Editor (overlay or history) opens the editable project. Cancelling or failing the render opens the project instead — a take is never lost. Known difference: the recorder's live "highlight clicks" halo that followed the pointer is rendered as a click ripple.
- **Studio project = a folder.** `<support>/Studio Projects/<name>.lightshotstudio/` holds `screen.mp4`, optional `camera.mov`, optional `input.json` and `project.json` (`StudioDocument.Edits`, Codable, versioned). `StudioProjectStore` (kit, Foundation only, like `HistoryStore`) creates a project by **moving** a studio take's files in, lists recent projects, and loads / saves edits. The coordinator routes a studio take to the store and then `openStudio(project:)`; it is not archived to history and not delivered to the save location — the export is. A plain MP4 opens as a *transient* session (no folder; edits live only while the window is open), keeping spec 0006's new-file / replace / revert save modes for that case.
- **`StudioDocument` is the seam, like `AnnotationDocument`.** A value type mutated only through commands (`split(at:)`, `deleteClip`, `trimClip`, `setSpeed`, `addZoom(at:)`, `moveZoom`, `resizeZoom`, `setZoomScale`, `setZoomFocus`, `removeZoom`, `autoZoom`, `setBackground`, `setCanvas`, `setAspect`, `setCursor`, `setCamera`, `setKeystrokes`, `setAudio`, `setOutput`, `undo`, `redo`); each command snapshots `Edits` for undo (edits are small). Slider drags coalesce into one undo step via `beginChange` / `endChange`.
- **Time is pure.** `StudioTimeline(clips:)` gives `outputDuration`, `sourceTime(atOutput:)`, `outputTime(atSource:) -> Double?` (nil inside a cut) and the clip segments the app turns into an `AVMutableComposition` (`insertTimeRange` + `scaleTimeRange` per clip; `audioTimePitchAlgorithm = .spectral` so sped-up audio keeps its pitch). Zoom regions live in **source time**, so a cut simply hides the part of a zoom it removes.
- **Zoom camera is pure.** `ZoomCamera.viewport(at: sourceTime)` returns the visible rect of the source (normalised), from the zoom regions, the transition duration (default 0.6 s, ease-in-out cubic on scale and centre) and — for follow-cursor zooms — the smoothed cursor, with the rect clamped inside the frame and a dead zone so small moves don't pan. Adjacent zooms blend directly instead of zooming out in between when the gap is shorter than one transition.
- **Cursor is pure.** `CursorPath` resamples the raw samples at 120 Hz and smooths them with a critically-damped spring (stiffness from the 0…1 smoothing value; 0 = raw); it answers `position(at:)`, `velocity(at:)` (for motion blur), `isIdle(at:)` (no movement for `idleDelay`, fade 0.25 s) and `clickProgress(at:)` (0…1 over 0.5 s after each click). Keystrokes replay the recorded `KeyEvent`s through spec 0006's `KeystrokeOverlayModel` up to the frame time.
- **Auto zoom is pure.** `AutoZoom.suggest(clicks:duration:)` clusters clicks closer than 3 s, makes one follow-cursor region per cluster from 0.8 s before the first click to 1.5 s after the last, scale 2, merges overlaps, and skips clusters shorter than the transition.
- **Canvas layout is pure.** `CanvasLayout(sourceSize:aspect:padding:outputHeight:)` gives the canvas size in pixels (even edges) and the screen's content rect (aspect-fit inside the padded canvas; padding is a fraction of the canvas' shorter side, 0…0.3); corner radius and shadow scale with it. `OutputSize` maps the resolution preset to the canvas (never upscaled beyond source unless the aspect requires it).
- **One renderer.** `StudioCompositor: AVVideoCompositing` (app target, Core Image on a Metal `CIContext`) renders each frame from a `StudioRenderState` snapshot (edits + timeline + input + camera track ID) carried by a custom `AVVideoCompositionInstructionProtocol`: background → shadow → source frame cropped to the zoom viewport, scaled into the content rect with a rounded-corner mask → cursor image (`NSCursor.arrow`, scaled by size × zoom) with directional motion blur from velocity → click effect → camera frame (from the composition's camera track, masked to its shape, laid out by spec 0006's `CameraBubbleLayout`) → keystroke pills. Screen motion blur (0…1) blends the previous viewport when the zoom camera moves. The preview is an `AVPlayerItem` over the composition with that video composition at a reduced render size; edits swap in a new video composition (and re-seek when paused). Export uses `AVAssetReaderVideoCompositionOutput` + `AVAssetReaderAudioMixOutput` into spec 0006's `AVAssetWriter` pump at the chosen size / fps / codec / bit rate (`VideoBitRate`), and GIF runs spec 0006's `GIFEncoder` on the exported MP4.
- **Wallpapers are generated, not bundled images.** Built-in wallpapers are named Core Image recipes (multi-stop gradients + soft radial blobs) so the app ships no image assets and they scale to any canvas; custom images are copied into the project folder.
- **Editor layout (CleanShot studio, LIG-43 shell kept).** Preview centre, inspector rail on the right (Background, Cursor, Zoom, Camera, Keys, Audio, Output), transport under the preview, timeline at the bottom with a ruler, clip track (split / delete / trim handles / speed badge), zoom track (pills, + Zoom, Auto Zoom) and the playhead. Clicking the preview while a zoom is selected sets its focus point. Export stays the toolbar's prominent button (⌘E).

## Testing

Pure and tested in `LightshotKit`: `StudioDocument` commands and undo/redo (split, delete, trim, speed, zoom add/move/resize/remove, coalesced slider changes, Codable round trip and version), `StudioTimeline` mapping both ways across cuts and speeds, `ZoomCamera` (no zoom = full frame, eased transition midpoint, follow-cursor clamped inside the frame, dead zone, blended adjacent zooms), `CursorPath` (raw at smoothing 0, smoothing lags then converges, idle detection, click progress), `AutoZoom` clustering and merge, `CanvasLayout` for every aspect and padding, `OutputSize`, `StudioInput` Codable, `StudioInputRecorder` clock (pause excluded), `StudioProjectStore` against a temp directory (create moves files, save/load edits, recent list order), and coordinator routing with fakes (studio take → project → `openStudio`; plain take unchanged). The compositor, composition building and export are verified by an offline harness (synthetic screen movie + synthetic input → exported frames checked for background colour, content-rect edges, zoomed crop and cursor position) and a manual checklist.

## Round 2 — closing the OpenScreen gaps (2026-09-23)

Round 1 (S1–S4) shipped the studio core, capture, renderer and editor. Comparing it feature by feature with OpenScreen left three gaps, now in scope.

### Stories

29. As a user, I want to **transcribe the narration on this Mac** and see it as **captions** burned into the video — font size, position (top / bottom), colours, a backdrop — so that a muted autoplay still reads.
30. As a user, I want to **edit a caption's text** and **delete a word or phrase from the transcript to cut it** from the video, so that editing speech is as easy as editing text.
31. As a user, I want **Remove Silences** to cut every pause longer than a threshold, so that dead air goes in one click.
32. As a user, I want to add **text annotations** — a title card or a callout — on their own timeline track with a time range, position, size, colours and a fade, so that I can label what is happening.
33. As a user, I want to **drag the camera bubble and annotations on the preview**, pills and handles to **snap** to the playhead and each other, and an **audio waveform** on the clip track, so that precise edits are direct.

### Decisions

- **Transcription is on-device only.** `SFSpeechRecognizer` with `requiresOnDeviceRecognition = true` (macOS 14+), asked for through the lazy permission gate (`PermissionKind.speechRecognition`, `NSSpeechRecognitionUsageDescription`); where the locale has no on-device model the panel says so — nothing is ever sent to a server (local-only guardrail). The first audio track is exported to M4A and transcribed; words land in `transcript.json` beside the project (`StudioTranscript`: words with source times) — an analysis of the take, not an edit.
- **Captions are edits.** `StudioEdits.captions` holds the caption lines (source times + text, built by the pure `CaptionBuilder` from the words: a new line after 42 characters, a pause over 0.6 s, or sentence punctuation) and their style; editing a line's text is an undoable command. The renderer draws the line under the source time on the content, like the keystroke pills.
- **Transcript cuts are clip edits.** `StudioDocument.cut(sourceRange:)` removes a source range from the clips (splitting a clip it falls inside, trimming ones it overlaps, deleting ones it covers); deleting words cuts their span; `removeSilences(words:minimumGap:padding:)` cuts every gap between words longer than `minimumGap`, keeping `padding` either side. All pure and tested.
- **Annotations are edits too.** `StudioEdits.annotations: [TextAnnotation]` — source time range, text, centre (normalised to the content), size, text / background colours, fade — drawn above the camera. Dragging on the preview moves one; one drag is one undo step.
- **Snapping and waveform are view concerns.** Pill and handle drags snap within 8 points to the playhead and to clip / zoom / annotation edges (pure `TimelineSnap` in the kit); the waveform is peak data read once from the audio track (`AVAssetReader`) and drawn under the filmstrip.

### Issue breakdown (round 2)

| # | Linear | Scope | Stories |
|---|---|---|---|
| S5 | LIG-54 | On-device transcription, `StudioTranscript`, `CaptionBuilder`, captions in edits + renderer, transcript panel, `cut(sourceRange:)`, Remove Silences | 29–31 |
| S6 | LIG-55 | Text annotations: model, renderer, timeline track, inspector, drag on preview | 32 |
| S7 | LIG-56 | Camera drag on the preview, `TimelineSnap`, audio waveform | 33 |
| S8 | LIG-57 | Every recording is a studio take: clean capture + data for all takes, rendered for quick shares, linked back to its project | 1–4, 14–19 on every take |

## Round 3 — trim and speed pills, cursor styles (2026-09-24, LIG-66)

Trimming by dragging clip edges did not match the rest of the timeline, which edits with pills. Round 3 makes trims and speed changes pills too, adds cursor styles, and starts studio projects without padding.

### Stories

34. As a user, I want to **add a trim at the playhead** and drag or resize its pill on a Trim track, like a zoom or a text, so that the trimmed part is **skipped** in the preview and left out of the export.
35. As a user, I want to **speed up or slow down** a stretch with a pill on a Speed track (0.25×–4×), so that boring parts play fast and key moments play slowly.
36. As a user, I want to pick a **cursor style** from a grid of presets (as in OpenScreen), so that the cursor matches the video's look.
37. As a user, I want a new studio project to start with **no padding and no corner radius**, so that the recording fills the frame until I decide otherwise.

### Decisions

- **The timeline shows source time.** The whole recording stays on the timeline and trimmed spans are shaded on the filmstrip. The playhead shows the source time of the playing frame. Clicking inside a trim seeks to where playback resumes.
- **Trims and speed changes are regions, like zooms.** `StudioEdits.trims: [TrimRegion]` and `speeds: [SpeedRegion]` are in source seconds, and regions in one lane never overlap. `StudioEdits.clips` is **derived**: the source minus the trims, split at the speed regions' edges. So `StudioTimeline`, the composition, the preview and the export skip trims and apply speed unchanged. A change that would trim everything is refused.
- **Split and clip-edge trimming are removed** (this supersedes stories 6–8). `cut(sourceRange:)`, transcript cuts and Remove Silences add trim regions. Projects saved before round 3 migrate on load: the gaps between their clips become trims and clip speeds become speed regions (`StudioEdits.currentVersion` 2).
- **Cursor styles are vector presets** drawn by the renderer: macOS (default), White, Pink, Mint, Violet, Blue, Neon, Outline, Bold and Yellow (`CursorTheme`). `CursorStyle.theme` is decoded with a default, so old projects still open. The Cursor panel shows the presets as a tile grid rendered from the same art. This supersedes decision 3.
- **Studio look default:** padding 0 and corner radius 0. Existing projects keep what they saved.

## Out of Scope

- AI editing agents, cloud rendering, translation.
- Arrow / image annotations on the video (text annotations are round 2).
- Recording the system cursor's changing shape (the studio cursor is an arrow, in the chosen style).
- Multi-display studio takes; editing several takes into one video.

## Issue breakdown (Linear issues)

| # | Linear | Scope | Stories |
|---|---|---|---|
| S1 | LIG-50 | Studio core in the kit: `StudioDocument` + commands/undo, `StudioTimeline`, `ZoomCamera`, `CursorPath`, `AutoZoom`, `CanvasLayout`, `OutputSize`, `StudioInput` | 5–22 (logic) |
| S2 | LIG-51 | Studio take: clean stream, `StudioInputRecorder`, camera movie, `input.json`; `StudioProjectStore`; coordinator routing; recent projects menu | 1–4 |
| S3 | LIG-52 | `StudioCompositor` + composition builder + preview + export (MP4 / GIF, size / fps / codec / quality) | 13–28 (rendering) |
| S4 | LIG-53 | Studio editor UI: timeline tracks, inspector panels, preview focus picking, undo/redo, autosave | 5–28 (UI) |

## Decisions taken (2026-09-23)

1. **Plain MP4s open in the Studio editor too**, with cursor / camera / keystroke panels disabled and a one-line reason — one editor, not two.
2. **Studio projects are not history entries**; their exports are. Recent projects live in the menu bar (last 10).
3. **The studio cursor is the system arrow**, drawn from data; shape changes are out of scope for v1.
4. **No bundled wallpaper images** — generated gradients only, plus the user's own image.
