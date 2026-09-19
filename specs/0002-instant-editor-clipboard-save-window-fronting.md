# Spec 0002 — Instant Editor, ⌘S-to-Clipboard, Window Fronting

**Status:** ready-for-agent
**Linear:** [LIG-23](https://linear.app/light-shot/issue/LIG-23/instant-editor-on-selection-release-s-copies-to-clipboard-windows-open)
**Platform:** Native macOS (Swift / SwiftUI), macOS 14+ (ScreenCaptureKit)
**Scope:** Local-only. Three capture-flow polish changes on top of Spec 0001. No new features, no new seams.

---

## Problem Statement

Using Lightshot day to day, three things break my flow:

1. **Selecting an area doesn't get me to the editor.** After I drag out an area,
   nothing happens until I press Return — and then I get a small toolbar at the
   selection rather than the editor. I almost always want to annotate, so that
   is two extra steps on every single capture.
2. **⌘S does the wrong thing.** In the editor, ⌘S writes a file and throws a
   Finder window in my face. What I actually do with nearly every screenshot is
   paste it somewhere. I want ⌘S to mean "I'm done — put it on my clipboard" and
   get out of my way, without Finder ever appearing.
3. **Windows open behind other apps.** When I pick an item from the menu-bar
   menu — Settings… most reliably — the window does open, but underneath
   whatever app I was using. I have to go hunting for it. Because Lightshot has
   no Dock icon, a buried window is genuinely hard to find.

## Solution

1. **Mouse-up confirms, and the capture opens straight in the editor.** I drag
   an area and release: the capture is taken and the annotation editor opens
   with it immediately. Clicking a window in window-capture mode does the same.
   The post-capture toolbar still exists, but only for people who turn off the
   existing **"Open captures in the editor"** setting (on by default) — that
   setting finally does what its label says.
2. **⌘S copies the finished image to the clipboard and closes the editor.** No
   file is written and Finder never opens. ⌘C still copies and leaves the editor
   open; ⇧⌘S is still Save As…; the toolbar's Save button still saves to disk.
   On a pinned screenshot ⌘S copies too (the pin stays up).
3. **Every window Lightshot opens comes to the front.** Settings, History, the
   permission checklist, the editor, and Lightshot's dialogs all appear above
   the app I was using, focused and ready for input — including when the window
   was already open but buried.

## User Stories

### Selection → editor

1. As a user, I want releasing the mouse after dragging an area to confirm the selection, so that I don't have to press Return on every capture.
2. As a user, I want the area capture to open in the annotation editor as soon as I release the mouse, so that I can start annotating immediately.
3. As a user, I want clicking a window in window-capture mode to open that capture straight in the editor, so that area and window capture behave the same way.
4. As a user, I want to still see the live pixel-size readout while dragging, so that I can size the area precisely before I let go.
5. As a user, I want Escape to cancel the selection at any time before I release the mouse, so that I can back out with no capture and no side effects.
6. As a user, I want a plain click (or a drag too small to be a real selection) to not capture anything and leave the overlay up, so that a stray click doesn't produce a useless 1-pixel screenshot.
7. As a user, I want the self-timer, when set, to still count down after I release the mouse and before the shot is taken, so that delayed captures keep working.
8. As a user, I want the selection overlay to be fully gone before the shot is taken, so that the dimming and selection chrome never appear in my capture.
9. As a user, I want the editor to come up focused and in front after a capture, so that my next keystroke or click lands in it.
10. As a user, I want "Repeat Last Capture" for area/window to follow the same release-to-editor flow, so that repeat behaves like the original.
11. As a user who prefers the quick toolbar, I want turning off "Open captures in the editor" in Settings to bring back the post-capture toolbar at the selection, so that I can still copy/pin/discard without opening the editor.
12. As a user with the setting off, I want the toolbar's Annotate action to still open the editor, so that the editor is one click away.
13. As a user, I want the setting to apply to both area and window capture, so that the behavior is predictable.
14. As a user, I want the setting to take effect on the very next capture without restarting, so that I can try both modes easily.
15. As a user, I want fullscreen capture and Open Image… to keep opening the editor directly as they do today, so that nothing I rely on changes.
16. As a user, I want each capture to still be recorded in History regardless of whether it went to the editor or the toolbar, so that I can always get it back.
17. As a user, I want a denied Screen Recording permission to still route to the recovery path rather than an empty editor, so that a permission problem is never disguised as a blank capture.
18. As a user, I want a capture failure to still show the failure alert rather than the editor, so that errors remain visible.

### ⌘S → clipboard

19. As a user, I want ⌘S in the editor to copy the flattened, annotated image to the clipboard, so that I can paste it immediately.
20. As a user, I want ⌘S to close the editor after copying, so that one shortcut means "done" and I'm back in the app I was working in.
21. As a user, I want ⌘S to never open Finder or a save dialog, so that finishing a screenshot doesn't interrupt me.
22. As a user, I want ⌘S to not write any file to disk, so that my Desktop doesn't fill up with screenshots I only wanted to paste.
23. As a user, I want the copied image to include all my annotations and respect the crop, so that what I paste is exactly what I saw in the editor.
24. As a user, I want blackout redactions to be burned into the copied image, so that ⌘S is as safe for secrets as any other export.
25. As a user, I want ⌘C to keep copying while leaving the editor open, so that I can copy, keep editing, and copy again.
26. As a user, I want ⇧⌘S to remain Save As… with the location/name/format panel, so that I can still save a file on purpose.
27. As a user, I want the editor toolbar's Save-to-disk button to keep working by click, so that default-location saving is still available — it just no longer owns ⌘S.
28. As a user, I want the editor's button tooltips to show the new shortcuts accurately, so that the UI doesn't lie about what ⌘S does.
29. As a user, I want ⌘S on a focused pinned screenshot to copy it to the clipboard, so that the shortcut means the same thing everywhere in Lightshot.
30. As a user, I want a pinned screenshot to stay pinned after ⌘S, so that copying a reference image doesn't dismiss it.
31. As a user, I want the capture to remain in History after ⌘S closes the editor, so that closing on copy never loses the original.

### Window fronting

32. As a user, I want the Settings window to appear in front of all other apps when I choose Settings… from the menu, so that I don't have to hunt for it.
33. As a user, I want the Settings window to be key (focused) when it appears, so that I can interact with it immediately.
34. As a user, I want ⌘, from the Lightshot menu to keep opening Settings, so that the standard shortcut still works.
35. As a user, I want choosing Settings… while the Settings window is already open but buried to bring it to the front, so that re-selecting the item always finds the window.
36. As a user, I want History… to open in front and focused, so that it behaves like Settings.
37. As a user, I want Set Up Permissions… to open the checklist in front and focused, so that first-run and recovery flows are never hidden.
38. As a user, I want the editor to open in front and focused from every entry point (capture, toolbar Annotate, Open Image…, History re-open), so that the editor is never buried.
39. As a user, I want Lightshot's dialogs (Open Image…, Save As…, the save-location chooser, error and permission alerts) to appear in front, so that the app never seems hung behind a hidden modal.
40. As a user, I want a window that is already open but minimized or behind others to be restored to the front when I re-select its menu item, so that the menu is a reliable way back to it.
41. As a user, I want Lightshot's ordinary windows to front once when opened but not float permanently above other apps, so that I can still switch away from them normally. (Pinned screenshots, the selection overlay, and the post-capture toolbar keep their existing always-on-top levels.)
42. As a user, I want Lightshot to remain a menu-bar-only app with no Dock icon, so that fixing window fronting doesn't change the app's footprint.

## Implementation Decisions

### 1 — Selection → editor

- **Confirm on release.** In area selection, ending a drag that produced a valid selection resolves the overlay to that `CaptureRegion` immediately. Return/Enter is no longer required. A release with no valid selection (plain click / degenerate rect) resolves nothing and leaves the overlay up. Escape still resolves to `nil` (silent no-op).
- **Adjust-after-draw is dropped.** Because release confirms, the committed-selection resize handles and move-the-selection interactions become unreachable and should be removed from the selection overlay model rather than left as dead code. The live pixel-size readout during the drag stays. Window-capture's hover-then-click is already confirm-on-click and is unchanged.
- **`OverlayController` contract is unchanged** — it still returns `CaptureRegion?`, never captures, and `nil` is still a silent no-op. Only *when* the concrete overlay resolves changes. The AGENTS.md ordering rule holds: overlay first → (self-timer) → `CaptureService` → post-capture surface.
- **Routing lives in `AppCoordinator`, driven by `SettingsStore.openInEditor`.** After a successful area or window capture, the coordinator reads `openInEditor`: `true` → `CaptureUI.openEditor(with:)`; `false` → `CaptureUI.presentPostCaptureToolbar(for:at:)`. The setting is read at capture time (no caching), so changes apply to the next capture. This consumes the already-persisted, already-surfaced, currently-unread setting (default `true`) and resolves Spec 0001's parity flag: **immediate editor-open is the default outcome.**
- **`CaptureUI` is unchanged.** Both outcomes already exist on the protocol; no new methods.
- **Unchanged paths:** fullscreen capture and Open Image… continue to call `openEditor` unconditionally (there is no region to anchor a toolbar to). History recording, self-timer ordering, first-run authorization guidance, `permissionDenied` recovery, and capture-failure alerts are untouched and happen before/independent of the routing decision.
- **Repeat Last Capture** goes through the same area/window entry points, so it inherits the routing with no extra work.

### 2 — ⌘S → clipboard

- **Editor:** ⌘S is rebound from "save to default location" to a **copy-and-close** action: copy via the existing `AppCoordinator.copyToClipboard(document)` path (which sinks `render(document)` through `ImageSink.copyToClipboard`), then close the editor window. No `ImageSink.write`, no Finder reveal, no panel.
- **No new coordinator or `ImageSink` API.** Copy already exists; closing the window is app-shell work. The editor view gains one "done/close" callback from its host alongside its existing output callbacks.
- **Other editor bindings:** ⌘C stays copy-and-stay-open. ⇧⌘S stays Save As… (`NSSavePanel`). The Save-to-disk toolbar button keeps its click behavior (default-location write + reveal) but **loses its ⌘S key equivalent**; tooltips/help text are updated to match (copy-and-close advertises ⌘S; Save-to-disk advertises no shortcut).
- **Pinned windows:** the pin window's ⌘S handler routes to the same copy path as its ⌘C. The pin is not closed. ⌘W / Escape behavior is unchanged.
- **What gets copied** is always the flattened `render(document)` — crop respected, `blackout` destructively applied — identical to ⌘C today. Never the raw base capture.
- **Closing on ⌘S discards the in-editor annotation session** (as closing the window does today); the base capture remains in History. No "unsaved changes" prompt is introduced.

### 3 — Window fronting

- **One shared window presenter in the app shell.** The duplicated "activate app + make key and order front" sequence currently repeated at each call site is replaced by a single helper that every Lightshot-opened standard window goes through: Settings, History, permission onboarding, and the editor. The helper's contract: activate the application, deminiaturize if needed, make the window key and order it front, and fall back to order-front-regardless so the window is at least visibly on top if the system declines activation (accessory apps under macOS's cooperative activation can be refused key status, and the old `activate(ignoringOtherApps:)` flag is a deprecated no-op hint on macOS 14+). Calling it on an already-open window re-fronts it.
- **Settings stops being the odd one out.** Today Settings is the only window opened with no activation at all (SwiftUI `Settings` scene via `SettingsLink`), which is why it most reliably lands behind other apps in an `LSUIElement` app. Preferred fix: the menu's Settings… item becomes a normal menu action that asks the app controller to show a controller-owned settings window (hosting the existing settings view and model) through the shared presenter — the same pattern History and onboarding already use. ⌘, stays on that menu item. An acceptable alternative, if it proves equally reliable in manual verification, is keeping the SwiftUI `Settings` scene and activating the app around the system open-settings action; whichever is chosen, there must be exactly one settings window.
- **Modals** (`NSAlert`, `NSOpenPanel`, `NSSavePanel`) activate the app through the same helper's activation step before running, replacing their scattered per-call-site activation.
- **Window levels are unchanged.** Standard windows stay at normal level (front once, not always-on-top). The selection overlay, post-capture toolbar, and pinned windows keep their existing elevated levels and their own presentation code.
- **Activation policy is unchanged.** The app stays `LSUIElement` / accessory — no Dock icon, no policy flipping while a window is open.
- **No domain-core involvement.** This is pure AppKit shell work; nothing moves into `LightshotKit` and no protocol is added for it.

## Testing Decisions

- **What makes a good test here:** assert externally observable outcomes at the coordinator seam — which `CaptureUI` surface was presented with which image/region, what reached the `ImageSink` — never internal call order beyond the overlay→capture→surface ordering the architecture already guarantees, and never view/window internals.
- **Seam: `AppCoordinator`, using the existing fakes — zero new seams.** Reuse the `CaptureUI` spy, settings stub, overlay stub, capture-service stub, and `ImageSink` spy already in the coordinator test suite.
- **Routing tests (new / changed):**
  - Area capture with `openInEditor == true` opens the editor with the captured image and presents no toolbar. *(The existing "area capture … shows the toolbar" test asserts the opposite today; it is inverted/parametrized, not deleted.)*
  - Area capture with `openInEditor == false` presents the toolbar at the resolved region and opens no editor.
  - The same pair for window capture.
  - Flipping the setting between two captures changes the outcome of the second (read-at-capture-time).
  - Fullscreen and Open Image… open the editor regardless of the setting.
  - Regression guards stay green under both setting values: cancelled selection is a silent no-op; `permissionDenied` routes to recovery and never to an editor; capture failure surfaces the failure; the capture is recorded to history; the self-timer waits after region resolution and before capture.
- **⌘S/copy tests:** the existing "copy places the rendered image on the clipboard" test is the prior art and already covers the domain half. Add one guard: copying writes nothing to disk (the sink spy records a copy and zero writes), pinning down "⌘S never produces a file" at the seam where it is checkable.
- **Prior art:** the coordinator suite's capture-flow, save, clipboard, history-recording, and self-timer tests — same Swift Testing style, same fakes.
- **Manually verified (thin OS wrappers, per Spec 0001's testing decisions — no app test target exists):**
  - Drag-release in area mode captures and opens the editor with no Return; plain click doesn't capture; Escape mid-drag cancels; overlay chrome is absent from the image; self-timer still delays.
  - With the setting off, the toolbar appears at the selection for both area and window capture.
  - Editor ⌘S: clipboard contains the annotated image (paste into another app), editor closes, no file appears in the save location, Finder does not open. ⌘C copies and stays open. ⇧⌘S shows the Save panel. Save button click still writes + reveals.
  - Pinned window ⌘S copies and the pin stays.
  - Fronting checklist, each performed with another app (e.g. a full-size browser window) frontmost: Settings… via click and via ⌘,; History…; Set Up Permissions…; editor via capture, via Open Image…, via History re-open; each window appears on top and accepts keyboard input immediately. Repeat with each window already open but buried, and minimized. Open Image…/Save As…/alerts appear in front.
  - Standard windows do not stay above other apps after switching away; no Dock icon appears at any point.
- `swift test` in the domain package must pass, and the app must build via the generated Xcode project; report only results actually observed.

## Out of Scope

- A Save button or keyboard handling on the post-capture toolbar (Spec 0001 story 14's Save action remains a separate ticket).
- A configurable "after capture" action beyond the existing boolean (e.g. auto-copy on capture, auto-save on capture).
- Making ⌘S behavior configurable, or changing what the Save-to-disk button does (including its Finder reveal).
- A copy confirmation HUD/toast/sound.
- An "unsaved annotations" prompt when the editor closes.
- The single reused editor window replacing an in-progress session when a new capture arrives — pre-existing behavior, not changed here.
- Re-introducing post-draw selection adjustment (e.g. behind a modifier key) or "capture previous area".
- Multi-display selection overlay; toolbar routing for fullscreen capture.
- Moving the selection overlay model or window presentation into the domain package, or adding an app-level test target.
- An About window or an application main menu.
- Refreshing the stale "current state" wording in AGENTS.md / CLAUDE.md.

## Further Notes

- **Supersedes parts of Spec 0001:** the parity flag "post-capture toolbar or immediate editor-open as default" is resolved in favor of editor-open; the Solution narrative's "a small toolbar appears at the selection" now describes the setting-off path only; and "⌘S saves to the default location" is replaced by copy-and-close. Stories 13 (open immediately, configurable) and 60 (settings window) are what items 1 and 3 finally make true.
- **Why ⌘S = copy is deliberate, not a misbinding:** it matches the original Lightshot muscle memory where the finishing gesture lands the image on the clipboard. File output remains one modifier away (⇧⌘S).
- **Why Settings was the worst offender:** every other window already attempted activation; Settings attempted none. But the user report says "some items *like* settings," so the fix is the shared presenter applied everywhere, not a one-line patch to Settings — and the manual checklist covers every menu item that opens a window.
- **Suggested PR title:** `fix(LIG-23): open editor on selection release, ⌘S copies to clipboard, front all windows`.
