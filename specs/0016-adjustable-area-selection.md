# Spec 0016 — Adjust the area before capturing

**Status:** implemented — see *As built* at the end
**Linear:** [LIG-76](https://linear.app/light-shot/issue/LIG-76) (label `ready-for-agent`)
**Platform:** Native macOS (Swift / AppKit + SwiftUI), macOS 14+
**Scope:** Local-only. A new setting, **Adjust the area before capturing** (Settings → Screenshots → Capture), is off by default. When it's on, releasing the Capture Area drag doesn't take the screenshot. The selection stays editable: I can move it, resize it from its handles, nudge it with the arrow keys, or drag out a different area. A **Capture** button at the selection (or Return) takes the screenshot. When it's off, Capture Area behaves exactly as it does today. OCR Text, Capture Window, fullscreen capture and recording are unchanged. The change adds one `SettingsStore` property and one argument to `OverlayController.selectRegion`. The selection geometry reuses the domain's `EditableSelection`, which the recording overlay already uses.

Vocabulary used here is defined in [`CONTEXT.md`](../CONTEXT.md). The new term (**adjustable selection**) is defined under *Further Notes*.

Parity reference: macOS's own Screenshot toolbar (⇧⌘5). Its selection stays up after the drag, can be moved and resized, and is captured with a Capture button. CleanShot X has no matching preference: its bundle shows only `crosshairMode`, which is a different thing. The interaction details below (button placement, click versus drag, cursors) are judgment calls modelled on Lightshot's own recording overlay (spec 0006).

---

## Problem Statement

Capture Area takes the screenshot the moment I release the mouse. That's fast when my drag is right, but my drag is often slightly off. An edge clips a word, the area sits a few pixels too far left, or I started in the wrong place. I can't fix it. I have to finish the capture, throw it away or crop it in the editor, and start over. When the frozen screen held something transient, such as a menu, a tooltip or a video frame, starting over may lose it. I'd like to place the area precisely before anything is captured, but I don't want everyone's quick one-gesture capture to become slower.

## Solution

Settings → Screenshots gets a toggle, **Adjust the area before capturing**, off by default. With it off, nothing changes: drag, release, captured.

With it on, I drag an area as usual, but releasing the mouse leaves the area on screen with handles at its corners and edges, its live pixel readout, and a **Capture** button next to it. The screen stays frozen the whole time. I can drag inside the area to move it, drag a handle to resize it, nudge it with the arrow keys, or drag anywhere outside it to draw a different area instead. A click that doesn't drag leaves the area alone. When it's right, I click **Capture** or press Return, and the screenshot is that area of the frozen screen. It then goes to the editor or a Quick Access card, exactly as today. Escape cancels with nothing captured. The setting applies everywhere Capture Area runs: the menu, the hotkey, Repeat Last Capture and the self-timer. With a self-timer, the countdown starts when I click Capture.

## User Stories

### The setting

1. As a user, I want Capture Area to keep capturing the moment I release the drag unless I opt in, so that my existing one-gesture habit is untouched after updating.
2. As a user, I want a toggle in Settings → Screenshots → Capture called "Adjust the area before capturing", so that I can opt in to placing the area before it's captured.
3. As a user, I want the toggle to be off on a fresh install and after updating from an earlier version, so that nothing changes unless I ask for it.
4. As a user, I want the toggle's help text to explain that I confirm with the Capture button or Return, so that I understand why the screenshot didn't fire on release.
5. As a user, I want the setting to persist across relaunches, so that I set it once.
6. As a user, I want a change to the setting to take effect on my next Capture Area without a restart, so that I can try it straight away.

### Releasing the drag

7. As a user with the setting on, I want releasing the drag to leave the area selected instead of capturing it, so that I can check it before anything is taken.
8. As a user with the setting on, I want the area to stay undimmed with its border, handles and pixel readout after I release, so that I can see exactly what will be captured.
9. As a user with the setting on, I want the screen to stay frozen while I adjust, so that the menu, tooltip or video frame I'm capturing doesn't change.
10. As a user with the setting on, I want a release too small to be a real area (a stray click before any area exists) to leave the overlay waiting for a drag, as it does today, so that a slip doesn't capture a few pixels or leave behind a useless area.

### Moving the area

11. As a user, I want to drag inside the selected area to move it, so that I can fix where it sits without redrawing it.
12. As a user, I want a moved area to keep its size, so that only its position changes.
13. As a user, I want a moved area to stop at the edges of its display, so that it never extends off-screen.
14. As a user, I want the arrow keys to nudge the area by one pixel, so that I can place it precisely.
15. As a user, I want ⇧-arrow keys to grow or shrink the area from its top-left corner, so that I can fine-tune its size without the mouse.

### Resizing the area

16. As a user, I want handles at the corners and edge midpoints of the area, so that I can resize it after the drag.
17. As a user, I want dragging a corner handle to keep the opposite corner fixed, so that resizing behaves predictably.
18. As a user, I want dragging an edge handle to move only that edge, so that I can extend the area in one direction.
19. As a user, I want resizing to stop at the display's edges, so that the area never extends off-screen.
20. As a user, I want the pixel readout to update live while I move or resize, so that I can hit an exact size.
21. As a user, I want the handles to look like the recording overlay's and the editor crop's, so that Lightshot's selection chrome is consistent.

### Selecting a different area

22. As a user, I want dragging anywhere outside the selected area to draw a new area that replaces it, so that I can start over without cancelling.
23. As a user, I want a click outside the area that doesn't drag to leave the area as it is, so that a stray click doesn't throw away my adjustments.
24. As a user with several displays, I want drawing on another display to replace the area on the first one, so that there is only ever one area to capture.
25. As a user with several displays, I want the area to stay on the display I drew it on when I move it, so that a capture never straddles two displays (as today).

### Capturing

26. As a user, I want a Capture button next to the selected area, so that I can take the screenshot when the area is right.
27. As a user, I want the Capture button below the area, or above it when there's no room below, and never off-screen, so that it's always reachable without covering what I'm capturing.
28. As a user, I want Return to do the same as the Capture button, so that I can confirm from the keyboard.
29. As a user, I want Return to capture the selected area whichever display the pointer is on, so that confirming always works.
30. As a user, I want the Capture button hidden while I'm dragging, so that it doesn't jump around mid-gesture.
31. As a user, I want the screenshot to be exactly the selected area of the frozen screen, pixel for pixel, so that what I adjusted is what I get.
32. As a user, I want the screenshot to go to the editor or a Quick Access card according to After Capture, exactly as today, so that the rest of my workflow is unchanged.
33. As a user, I want the capture to land in history exactly as a normal Capture Area does, so that nothing downstream can tell the difference.

### Cancelling

34. As a user, I want Escape to cancel at any point, before or after I release the drag, with nothing captured, so that I can always back out.
35. As a user, I want cancelling to unfreeze the screen and remove every overlay, as today, so that I'm back where I started.

### Pointer

36. As a user, I want a crosshair outside the area, an open hand inside it, a closed hand while moving it, a resize cursor over a handle, and an arrow over the Capture button, so that I can tell what a drag will do before I start it.

### Every way Capture Area runs

37. As a user with the setting on, I want the Capture Area hotkey and menu item to use the adjustable selection, so that it behaves the same however I start it.
38. As a user with the setting on, I want Repeat Last Capture after a Capture Area to use the adjustable selection too, so that repeating behaves like the original.
39. As a user with the setting on and a self-timer set, I want to adjust the area over the live screen and start the countdown only when I click Capture, so that the timer still gives me time to set up transient UI after I've placed the area.

### What stays the same

40. As a user with the setting off, I want Capture Area to behave exactly as today: no handles, no Capture button, captured on release, so that the default experience is untouched.
41. As a user, I want OCR Text to keep copying the moment I release the drag whatever this setting says, so that quick text grabs stay one gesture.
42. As a user, I want Capture Window, fullscreen capture and recording to be unaffected by this setting, so that it only changes the one thing it names.

## Implementation Decisions

### Seam

- **One seam, already in place: `OverlayController.selectRegion`.** It gains an `adjustable` argument (a `Bool`). `false` is today's release-to-capture overlay; `true` is the adjustable selection. No new protocol and no new service.
- **The coordinator decides the mode, not the overlay.** `AppCoordinator.captureArea()` reads the new setting live at the start of each run and passes it on both of its paths: the frozen path and the self-timer (live) path. OCR Text (`captureText()`, through the shared frozen-area helper) always passes `false`. Because the frozen-area helper is shared, it takes the mode as a parameter. This keeps "setting off behaves as today" and "OCR Text is unaffected" as coordinator facts that `swift test` can check.
- **Nothing after the overlay changes.** `selectRegion` still resolves to `.rect` in global top-left screen points, or `nil` on Escape. The coordinator still cuts the region from the frozen screen (or captures it live after the self-timer), records history and calls `presentCapture`. The adjustable selection is purely a different way of producing the same `CaptureRegion`.

### Settings

- `SettingsStore` gains `adjustAreaBeforeCapture: Bool`, default `false`. The concrete store persists it in `UserDefaults`. A missing key reads as `false`, so existing installs keep today's behavior.
- `SettingsModel` mirrors it, writing through on change like its other toggles.
- Settings → Screenshots → **Capture** section gets a `Toggle("Adjust the area before capturing")` under "Include the mouse cursor". Its `.help`: "After you drag, move or resize the area, then click Capture or press Return."

### Overlay (app target)

- **Geometry is the domain's `EditableSelection`, unchanged.** It already draws, moves, resizes from eight handles, nudges and ⇧-resizes with arrow keys, and clamps everything to its display's bounds, with tests. The adjustable mode always uses the freeform ratio. The Option-key square lock and ratio presets are not exposed (see *Out of Scope*).
- **A separate `AdjustableSelectionOverlayModel` beside `SelectionOverlayModel`.** The release-to-capture model and view stay exactly as they are: no threshold, no handles, no button. With `adjustable == true` the controller uses the new model instead, which wraps an `EditableSelection` per display, the way `RecordingOverlayModel` does:
  - **Click versus drag:** `dragBegan` is deferred until the pointer has moved past a small threshold, as in `RecordingOverlayModel`. A click that never crosses it changes nothing (story 23). A first-ever click with no area behaves as today (story 10). A redraw too small to be an area puts the previous area back.
  - **Arrow keys:** move by 1 px; ⇧ grows or shrinks from the top-left by 10 px, as in the recording overlay.
  - **Confirm:** resolves `.rect` with the current selection, standardized. It's a no-op with no selection or mid-drag.
  - **Cursor:** reuse the app-side `PointerCursor` and the same hit-testing (`dragKind(at:)`) the recording overlay uses.
- **`AdjustableSelectionOverlayView`** (beside `SelectionOverlayView`) draws the selection chrome with `OverlayCanvas.drawSelectionChrome` (hidden mid-drag), keeps the existing readout, and lays a **Capture** button over the canvas, as `RecordingOverlayView` lays its toolbar. Placement: centred under the selection, flipped above it when there's no room below, inside its bottom edge when neither fits, clamped horizontally to the display. It never overlaps the readout pill: when both would sit below, the button goes under the readout. The button is shown only when a selection exists and no drag is in progress. It uses the existing toolbar control styling (`toolbarPanel` / `toolbarControl`) so it matches the recorder toolbar in Light and Dark.
- **`OverlaySelectionController.presentRectOverlay`** owns the cross-display rules in adjustable mode:
  - When a drag begins drawing on one display, every other display's selection is cleared (story 24).
  - Return (`onConfirm`) on any window confirms whichever display holds the selection (story 29).
  - Arrow keys (`onArrow`) go to that display's model.
  - Escape on any window cancels.
  - The adjustable view is hosted in a `FirstMouseHostingView` (`acceptsFirstMouse` is `true`), so the first drag into another display's overlay window draws at once instead of only making that window key.

  In release-to-capture mode, the per-window wiring stays as it is today.

### Coordinates

- Unchanged. Each display's model works in that display's local screen points (1:1 with its window). The controller shifts the confirmed rect into global top-left points, exactly as it does today.

## Testing Decisions

- **What makes a good test:** assert observable behavior at the seam: which mode the coordinator asks the overlay for, and what it does with the region it gets back. Selection geometry is checked through `EditableSelection`'s public API. Windows, buttons, cursors and multi-display key routing are checked by hand. No test reaches into a model's private state.
- **`AppCoordinator` (`AppCoordinatorTests`):**
  - `StubOverlay` records the `adjustable` argument per `selectRegion` call, as it already records `backdrops`. `StubSettings` gains the property (in `RecordingCoordinatorTests` too, so both stubs still conform).
  - Setting off: Capture Area asks for `adjustable == false` over the frozen screen, and the existing area tests keep passing unchanged.
  - Setting on: Capture Area asks for `adjustable == true` over the frozen screen. The returned region is cut from the frozen screen, recorded in history and presented exactly as with the setting off (same image, same `presentCapture` routing).
  - Setting on, with a self-timer: the live path asks for `adjustable == true` over no backdrop, and the delay and live capture still follow.
  - Setting on, Repeat Last Capture after an area capture: asks for `adjustable == true`.
  - Setting on, OCR Text: asks for `adjustable == false`.
  - Setting on, cancel (`nil`): no capture, no history, no presentation, as today.
- **`EditableSelection` (`EditableSelectionTests`):** the behaviors this spec relies on are already covered: draw, move, handle resize, nudge and ⇧-resize, clamping, and `dragKind(at:)` choosing draw outside the selection. Add one test only if it's missing: a draw that begins outside an existing selection replaces it with the new rect.
- **Prior art:** the existing `StubOverlay` / `backdrops` assertions from spec 0011, and the `openInEditor` routing tests from spec 0014.
- **App side (manual, `.verify` Debug build):**
  - Use the existing DEBUG `-previewSurface frozenArea` surface with the setting on and off. That surface calls `selectRegion` directly, not through the coordinator, so it must pass the stored setting as `adjustable`.
  - With the setting off, confirm release still captures immediately with no handles or button.
  - With it on, check: release keeps the area; move, resize, arrow-nudge and redraw; a stray click outside keeps the area; Capture and Return both capture the adjusted area; Escape cancels; the button flips above the area at the bottom of the screen; cursors; Light and Dark.
  - With two displays, drawing on the second clears the first, and Return captures from either.
  - Check a self-timer run: the countdown starts at Capture.
  - Check OCR Text still copies on release with the setting on.

## Out of Scope

- Applying the adjustable selection to OCR Text (a user decision; OCR stays one gesture).
- Aspect-ratio presets, the ⌥ square lock, and typed width/height fields for the screenshot area. The recording overlay has these; the screenshot area doesn't gain them here.
- Double-click inside the area to capture, and any capture actions beyond the single Capture button (copy, save, annotate directly from the overlay).
- Remembering the last screenshot area between runs (the recording overlay's "remember last area" is not extended to screenshots).
- Snapping the area to a window while adjusting, and moving an area across displays.
- Any change to Capture Window, fullscreen capture or recording.

## Further Notes

- **Glossary addition** (`CONTEXT.md`, under a Capture Area heading or beside *Freeze Screen*):
  - **Adjustable selection:** a Capture Area selection that stays editable after the drag (move, resize, nudge, redraw) until Capture or Return takes it. Used only when *Adjust the area before capturing* is on. _Avoid_: edit mode, selection-editing mode ("editor" already means the annotation editor).
- **Why a mode argument rather than the overlay reading Settings.** It keeps the overlay a pure "resolve a region" step and puts the choice where `swift test` can see it. That's the only way to check "off behaves exactly as today" and "OCR Text is unaffected" without a window server.
- **Why handles are in.** `EditableSelection.dragKind(at:)` returns a resize near a handle, so leaving resize out would take extra code that fights the shared geometry. Including handles also matches the recording overlay and the editor crop.
- **Why the default is off.** Capture-on-release (LIG-23) was a deliberate speed decision. This spec adds precision as an opt-in, not a replacement.

## As built

- **Verified in the `.verify` Debug build** with `-previewSurface frozenArea -previewFile <png>` over a synthetic backdrop, on a 2560 × 1440 main display plus a Retina display below it. Input was driven with `CGEvent`. The preview now logs the region it resolves.
  - **Setting off:** a drag resolved `.rect(500, 300, 400 × 300)` on release and the overlays closed, as before.
  - **Setting on:** the same drag left the area up with handles, the `400 × 300` readout and the Capture button below it, and resolved nothing. Then:
    - a move of (+100, +50);
    - a click outside (no change);
    - → (x + 1);
    - ⇧↓ (height + 10);
    - a bottom-right handle drag of (+100, +50);
    - Return.

    Return resolved exactly `.rect(601, 350, 500 × 360)`.
  - **Button placement:** for an area at the bottom of the screen, the button flipped above the area and above its readout. For a full-display area, it sat inside the bottom edge.
  - **Several displays:** an area drawn on the main display was cleared by a drag on the second display. Return pressed with the main display's window key resolved the second display's area in global points: `.rect(800, 1600, 400 × 300)`.
  - **Other checks:**
    - A click with nothing selected left the screen dimmed and resolved nothing.
    - Escape resolved `nil`.
    - Clicking the Capture button resolved the area.
    - Dark appearance (`-previewAppearance dark`) looked right.
    - Settings → Screenshots → Capture shows the toggle.
- **Bug caught by that check:** at first, the first drag into another display's overlay window was swallowed, because it only made that window key. That window then kept no area, so Return captured the first display's old area. `FirstMouseHostingView` fixes it. The release-to-capture overlay is left as it was.
- **Tests:** seven `AppCoordinator` tests cover the setting off and on, the self-timer, Repeat Last Capture, reading the setting live, cancelling, and OCR Text staying on release. One `EditableSelection` test covers a draw outside an existing area replacing it.
