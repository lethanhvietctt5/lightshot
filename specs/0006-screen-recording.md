# Spec 0006 — Screen Recording (video + GIF)

**Status:** accepted — tracked in Linear; the decisions at the end are taken and the sub-issues are being implemented in order
**Linear:** epic [LIG-26](https://linear.app/light-shot/issue/LIG-26) with sub-issues LIG-27 … LIG-41 (see §Issue breakdown)
**Platform:** Native macOS (Swift / SwiftUI + AppKit), macOS 14+ (ScreenCaptureKit `SCStream`, AVFoundation)
**Scope:** Local-only. The biggest follow-up Spec 0001 deferred: record an area, a window or a display as MP4 or GIF, with microphone / computer audio, a webcam bubble, click and keystroke visualisation, and a trim/convert step afterwards. No cloud, no accounts, no network.

Parity reference: [`docs/research/cleanshot-x-recording-inventory.md`](../docs/research/cleanshot-x-recording-inventory.md) — what CleanShot X 4.8.3 actually does, with evidence. Vocabulary in [`CONTEXT.md`](../CONTEXT.md) gains the terms in §Vocabulary once this spec is accepted.

---

## Problem Statement

Screenshots explain a state; they cannot explain a motion. When I need to show a bug reproducing, a UI flow, or "click here, then here", I reach for CleanShot X's Record Screen: pick an area, hit Start, talk over it, stop, trim, and share an MP4 or a small GIF. Lightshot has none of that, so the moment a screenshot isn't enough I am back in the other app. I want the same recording flow — area / window / fullscreen, video or GIF, mic and computer audio, my webcam in a corner, clicks and keystrokes shown, a quick trim — running entirely on my machine.

## Solution

A **Record Screen** action next to the capture actions. It reuses the selection overlay in a *record* mode to resolve a region, then shows a **recorder toolbar** at the selection: Start Video, Start GIF, and per-recording toggles for microphone, computer audio, camera, click highlighting and keystrokes. After an optional countdown the region streams through ScreenCaptureKit into an MP4 written by AVFoundation; the menu-bar item turns into a stop button with the elapsed time; a small controls pill offers pause / resume / stop / restart / discard. When recording stops, a **post-recording overlay** shows the result with copy / save / trim / delete, or opens the **video editor** (trim, resize, quality, audio) if that is the configured default. GIF is recorded as video and converted afterwards, cancellable back to the video. Recordings join the local history alongside screenshots.

## Vocabulary

- **Recording** — one video or GIF produced by a single start→stop session.
- **Recording region** — what is recorded: a rect, a window, or a display. Same `CaptureRegion` as screenshots plus the display case.
- **Recorder toolbar** — the pre-start toolbar at the selection (Start Video / Start GIF + toggles). _Avoid_: recorder overlay.
- **Recording controls** — the pause / resume / stop / restart / discard pill shown while recording.
- **Post-recording overlay** — the result popup after stop. CleanShot calls it the Quick Access Overlay. _Avoid_: QAO.
- **Video editor** — the trim / resize / quality / audio window. Not the annotation editor.
- **Input visualisation** — click highlighting and the keystroke overlay, collectively.

## User Stories

### Starting a recording

1. As a user, I want a **Record Screen** menu item and global hotkey, so that recording is as reachable as a screenshot.
2. As a user, I want the same hotkey to **stop** a recording in progress, so that one chord starts and ends the session.
3. As a user, I want to **drag an area** to record and then **keep adjusting it** — move it, resize it by its edges and corners, nudge it with the arrow keys — until I press Start, so that I record exactly the region I mean. (Unlike a screenshot, releasing the drag does not confirm.)
4. As a user, I want to **lock the aspect ratio** of the recording area (16:9, 4:3, 1:1, 9:16 …) and type an exact width/height, so that the output fits where I will post it.
5. As a user, I want to **pick a window** to record, so that the recording stays clean when I move other windows.
6. As a user, I want to **record a whole display**, so that I can capture everything at once.
7. As a user, I want the app to **remember my last recording area** (optional), so that repeat recordings of the same spot need no re-selection.
8. As a user, I want a **recorder toolbar** at the selection offering Start Video and Start GIF plus toggles for microphone, computer audio, camera, click highlighting and keystrokes, so that I can set up each recording without opening Settings.
9. As a user, I want per-recording toggles to **override the defaults from Settings**, so that I can mute the mic for one recording without changing my preference.
10. As a user, I want an optional **countdown** (3-2-1) before recording starts, so that I can get my hands in position.

### While recording

11. As a user, I want the **menu-bar item to show the elapsed time and act as a stop button**, so that I always know I am recording and can end it in one click.
12. As a user, I want a small **controls pill** with pause / resume / stop / restart / discard, so that I can manage the session without hunting for the menu.
13. As a user, I want to **pause and resume**, so that a break in the middle doesn't have to be trimmed out later.
14. As a user, I want **restart** and **discard** to confirm before throwing away footage, so that a mis-click doesn't cost me a take.
15. As a user, I want the controls and the toolbar to be **excluded from the recording**, so that the output shows only my content.
16. As a user, I want the screen outside the recording area **dimmed** (optional), so that I can see what is in and out of frame.
17. As a user, I want the display to **not sleep** while recording, so that a long demo isn't cut short.
18. As a user, I want a recording to be **recovered if the app crashes** mid-session, so that I don't lose a long take.
19. As a user, I want the cursor **shown or hidden** in recordings (setting), so that I can point at things or keep the output clean.

### Audio

20. As a user, I want to **record my microphone**, choosing which input device, so that I can narrate.
21. As a user, I want to **record computer audio** (what other apps play), so that demos with sound are complete.
22. As a user, I want mic and computer audio **on one track or separate tracks**, so that I can mix them later if I want.
23. As a user, I want a **level meter** while recording, so that I know the mic is actually picking me up.
24. As a user, I want a **warning if my mic looks muted** or gets **disconnected** mid-recording (continue without audio / stop), so that I don't record a silent take.
25. As a user, I want **mic and computer audio volume** sliders and a **mono** option, so that levels come out balanced.

### Webcam

26. As a user, I want my **camera composited in a corner** of the recording, so that viewers see me talking.
27. As a user, I want to choose the **camera device, size, shape (circle / rounded / square) and mirroring**, and to **drag** the bubble anywhere in the frame, so that it sits where it doesn't cover content.
28. As a user, I want to **click the camera bubble to make it fullscreen** and back, so that I can switch between "me" and "screen".

### Input visualisation

29. As a user, I want **clicks highlighted** with a configurable style (ring / filled / outline), size, colour and an optional click animation, so that viewers can follow where I click.
30. As a user, I want **keystrokes shown** as an overlay (all keys or command-chords only), with configurable position, size, appearance (light / dark / system) and a blurred backdrop, so that shortcuts I press are visible.
31. As a user, I want keystrokes typed into **password fields never shown**, so that the overlay can't leak a secret.

### After recording

32. As a user, I want a **post-recording overlay** showing the result with copy file / save / open editor / trim / delete / Quick Look, so that common outcomes are one click away.
33. As a user, I want to configure **what happens after a recording** (show overlay, save silently, open the video editor), separately from the screenshot setting, so that my default flow is one step shorter.
34. As a user, I want to **drag the video or GIF out** of the overlay into another app, so that it lands where I need it.
35. As a user, I want a **video editor** to **trim** start/end, **resize** to presets or exact dimensions, pick **quality**, and adjust **audio** (mute / volume / mono / remove), with an **estimated file size**, so that I can ship a smaller file without another app.
36. As a user, I want to **save as a new file or replace** the original, and **revert to original**, so that editing is never destructive by accident.
37. As a user, I want **GIF** output with FPS, quality, max width and optimisation settings, so that the GIF is small enough to paste in chat.
38. As a user, I want to **cancel a GIF conversion and keep the video** instead, so that a slow conversion isn't a dead end.
39. As a user, I want recordings in the **local history** with a thumbnail, so that I can find, reopen, reveal or delete them like screenshots.

### Settings & permissions

40. As a user, I want a **Recording** settings section for video FPS, max resolution, encoder (H.264 / HEVC), Retina scale-to-1x, and the toggles above, so that I can tailor size versus fidelity.
41. As a user, I want the app to **ask for Microphone, Camera and Input Monitoring (keystrokes) permission only when I first enable that feature**, with a path to System Settings if denied, so that I am never stuck and never asked for something I don't use.
42. As a user, I want **Pause/Resume** and **Restart** to be rebindable hotkeys, so that I can control a recording without touching the mouse.

## Implementation Decisions

- **Seams first, as with screenshots.** A pure `RecordingSession` value type in `LightshotKit` owns the state machine (`idle → countdown → recording ⇄ paused → stopping → finished(URL) | failed(RecordingError)`) and the elapsed-time arithmetic across pauses; a pure `RecordingOptions.resolve` merges the settings defaults with the per-recording overrides into the one immutable `RecordingOptions` a session runs with. Everything OS-facing hides behind `RecordingService` (ScreenCaptureKit + AVAssetWriter), `AudioInputService` (mic devices, levels), `CameraService` (devices, frames), `InputEventSource` (click/key taps), and `MediaSink` (copy file / save; drag-out is an `NSItemProvider` over the file URL in the app, no seam needed). The domain package still imports no AppKit / ScreenCaptureKit / AVFoundation. *As built (R9):* `CameraService` only enumerates cameras, like `AudioInputService`; frames are pixel buffers, so the capture (`CameraCapture`, one `AVCaptureSession` feeding both the preview layer and the compositor's newest-frame slot) stays in the app. The pure `CameraBubbleLayout` gives the bubble's frame in region points from `CameraBubbleSettings` (size as a share of the shorter side with an 80-pt floor, shape radius, mirror, and the dragged position stored as a normalised anchor so it survives a different region); the on-screen bubble and the compositor both call it and scale by their own pixels-per-point, which is how preview and output agree. A click toggles fullscreen (the bubble covers the region, aspect-filled) in both at once through the shared `CameraFeed`; the preview panel is one of Lightshot's windows, so the process exclusion keeps it out of the stream. The preview appears as soon as the camera toggle is on and stays through the countdown and the take. A camera that cannot open costs the bubble, not the take.
- **Restart and discard are transitions, not side channels.** `restart` is legal from `recording` and `paused`: the partial file is deleted, the elapsed time resets to zero, and the session returns to `countdown` when a countdown is configured, otherwise straight to `recording` with the same `RecordingOptions`. `discard` is legal from `countdown`, `recording` and `paused`: the partial file is deleted and the session ends in `idle` — terminal for that take, no history entry, no post-recording overlay. `stop` from `countdown` behaves like `discard` (nothing was written). Every other combination is an illegal transition and R1 tests it. Only `stopping → finished(URL)` produces a file the rest of the app ever sees.
- **One `CaptureRegion` for screenshots and recordings, but record mode is a new interaction, not a reuse.** Add `.display(id:)` so the recorder can target a whole display through the same type the overlay already resolves. The screenshot overlay confirms on mouse-up and has no handles (Spec 0002 removed them). Record mode keeps the drag, the dimmed backdrop and the live pixel readout, but **mouse-up does not confirm**: the selection stays on screen as an editable rect with eight edge/corner handles, is movable by dragging inside it, and nudges with the arrow keys (⇧ resizes by 10 px). It is confirmed only by Start in the recorder toolbar (R4; until R4 lands, Return) and cancelled by Escape. The ratio lock constrains both the initial drag and every handle drag (the dragged edge moves, the opposite edge stays anchored, the other axis follows); typed width/height resize from the top-left corner and clamp to the display; Option during a drag forces 1:1. Clicking a hovered window snaps the selection to that window's frame and resolves `.window(id:frame:)`, which the recorder captures with a window content filter (story 5) — a snapped window shows no handles; dragging a fresh rect leaves window mode. The geometry is `EditableSelection`, a pure value in `LightshotKit` that is unit-tested; the app's `RecordingOverlayModel` adds what needs a screen (the window pick, click-vs-drag, the Option key) and `OverlayController` gains `selectRecording(initial:defaults:)` (stories 3–9). Arrow keys nudge by 1 px and ⇧-arrows resize by 10 px — native pixels, like the readout and the typed fields. A click outside an existing selection clears it so windows can be picked again; a rect covering the whole display resolves to `.display`. The Fullscreen button selects the whole display (Start then resolves `.display`) — the main screen in v1, like the screenshot overlays. The recorder toolbar (R4) is the overlay's control strip, so the selection stays adjustable while the user picks Start Video / Start GIF and flips the per-recording toggles; the overlay resolves one `RecordingChoice` (region, output, overrides). The countdown is a `CaptureUI` step the coordinator awaits, so Escape during it discards the take before anything is recorded.
- **Overlays are composited into the stream, not into the screen.** Cursor highlight, keystrokes and the camera bubble are drawn by the recorder onto each frame before encoding, so the recording controls, the toolbar and the dimming never appear in the output (story 15) and the overlays render identically on every display scale. The exclusion itself is mechanical, not cosmetic: every Lightshot window (toolbar, controls pill, countdown, dimming, camera preview) is excluded from the `SCContentFilter` by process, so the stream never contains them even if one overlaps the region.
- **Computer audio via ScreenCaptureKit** (`SCStreamConfiguration.capturesAudio`), never a loopback driver: macOS 14+ makes CleanShot's legacy driver path unnecessary and it would violate the "no system-level installs" spirit of a self-signed local app. *As built (R8):* the stream captures audio at 48 kHz with `excludesCurrentProcessAudio`, so Lightshot's own cues never reach the file; per-source volume is applied to the PCM before anything else; "separate tracks" writes one AAC track per source, "single track" sums both by sample time through the pure `AudioMixer` (silence for a source that started late or stalls beyond two seconds, clipped to unity) into one AAC track; mono asks both the microphone and the stream for one channel.
- **After a take, the file waits in scratch until the overlay decides.** *As built (R12):* `RecordingDefaults.afterRecording` (show overlay — the default — / save silently / open editor, story 33) is read when the take finishes. The overlay path leaves the file in the scratch directory and hands the coordinator a `PendingRecording`; **Save** (or a dismissal by Escape, the 20-second timeout, or the app moving on) moves it to the save location under the filename pattern or the name typed into the overlay's Rename field (path separators and leading dots stripped, empty falls back to the pattern), **Copy file** puts the scratch file's URL on the pasteboard and keeps the overlay up, **Delete** confirms then moves it to the Trash, and the preview drags out as the file itself. Save silently and open editor move the file first; the editor and Trim are inert until R14. A failed save or delete surfaces and leaves the take pending, so nothing is lost. A drag-out copies; the original is still saved on dismissal.

- **GIF = video first, then convert** (as CleanShot does): the session always writes MP4; a `GIFEncoder` (ImageIO, palette per frame; optional gifsicle-style optimisation done in-process) converts afterwards with progress and cancel-to-video (story 38). No bundled third-party binaries.
- **Video editor is a separate window over AVFoundation** (`AVAssetExportSession` / `AVAssetWriter`), not the annotation editor. Trim math (`TrimRange`, clamped, minimum length) and the size estimator are pure and tested; encoding is not.
- **History stores media files, not only images.** `CaptureRecord` gains `kind: screenshot | video | gif` and `duration: TimeInterval?`. `HistoryStore` gains `add(mediaAt: URL, kind:, pixelWidth:, pixelHeight:, duration:, thumbnail: Data, source:)`, which **moves** the finished file into the store's directory (keeping its extension) and writes the caller-supplied thumbnail — the store stays AppKit/AVFoundation-free because the app target supplies what only AVFoundation knows: the first-frame thumbnail from `AVAssetImageGenerator`, and the full-resolution `pixelWidth` / `pixelHeight` read from the finished asset's video track (`naturalSize`, which equals the encoder's output dimensions after max-resolution / Retina scaling) — never inferred from the thumbnail. `CaptureRecord`'s existing dimension fields therefore keep their contract for every kind. **GIFs take the ImageIO path, not the AVFoundation one:** for `kind == .gif` the app target reads pixel dimensions from `CGImageSourceCopyPropertiesAtIndex` and makes the thumbnail from frame 0 via `CGImageSourceCreateThumbnailAtIndex` — the same ImageIO calls `HistoryStore` already uses for PNGs — and `duration` is the sum of the frame delays. `fileURL` already points at the owned file, so reveal/delete/retention need no new API; reopen is by kind: `capturedImage(for:)` returns `nil` for non-screenshot records; `.video` reopens in the video editor; `.gif` reopens in the post-recording overlay (copy / save / reveal / delete / Quick Look) because **GIF trimming is out of scope for v1** — the overlay hides Trim and Open video editor for a GIF, and the intermediate MP4 is deleted after a successful conversion. **Backward compatibility is an explicit decoding rule, not a hope:** `StoredEntry` gets a custom `init(from:)` that reads `kind` and `duration` with `decodeIfPresent`, defaulting to `.screenshot` / `nil`, so an `index.json` written before this spec still loads every record — R15 tests decoding a pre-0006 fixture.
- **Permissions are lazy and per-feature.** `PermissionKind` gains `microphone`, `camera`, `inputMonitoring`. The keystroke overlay uses a **listen-only** `CGEvent` tap (`.listenOnly`), which macOS gates behind **Input Monitoring** (`CGPreflightListenEventAccess` / `CGRequestListenEventAccess`, System Settings → Privacy & Security → Input Monitoring) — not Accessibility, which CleanShot requests because its tap can also modify events. Lightshot never needs Accessibility; the mouse tap for click highlighting needs no grant at all. **Story 31's guarantee rests on secure event input, not on inspecting the focused control:** when any password field has focus, macOS turns on secure event input system-wide and stops delivering its keystrokes to event taps; the public `IsSecureEventInputEnabled()` (HIToolbox) reports that state. The keystroke overlay polls it on every key event and every rendered frame, and while it is `true` the `KeystrokeOverlayModel` is fed `secureInput = true`, which suppresses all keys, clears anything still fading out, and shows nothing — conservatively, whatever the tap happened to deliver. No per-control Accessibility inspection is attempted. **Usage strings are part of the contract:** `App/Resources/Info.plist` today declares neither `NSMicrophoneUsageDescription` nor `NSCameraUsageDescription`, and macOS refuses the AVFoundation authorisation prompt without them, so R6 adds both (and R6's acceptance criteria check the prompt actually appears). **Recovery is kind-aware:** `CaptureUI.presentPermissionDenied()` becomes `presentPermissionDenied(_ kind: PermissionKind)` and `RecordingError.permissionDenied(kind)` carries the kind, so `AppController` picks the message and the System Settings pane per kind — `Privacy_ScreenCapture`, `Privacy_Microphone`, `Privacy_Camera`, `Privacy_ListenEvent` — instead of the Screen-Recording-only alert it hard-codes today; the existing screenshot paths pass `.screenRecording` and keep their behaviour; onboarding (LIG-21) keeps asking only for Screen Recording, and each recording feature requests its permission the first time it is toggled on, with the same System-Settings recovery path as capture. *As built (R11):* `KeyEventTap` is a listen-only `CGEvent` tap on the HID tap point, spinning its own run loop on a background thread and re-enabling itself if macOS disables it for slowness; every key-down and modifier change is preceded by a `secureInput(IsSecureEventInputEnabled())` event, and the compositor re-polls the flag on every frame. The pure `KeystrokeOverlayModel` shows one pill per chord (`fn ⌃ ⌥ ⇧ ⌘` glyphs then the key label from `KeyLabel`), counts a same-chord press within one second as `×n` with a re-bump instead of a new pill, keeps the newest three, holds each 1.5 s then fades over 0.35 s, and shows held modifiers as their own pill while nothing fresh is on screen; "Only command keys" drops presses without ⌘ ⌃ ⌥ (⇧ alone is typing). The pill's `system` appearance is resolved once at start from the interface style, and the blurred backdrop is a CoreImage Gaussian blur of the frame under the pill.
- **Hotkeys:** `CaptureAction` gains `recordScreen` (toggle start/stop), `pauseResumeRecording`, `restartRecording`. None carries a default chord — Lightshot claims no extra global shortcuts by default, and CleanShot's default for Record Screen could not be verified. Menu rows show the live binding as in Spec 0005.
- **Not doing "Do Not Disturb"**: macOS exposes no public API to toggle Focus; CleanShot pokes a private Notification Center default. A best-effort "hide notifications" is out of scope for v1.

## Testing

Pure and tested in `LightshotKit`: `RecordingSession` transitions and illegal transitions, elapsed time across pause/resume, option resolution (overrides beat defaults), aspect-ratio and size-field math in the overlay model, `TrimRange` clamping, GIF frame-sampling plan for a given FPS, size estimation, history media ownership against a temp directory (a pre-0006 index decodes with `kind = .screenshot`; `add(mediaAt:…)` moves the file in keeping its extension and the source path no longer exists; the supplied thumbnail bytes are persisted and served back; `capturedImage(for:)` returns `nil` for video/gif records while `fileURL` resolves; a GIF fixture yields ImageIO-derived dimensions, a frame-0 thumbnail and a duration; `remove`, `clear` and retention trimming delete media files exactly as they delete PNGs — mirroring the invariants `HistoryStoreTests` already pins for screenshots), `KeystrokeOverlayModel` under `secureInput = true` (emits nothing for any key, clears pending entries, resumes only after it turns `false`) plus a manual check that typing into a login-window or Safari password field shows nothing in the output, and coordinator routing with fakes (`permissionDenied(kind)` → the recovery for **that** kind, never the Screen Recording one; `userCancelled` → silent). OS wrappers (`SCStream`, `AVAssetWriter`, event taps, camera) are verified by a manual checklist per issue.

## Out of Scope

- Cloud upload / share links (local-only guardrail).
- CleanShot 5.0 **Studio Mode**: smart zoom following the cursor, cursor smoothing, motion blur, backgrounds, post-hoc overlay editing, vertical/square re-framing.
- Presenter Overlay integration, "Do Not Disturb" toggling, hide-desktop-icons (its own small spec if wanted).
- Annotating video frames in the annotation editor.
- Trimming or re-encoding GIFs after conversion (CleanShot's `GIFTrimmer`); a GIF reopens in the post-recording overlay only.
- A URL-scheme / AppleScript API for starting recordings.

---

## Issue breakdown (Linear issues)

One epic plus fifteen child issues, created 2026-09-22. Each child follows the LIG-5 child template (Parent · What to build · Acceptance criteria · Blocked by), carries **Feature** (or **Improvement**) and gets **Ready for Agent** once the epic is accepted. Suggested order is the numbering; parallel groups are marked.

| # | Linear | Working title | Stories | Blocked by | Notes |
|---|---|---|---|---|---|
| E | LIG-26 | **Screen Recording (v1)** — epic mirroring this spec | all | — | Backlog epic like LIG-5 |
| R1 | LIG-27 | Recording domain model: `RecordingSession` state machine, `RecordingOptions`, `RecordingError`, new `CaptureAction` cases | 2, 9, 13, 42 | — | Pure Swift, Swift Testing; no UI |
| R2 | LIG-28 | Tracer bullet: Record Screen (display) → MP4 via `SCStream` + `AVAssetWriter` → menu-bar timer/stop → save to disk | 1, 2, 6, 11, 15, 17 | R1 | End-to-end spine; introduces `RecordingService`, `MediaSink`; menu row + hotkey |
| R3 | LIG-29 | Recording region: overlay *record* mode — editable selection (handles, move, arrow keys, no confirm on mouse-up), aspect-ratio lock, typed size, window pick, remember-last-area; `CaptureRegion.display` | 3, 4, 5, 6, 7 | R2 | Pure `EditableSelection` in the kit + `RecordingOverlayModel` in the app; no new seam |
| R4 | LIG-30 | Recorder toolbar + per-recording toggles + countdown + sounds | 8, 9, 10 | R3 | Toggles are hidden (not disabled) for features whose ticket hasn't landed |
| R5 | LIG-31 | Recording controls pill: pause / resume / stop / restart / discard, confirmations, dim outside area, exclusion from capture, crash recovery | 12, 13, 14, 16, 18 | R2 | Runs in parallel with the R3 → R4 chain and with R12, all after R2 |
| R6 | LIG-32 | Recording settings section + lazy permissions (`PermissionKind` microphone / camera / inputMonitoring), `Info.plist` usage strings, kind-aware `presentPermissionDenied(_:)` | 19, 40, 41 | R1 | Parallel with R2; other tickets add their rows |
| R7 | LIG-33 | Microphone audio: device picker, level meter, muted / disconnected handling, volume, mono | 20, 23, 24, 25 | R4, R6 | `AudioInputService`; AVCaptureSession in app target |
| R8 | LIG-34 | Computer audio via ScreenCaptureKit + single/separate tracks | 21, 22, 25 | R7 | Track layout decided here |
| R9 | LIG-35 | Webcam overlay: device, size, shape, mirror, drag, click-to-fullscreen, composited into frames | 26, 27, 28 | R4, R6 | `CameraService`; frame compositor introduced here or in R10, whichever lands first |
| R10 | LIG-36 | Click highlighting: `InputEventSource`, style / size / colour / animate, cursor show/hide, preview in settings | 19, 29 | R4, R6 | Parallel with R7–R9 |
| R11 | LIG-37 | Keystroke overlay: all keys / command-only, position, size, appearance, blur backdrop, password-field suppression | 30, 31 | R10 | Needs Input Monitoring; secure-input detection |
| R12 | LIG-38 | Post-recording overlay + after-recording actions + drag-out + Quick Look | 32, 33, 34 | R2 | Parallel with R3–R5 |
| R13 | LIG-39 | GIF recording: `GIFEncoder` (FPS, quality, max width, optimise), progress popup, cancel-to-video | 37, 38 | R4, R12 | Pure frame-plan + in-process encoder |
| R14 | LIG-40 | Video editor: trim, dimensions, quality, audio (mute / volume / mono / remove), estimated size, save-as-new / replace / revert | 35, 36 | R12 | Pure `TrimRange` + estimator; AVFoundation export |
| R15 | LIG-41 | Recordings in local history: `kind`, dimensions + duration from the asset, first-frame thumbnail, reopen / reveal / delete / retention; Spec 0005 menu row | 39 | R12 | Backward-compatible index; media-ownership tests |

Dependency spine: **R1 → R2 → {R3 → R4 → {R7 → R8, R9, R10 → R11}, R5, R12 → {R13, R14, R15}}**, with R6 alongside R2.

## Decisions taken (2026-09-22, at the start of R1)

Each proposal below is adopted as written; the sub-issues are `Ready for Agent` on that basis.

1. **Default hotkey for Record Screen** — proposal: none (rebindable), matching `window` / `repeatLast`. Alternative: ⌘⇧R, the only third-party claim for CleanShot's default.
2. **Encoders offered** — proposal: H.264 default, HEVC optional; FPS choices 10 / 15 / 30 / 60; max resolution Original / 1080p / 720p.
3. **GIF optimisation** — proposal: in-process (ImageIO + frame differencing), no bundled gifsicle; accept somewhat larger GIFs than CleanShot.
4. **Where the frame compositor lives** — proposal: app target, `RecordingCompositor`, fed by pure overlay *models* (positions, styles) from `LightshotKit` so layout math is testable. *As built (R10):* `RecordingCompositor` copies each ScreenCaptureKit frame into a pool buffer and draws the circles the pure `ClickHighlightModel` returns, mapped from screen points to frame pixels by `FrameMapping`; a frame with nothing to draw passes through uncopied. The **cursor itself is not composited**: ScreenCaptureKit draws it into the stream (`showsCursor`, story 19), which already keeps it off the screen-side overlays, so the compositor draws only the halo and click rings. The pointer source is an `NSEvent` monitor pair (global plus local, so the halo keeps following the pointer over Lightshot's own windows), not a `CGEvent` tap; it needs no grant either way. Pointer events and frames are both stamped from the host clock. Known v1 limit: a window recording maps clicks against the window's frame at start, so the highlight drifts if the window is moved mid-recording.
5. **Crash recovery** — proposal: write fragmented MP4 (`movieFragmentInterval`) so a partial file is playable; skip if it constrains encoders. *As built (R5):* `AVAssetWriter` fragments QuickTime movies, not MP4, so the writer produces a fragmented `.mov` in the scratch directory and `stop` rewraps it as MP4 with a passthrough export (no re-encode); an orphaned `.mov` found at launch is rewrapped beside itself, then delivered through `MediaSink.save` like any take (a name clash gets a numbered suffix, never an overwrite) and surfaced; a finished-but-undelivered `.mp4` is delivered the same way; an unreadable stub is deleted. Scratch lives in Application Support, not a temp dir the OS purges. If the rewrap itself fails at stop, the finished `.mov` is delivered under its own extension rather than lost.
