# Spec 0006 — Screen Recording (video + GIF)

**Status:** draft — tracked in Linear; children become `Ready for Agent` once the open decisions below are confirmed
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
3. As a user, I want to **drag an area** to record, with the same dimension readout and handles as area capture, so that I record exactly the region I mean.
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
41. As a user, I want the app to **ask for Microphone, Camera and Accessibility (keystrokes) permission only when I first enable that feature**, with a path to System Settings if denied, so that I am never stuck and never asked for something I don't use.
42. As a user, I want **Pause/Resume** and **Restart** to be rebindable hotkeys, so that I can control a recording without touching the mouse.

## Implementation Decisions

- **Seams first, as with screenshots.** A pure `RecordingSession` value type in `LightshotKit` owns the state machine (`idle → countdown → recording ⇄ paused → stopping → finished(URL) | failed(RecordingError)`), the elapsed-time arithmetic across pauses, and the option resolution (settings defaults + per-recording overrides → one immutable `RecordingOptions`). Everything OS-facing hides behind `RecordingService` (ScreenCaptureKit + AVAssetWriter), `AudioInputService` (mic devices, levels), `CameraService` (devices, frames), `InputEventSource` (click/key taps), and `MediaSink` (copy file / save / drag). The domain package still imports no AppKit / ScreenCaptureKit / AVFoundation.
- **One `CaptureRegion` for screenshots and recordings.** Add `.display(id:)` so the recorder can target a whole display through the same type the overlay already resolves; the overlay gets a *record* mode that adds the aspect-ratio lock and size fields (stories 3–6).
- **Overlays are composited into the stream, not into the screen.** Cursor highlight, keystrokes and the camera bubble are drawn by the recorder onto each frame before encoding, so the recording controls, the toolbar and the dimming never appear in the output (story 15) and the overlays render identically on every display scale.
- **Computer audio via ScreenCaptureKit** (`SCStreamConfiguration.capturesAudio`), never a loopback driver: macOS 14+ makes CleanShot's legacy driver path unnecessary and it would violate the "no system-level installs" spirit of a self-signed local app.
- **GIF = video first, then convert** (as CleanShot does): the session always writes MP4; a `GIFEncoder` (ImageIO, palette per frame; optional gifsicle-style optimisation done in-process) converts afterwards with progress and cancel-to-video (story 38). No bundled third-party binaries.
- **Video editor is a separate window over AVFoundation** (`AVAssetExportSession` / `AVAssetWriter`), not the annotation editor. Trim math (`TrimRange`, clamped, minimum length) and the size estimator are pure and tested; encoding is not.
- **History records gain a `kind`** (`screenshot | video | gif`) with a first-frame thumbnail; retention counts recordings like screenshots. Existing index entries decode with `kind = screenshot`.
- **Permissions are lazy and per-feature.** `PermissionKind` gains `microphone`, `camera`, `inputMonitoring`; onboarding (LIG-21) keeps asking only for Screen Recording, and each recording feature requests its permission the first time it is toggled on, with the same System-Settings recovery path as capture.
- **Hotkeys:** `CaptureAction` gains `recordScreen` (toggle start/stop), `pauseResumeRecording`, `restartRecording`. None carries a default chord — Lightshot claims no extra global shortcuts by default, and CleanShot's default for Record Screen could not be verified. Menu rows show the live binding as in Spec 0005.
- **Not doing "Do Not Disturb"**: macOS exposes no public API to toggle Focus; CleanShot pokes a private Notification Center default. A best-effort "hide notifications" is out of scope for v1.

## Testing

Pure and tested in `LightshotKit`: `RecordingSession` transitions and illegal transitions, elapsed time across pause/resume, option resolution (overrides beat defaults), aspect-ratio and size-field math in the overlay model, `TrimRange` clamping, GIF frame-sampling plan for a given FPS, size estimation, history `kind` decoding of old indexes, and coordinator routing with fakes (`permissionDenied` per permission kind → recovery; `userCancelled` → silent). OS wrappers (`SCStream`, `AVAssetWriter`, event taps, camera) are verified by a manual checklist per issue.

## Out of Scope

- Cloud upload / share links (local-only guardrail).
- CleanShot 5.0 **Studio Mode**: smart zoom following the cursor, cursor smoothing, motion blur, backgrounds, post-hoc overlay editing, vertical/square re-framing.
- Presenter Overlay integration, "Do Not Disturb" toggling, hide-desktop-icons (its own small spec if wanted).
- Annotating video frames in the annotation editor.
- A URL-scheme / AppleScript API for starting recordings.

---

## Issue breakdown (Linear issues)

One epic plus fifteen child issues, created 2026-09-22. Each child follows the LIG-5 child template (Parent · What to build · Acceptance criteria · Blocked by), carries **Feature** (or **Improvement**) and gets **Ready for Agent** once the epic is accepted. Suggested order is the numbering; parallel groups are marked.

| # | Linear | Working title | Stories | Blocked by | Notes |
|---|---|---|---|---|---|
| E | LIG-26 | **Screen Recording (v1)** — epic mirroring this spec | all | — | Backlog epic like LIG-5 |
| R1 | LIG-27 | Recording domain model: `RecordingSession` state machine, `RecordingOptions`, `RecordingError`, new `CaptureAction` cases | 2, 9, 13, 42 | — | Pure Swift, Swift Testing; no UI |
| R2 | LIG-28 | Tracer bullet: Record Screen (display) → MP4 via `SCStream` + `AVAssetWriter` → menu-bar timer/stop → save to disk | 1, 2, 6, 11, 15, 17 | R1 | End-to-end spine; introduces `RecordingService`, `MediaSink`; menu row + hotkey |
| R3 | LIG-29 | Recording region: overlay *record* mode with aspect-ratio lock, typed size, window pick, remember-last-area; `CaptureRegion.display` | 3, 4, 5, 7 | R2 | Reuses `OverlayController`; no new seam |
| R4 | LIG-30 | Recorder toolbar + per-recording toggles + countdown + sounds | 8, 9, 10 | R3 | Toggles are inert for features whose ticket hasn't landed |
| R5 | LIG-31 | Recording controls pill: pause / resume / stop / restart / discard, confirmations, dim outside area, exclusion from capture, crash recovery | 12, 13, 14, 16, 18 | R2 | R3–R5 can run in parallel after R2 |
| R6 | LIG-32 | Recording settings section + lazy permissions (`PermissionKind` microphone / camera / inputMonitoring) | 19, 40, 41 | R1 | Parallel with R2; other tickets add their rows |
| R7 | LIG-33 | Microphone audio: device picker, level meter, muted / disconnected handling, volume, mono | 20, 23, 24, 25 | R4, R6 | `AudioInputService`; AVCaptureSession in app target |
| R8 | LIG-34 | Computer audio via ScreenCaptureKit + single/separate tracks | 21, 22, 25 | R7 | Track layout decided here |
| R9 | LIG-35 | Webcam overlay: device, size, shape, mirror, drag, click-to-fullscreen, composited into frames | 26, 27, 28 | R4, R6 | `CameraService`; frame compositor introduced here or in R10, whichever lands first |
| R10 | LIG-36 | Click highlighting: `InputEventSource`, style / size / colour / animate, cursor show/hide, preview in settings | 19, 29 | R4, R6 | Parallel with R7–R9 |
| R11 | LIG-37 | Keystroke overlay: all keys / command-only, position, size, appearance, blur backdrop, password-field suppression | 30, 31 | R10 | Needs Input Monitoring; secure-input detection |
| R12 | LIG-38 | Post-recording overlay + after-recording actions + drag-out + Quick Look | 32, 33, 34 | R2 | Parallel with R3–R5 |
| R13 | LIG-39 | GIF recording: `GIFEncoder` (FPS, quality, max width, optimise), progress popup, cancel-to-video | 37, 38 | R4, R12 | Pure frame-plan + in-process encoder |
| R14 | LIG-40 | Video editor: trim, dimensions, quality, audio (mute / volume / mono / remove), estimated size, save-as-new / replace / revert | 35, 36 | R12 | Pure `TrimRange` + estimator; AVFoundation export |
| R15 | LIG-41 | Recordings in local history: `kind`, first-frame thumbnail, reopen / reveal / delete / retention; Spec 0005 menu row | 39 | R12 | Backward-compatible index |

Dependency spine: **R1 → R2 → {R3 → R4 → {R7 → R8, R9, R10 → R11}, R5, R12 → {R13, R14, R15}}**, with R6 alongside R2.

## Open decisions (confirm before `ready-for-agent`)

1. **Default hotkey for Record Screen** — proposal: none (rebindable), matching `window` / `repeatLast`. Alternative: ⌘⇧R, the only third-party claim for CleanShot's default.
2. **Encoders offered** — proposal: H.264 default, HEVC optional; FPS choices 10 / 15 / 30 / 60; max resolution Original / 1080p / 720p.
3. **GIF optimisation** — proposal: in-process (ImageIO + frame differencing), no bundled gifsicle; accept somewhat larger GIFs than CleanShot.
4. **Where the frame compositor lives** — proposal: app target, `RecordingCompositor`, fed by pure overlay *models* (positions, styles) from `LightshotKit` so layout math is testable.
5. **Crash recovery** — proposal: write fragmented MP4 (`movieFragmentInterval`) so a partial file is playable; skip if it constrains encoders.
