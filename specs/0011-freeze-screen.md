# Spec 0011 — Freeze Screen

**Status:** implemented — see *As built* at the end for where the build refined a decision
**Linear:** [LIG-69](https://linear.app/light-shot/issue/LIG-69) (label `ready-for-agent`)
**Platform:** Native macOS (Swift / AppKit + SwiftUI), macOS 14+
**Scope:** Local-only. When I start Capture Area, Capture Window or OCR Text, the screen freezes: the selection overlay shows a still of the screen taken the moment I triggered it, and what I get is what that still shows. It is always on, with no setting. It adds one method to `CaptureService`, a frozen-backdrop parameter to two `OverlayController` methods, and one pure crop in the domain core. Fullscreen capture and recording are unchanged.

Vocabulary used here is defined in [`CONTEXT.md`](../CONTEXT.md). New terms (**frozen screen**, **freeze**) are defined under *Further Notes*.

Parity reference: CleanShot X's **Freeze screen**. Its bundle has a `FreezerController` / `Freezer`, a `freezeScreenButton`, and a `freezeScreen` preference. CleanShot makes it optional. Lightshot always freezes (a user decision).

---

## Problem Statement

I trigger a screenshot or OCR Text because something is on screen right now: a hover tooltip, an open menu, a video frame, a notification banner, a progress state, a live-updating log. Today the selection overlay sits over the live screen. While I'm dragging, the video plays on, the log scrolls, and the tooltip or menu can vanish because the overlay takes focus. The capture fires only when I release the drag, so I get whatever the screen shows then, not what I wanted. I keep retrying, or I pause things by hand before I capture. For OCR Text this is worse: the text I wanted to copy has often scrolled away by the time I finish the drag.

## Solution

When I start Capture Area, Capture Window or OCR Text (from the menu, a hotkey, or Repeat Last Capture), Lightshot first takes one still of the screen and shows the selection overlay over that still, not over the live screen. Nothing under the overlay moves: the video, the menu, the tooltip and the cursor stay exactly as they were when I triggered it. I drag (or pick a window) on the frozen image. For an area, what I capture or OCR is cut out of that still, pixel for pixel. For a window, the picker shows the frozen screen, and the window I click is still captured on its own, cleanly, as today. Escape unfreezes and cancels with nothing captured. It always happens; there is no setting.

## User Stories

### Freezing on start

1. As a user, I want the screen to freeze the moment I start Capture Area, so that what I'm selecting doesn't change under me.
2. As a user, I want the screen to freeze the moment I start OCR Text, so that text scrolling in a log or chat is still there when I finish the drag.
3. As a user, I want the screen to freeze the moment I start Capture Window, so that the window picker shows a stable screen while I hover.
4. As a user, I want a playing video to stop on the frame showing when I triggered the capture, so that I can grab that exact frame.
5. As a user, I want an open menu or a hover tooltip to stay visible in the frozen screen even though the overlay has taken focus, so that I can capture transient UI.
6. As a user, I want a notification banner that was on screen when I triggered the capture to stay in the frozen screen, so that it doesn't slide away mid-drag.
7. As a user, I want the frozen screen to match the live screen exactly (same position, same scale, no shift or blur), so that freezing doesn't feel like a mode change, only a pause.
8. As a user, I want the overlay to appear just as quickly as it does today (no visible lag from freezing), so that capturing still feels instant.
9. As a user, I want freezing triggered from the hotkey, the menu-bar menu and Repeat Last Capture alike, so that it behaves the same however I start it.
10. As a user, I don't want Lightshot's own overlay, menu or notices in the frozen still, so that nothing of Lightshot's leaks into my capture.

### Selecting on the frozen screen

11. As a user, I want the dimming, the crosshair, the selection rectangle, the handles and the pixel-size readout to work exactly as they do today, so that nothing new has to be learned.
12. As a user, I want the live pointer to stay usable over the frozen screen, so that I can still drag and aim precisely.
13. As a user, I want the area inside my selection to show the frozen screen undimmed, so that I can see exactly what will be captured.
14. As a user, I want the window picker to highlight windows at the positions they had when I triggered it, so that the highlight lines up with the frozen image.

### What gets captured

15. As a user, I want Capture Area to produce the frozen pixels inside my selection, so that the result is what I saw while selecting.
16. As a user, I want the area result at full native (Retina) resolution, so that freezing costs no quality.
17. As a user, I want OCR Text to read the frozen pixels inside my selection, so that the copied text is the text I selected.
18. As a user, I want Capture Window to still give me just the clicked window, cleanly, with no overlapping windows and the shadow trimmed, so that window capture keeps its point.
19. As a user, I want a selection that runs past the screen edge clamped to the screen, as today, so that an overshoot never fails the capture.
20. As a user, I want the include-cursor setting honoured in the frozen still, so that the pointer appears in my area captures only when I asked for it.
21. As a user, I want area captures of the frozen screen to go to the editor or the post-capture toolbar, into history, and through Repeat Last Capture exactly as live captures do today, so that freezing changes only what is captured, not where it goes.
22. As a user, I want OCR Text on the frozen screen to keep its current behaviour (clipboard, notice, no editor, no history), so that only the source pixels change.

### Unfreezing

23. As a user, I want the screen to unfreeze the moment the overlay closes (confirm or Escape), so that I'm never left looking at a stale image.
24. As a user, I want Escape to unfreeze and do nothing else, with no capture, no clipboard change and no notice, so that cancelling stays harmless.
25. As a user, I don't want the frozen still kept anywhere after the overlay closes (not on disk, not in history, not in memory), so that a capture I cancelled leaves no trace.

### Self-timer

26. As a user with a self-timer set, I want Capture Area to wait and then capture the live screen as it does today, so that the timer still lets me set up UI after choosing the area. (A still taken before the timer would defeat the point of the timer.)
27. As a user with a self-timer set, I want Capture Window to show the frozen picker, wait, then capture the window live, so that window capture behaves as it does today apart from the frozen backdrop.

### Permissions and edge cases

28. As a first-time user, I want the Screen Recording permission prompt to come before any freeze, as it does today, so that I'm not frozen behind a system prompt.
29. As a user without the Screen Recording grant, I want triggering a capture to go straight to the permission recovery path, with no overlay and no blank frozen screen, so that I can fix the grant.
30. As a user, if the still can't be taken for any other reason, I want the usual capture-failure message with no overlay, so that I never select over a blank or black screen.
31. As a user, I want OCR Text still ignored while a recording is active, with no freeze, so that nothing flickers over my take.
32. As a user on a multi-monitor setup, I want the display the overlay covers (the main display, as today) to be the one that freezes, so that the frozen image and the overlay are on the same screen.
33. As a user, if I trigger a new capture while an overlay is already up, I want the old one to cancel cleanly and the new one to freeze afresh, so that I never see a stale still.
34. As a user, I want a window that closed between my trigger and my click to fail with the existing "no longer available" message, so that I never get a blank window capture.

## Implementation Decisions

### Modules

- **`AppCoordinator` (existing seam, no new use case).** It stays the main test seam. `captureArea()`, `captureWindow()` and `captureText()` each gain one step, right after first-run permission onboarding and before the overlay: ask `CaptureService.freezeScreen()` for a **frozen screen**. On success, pass it to the overlay. On failure, route exactly as a capture failure (`permissionDenied` goes to `presentPermissionDenied(.screenRecording)`, `userCancelled` is silent, the rest go to `presentCaptureFailure`) and never show the overlay.
  - **Area** (`captureArea()` with no self-timer, and `captureText()`): the result is the **pure crop** of the frozen screen to the chosen region. `CaptureService.captureRegion(_:)` is **not** called. A crop that comes out empty routes to `presentCaptureFailure`, never a blank image.
  - **Area with a self-timer** (`captureDelay` > 0): no freeze. The overlay runs over the live screen as today, then the delay, then `captureRegion(_:)` live. This is the only unfrozen screenshot path.
  - **Window** (`captureWindow()`): freeze, then `selectWindow(over:)`, then the self-timer if set, then `captureRegion(.window…)` live, as today. The frozen screen is only the picker's backdrop.
  - Everything downstream (history, editor vs. toolbar, Repeat Last Capture memory, OCR status notices) is unchanged.
- **`FrozenScreen` (new value type, domain core).** One still of a display: the display id (`UInt32`, like `CaptureRegion.display`), the display's frame in screen points (top-left origin), and the still as a `CapturedImage` at native pixels. The point→pixel scale is derived from the image and frame sizes, not stored separately, so the two can't disagree.
- **Pure crop (new, domain core, CoreGraphics/ImageIO only, as `render` already uses).** A function on `FrozenScreen` taking a `CaptureRegion` and returning `CapturedImage?`:
  - `.rect`: standardise, subtract the display's origin, scale to pixels (floor the origin, round the size, the same rounding `SCCaptureService`'s rect path uses today), intersect with the image bounds, crop, encode as PNG.
  - `nil` when the intersection is empty, or for `.window` / `.display`, which the coordinator never passes.
  - It's deliberately the same math as the live rect path, so a frozen area and a live area of the same rect give identical pixel sizes.
- **`CaptureService.freezeScreen() async -> Result<FrozenScreen, CaptureError>` (existing seam, one new method).** The concrete ScreenCaptureKit version grabs the display the overlay covers (the main display, as `OverlaySelectionController` resolves it today) with `SCScreenshotManager`, honouring `includeCursor`. It reuses the existing shareable-content query, error mapping and PNG encoding. It must run **before** any Lightshot overlay window exists, so none of our windows can be in the still. No deprecated `CGWindowListCreateImage`.
- **`OverlayController` (existing seam, changed signatures).** `selectRegion()` becomes `selectRegion(over frozen: FrozenScreen?)` and `selectWindow()` becomes `selectWindow(over frozen: FrozenScreen?)`. `nil` means the live screen (the self-timer area path). `selectRecording` is unchanged.
  - The concrete overlay draws the frozen still as an opaque, full-bleed backdrop at the window's exact frame, under the existing dimming and selection chrome. Inside the selection it shows the still undimmed. The overlay window is already screen-saver level, so live changes underneath are hidden.
  - The still is decoded once, when the overlay is presented, not per frame.
  - The window picker's hover list is still enumerated before the overlay appears (as today), which is also the moment of the freeze, so highlight frames line up with the backdrop.
- **Lifetime.** The frozen screen is a local in the coordinator's use case. It's dropped when the use case returns, never stored on the coordinator, written to disk, or recorded in history.

### Routing (area and OCR Text, no self-timer)

1. First-run permission onboarding, unchanged.
2. `freezeScreen()`. A failure routes as a capture failure, with no overlay.
3. `selectRegion(over: frozen)`. `nil` means a silent no-op: no crop, no capture call, no UI.
4. Crop. `nil` goes to `presentCaptureFailure`. Otherwise the image continues exactly as a successful live `captureRegion` result does today.

### Settings

- None. Freezing is always on (a user decision). Nothing is added to `SettingsStore` or the Settings window.

## Testing Decisions

- **What makes a good test here:** assert what the user would observe through the coordinator's fakes. Which image reached the editor, toolbar, history or text recogniser. Whether the overlay was shown, and with which backdrop. Whether a live capture happened at all. Which error UI appeared. Don't assert ScreenCaptureKit configuration or how the overlay draws. No test touches a screen or a permission.
- **`AppCoordinator` (primary seam), Swift Testing, extending the existing fakes.** The stub capture service gains a canned `freezeScreen()` result and a count of `captureRegion` calls. The stub overlay records the `FrozenScreen?` it was given.
  - Area: `freezeScreen` runs before the overlay. The overlay receives that frozen screen. The editor (or toolbar) receives the crop of it, and `captureRegion` is never called. History records the cropped image.
  - Area: a cancelled overlay produces no capture call, no editor and no history entry.
  - Area: `freezeScreen` returning `permissionDenied` goes to the Screen Recording recovery path, and the overlay is never shown. `systemFailure` goes to `presentCaptureFailure` with no overlay. `userCancelled` is silent.
  - Area: a region wholly outside the frozen screen goes to `presentCaptureFailure`, never the editor.
  - Area with `captureDelay` > 0: `freezeScreen` isn't called, the overlay gets `nil`, and `captureRegion` runs after the delay, as today.
  - OCR Text: the recogniser receives the crop of the frozen screen, `captureRegion` isn't called, and the existing copy / no-text / failure routing still holds. Freeze failures route as above. During an active recording, `freezeScreen` isn't called.
  - Window: the overlay receives the frozen screen, then `captureRegion(.window…)` runs live (after the self-timer if set), and the result routes as today.
  - Repeat Last Capture of an area freezes again (a fresh `freezeScreen` call per run).
  - Fullscreen never calls `freezeScreen`.
- **Pure crop (`FrozenScreen`), Swift Testing, with generated images.** Build a still with CoreGraphics (a known colour per quadrant) at scale 2.
  - A rect over one quadrant gives that colour and the expected pixel size.
  - A reversed (negative-size) rect is standardised.
  - A rect overshooting the edge is clamped.
  - A rect entirely outside gives `nil`.
  - A display frame with a non-zero origin is offset correctly.
  - `.window` / `.display` give `nil`.
  - For the same rect, the pixel size matches what the live rect path's rounding gives.
- **Prior art:**
  - `AppCoordinatorTests` has the stub capture service, overlay, UI, sink and delay spy that all extend here, and the area/OCR routing tests to mirror.
  - `TextCaptureTests` covers OCR routing.
  - `DocumentRenderTests` / `ExportTests` generate CoreGraphics images and inspect pixels in the domain test target.
- **App side (no unit-test target in `App/`):** verify by hand with the isolated `.verify` Debug build:
  - Start Capture Area over a playing video and confirm the frame in the editor is the trigger frame.
  - Open a menu, trigger Capture Area by hotkey, and confirm the open menu is in the capture.
  - Run OCR Text over a scrolling log.
  - Run Capture Window over overlapping windows and confirm a clean window.
  - Confirm there's no visible shift between the frozen backdrop and the live screen on a Retina display, and that no Lightshot window appears in any still.
  - Record before/after captures in the PR.

## Out of Scope

- A setting or toggle to turn freezing off. It is always on.
- Freezing fullscreen capture (it fires with no overlay, so there's nothing to freeze).
- Freezing the recording overlay or anything in recording or the Studio.
- Capturing a window's pixels from the frozen still (window capture stays a live, clean window capture).
- Freezing displays other than the one the overlay covers. Multi-display overlays are a separate piece of work.
- Freezing during the self-timer path of Capture Area.
- Magnifier / loupe improvements over the frozen image.
- Any change to the post-capture toolbar, the editor, history or OCR text assembly.

## Further Notes

- **Glossary additions** (add to `CONTEXT.md`):
  - **Frozen screen:** one still of a display, taken when a capture or OCR Text starts. The selection overlay shows it as its backdrop, and area results are cut from it. Never stored. _Avoid_: snapshot, freeze-frame image.
  - **Freeze:** taking the frozen screen and showing it under the overlay. _Avoid_: pause, lock.
- **Why the crop lives in the domain core.** "What you selected on the frozen screen is exactly what you get" is the behaviour worth testing, and it's pure geometry over an image, like `render`. Keeping it out of `SCCaptureService` makes it testable without a screen, and it stops a frozen area and a live area drifting apart in rounding.
- **Why window capture stays live.** Cropping the window's frame from the still would include whatever overlaps it and the desktop behind its shadow, which is the opposite of what Capture Window is for. The freeze still makes the picker stable. The trade-off is that a window whose content changes between the trigger and the click is captured as it is at the click. That's accepted, since window captures are rarely of transient content.
- **Why the self-timer area path skips the freeze.** The self-timer runs after the selection so I can open a menu or hover something before the shot. A still taken before the selection would make the timer do nothing.
- **Cursor in the backdrop.** With include-cursor on, the frozen pointer appears in the backdrop next to the live crosshair. That's accepted: the backdrop shows exactly what the capture will contain.
- **Performance.** One display grab adds roughly tens of milliseconds before the overlay appears. That's within "instant". If verification shows a visible delay, measure it and note it under *As built* rather than dropping the freeze.
- **Memory.** A 5K still is about 60 MB decoded. It's held only while the overlay is up and released when the use case returns.

## As built

- **The still is uncompressed TIFF, not PNG.** Measured offline on this machine: a PNG encode of a full-display still took 88 ms at 2940 × 1912 and 157 ms at 5120 × 2880. The backdrop's decode added 36–69 ms, so the overlay would have appeared up to ~225 ms late. Uncompressed TIFF took 6–13 ms to encode and 4–7 ms to decode. `FrozenScreen` accepts any ImageIO-readable still, and the area cut from it is still PNG.
- **Which display freezes.** `SCCaptureService.freezeScreen()` grabs `NSScreen.main`, the screen the overlay covers. The live rect path still grabs the first shareable display. The two are the same on a single display.
- **Backdrop.** The overlay's content view is a layer-backed container whose layer draws the still, with the SwiftUI overlay as a subview above it.
- **DEBUG preview.** `-previewSurface frozenArea|frozenWindow -previewFile <png>` opens the area or window overlay over a still loaded from a file. It needs no Screen Recording grant.
