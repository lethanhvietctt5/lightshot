# Spec 0014 — Quick Access Overlay for screenshots

**Status:** implemented — see *As built* at the end
**Linear:** [LIG-72](https://linear.app/light-shot/issue/LIG-72) (label `ready-for-agent`)
**Platform:** Native macOS (Swift / AppKit + SwiftUI), macOS 14+
**Scope:** Local-only. When a screenshot's After Capture action is **Show Quick Access Overlay**, the screenshot appears as a small **card** in a corner of the screen instead of the toolbar at the selection (story 14 of spec 0001). Cards stack as I take more screenshots and stay until I act on them or close them. Each card offers Copy, Save, Annotate, Pin, Close and drag-out. Fullscreen screenshots now follow the After Capture setting too. Recordings keep their own overlay (spec 0006) unchanged.

Vocabulary is defined in [`CONTEXT.md`](../CONTEXT.md). New terms (**Quick Access card**, **card stack**) are under *Further Notes*.

Parity reference: CleanShot X's **Quick Access Overlay**. Its bundle shows:
- the card's hover buttons (`popupClose`, `popupPin`, `popupAnnotate`, `popupTick`);
- double-click to annotate, right-click for a menu;
- "Close All Overlays", and "(option) to keep the item on Overlay after dragging";
- preferences for Position on screen (left or right), Multi-display (active screen), Overlay size, Auto-close (interval and action), Close after dragging, and Save button behavior.

---

## Problem Statement

With After Capture set to Show Quick Access Overlay, Lightshot shows a toolbar right under my selection. It sits in the middle of my work, holds only one screenshot, and disappears as soon as I take another. If I take three screenshots for a bug report, I can act on only the last one. The toolbar can't be dragged into another app, and it doesn't save. Fullscreen screenshots ignore the setting and always open the editor.

## Solution

After a screenshot, a card with the screenshot slides in at the bottom-left of the screen I'm on (bottom-right if I choose). Each new screenshot adds a card at the bottom and pushes the older ones up. Cards that no longer fit on the screen close; the screenshots stay in History.

Hovering a card dims it and shows **Copy** and **Save** in the middle, with **Close** (top-left), **Pin** (top-right) and **Annotate** (bottom-left) in the corners. Double-clicking opens the editor. Dragging a card drops the image file into another app, and the card closes afterwards (hold ⌥ to keep it). Right-clicking offers Copy, Save, Save As…, Annotate, Pin, Close and Close All.

Copy and Save show a tick on the card, then close it. Cards stay until I act, unless I set them to close after a while. Hovering a card holds that countdown.

A **Quick Access** section in Settings → Screenshots sets the position, auto-close and close after dragging.

## User Stories

### Showing cards

1. As a user, with After Capture set to Show Quick Access Overlay, I want each screenshot to appear as a card in a corner, so that it's at hand without covering my work.
2. As a user, I want the card on the screen my pointer is on, so that it appears where I'm looking.
3. As a user, I want to choose the bottom-left or bottom-right corner, so that cards don't sit on something I use.
4. As a user, I want bottom-left by default, so that cards don't collide with the recording overlay in the bottom-right.
5. As a user, I want each new screenshot to add a card at the bottom and push the others up, so that I can work through several screenshots.
6. As a user, I want the oldest cards closed when the stack no longer fits on the screen, so that cards never run off it; those screenshots are still in History.
7. As a user, I want the card to show the whole screenshot scaled down, so that I can tell cards apart.
8. As a user, I want fullscreen screenshots to follow the After Capture setting too, so that every screenshot behaves the same way.
9. As a user, with After Capture set to Open Annotate tool, I want the editor to open as before, so that nothing changes if I don't use the overlay.
10. As a user, I want cards to never take focus from the app I'm in, so that I can keep typing.
11. As a user, I want cards left out of my next screenshot, so that they never end up in it.

### Acting on a card

12. As a user, I want hovering a card to show its actions, so that the picture stays clean until I need them.
13. As a user, I want Copy to put the screenshot on the clipboard, so that I can paste it right away.
14. As a user, I want Save to write it to my export location with my file name pattern and format, so that saving is one click.
15. As a user, I want a tick after Copy or Save before the card closes, so that I know it worked.
16. As a user, I want Annotate (and double-click) to open the screenshot in the editor, so that I can mark it up.
17. As a user, I want Pin to float the screenshot on top, so that I can keep it in view.
18. As a user, I want Close to dismiss one card, so that I can clear what I don't need.
19. As a user, I want to drag a card into another app as an image file, so that I can drop it into a chat, an email or Finder.
20. As a user, I want the card to close after I drop it, and to stay if I cancel the drag; holding ⌥ at the drop inverts Close after dragging (keeps a card that would close, closes one that would stay), as in CleanShot, so that finished items clear themselves.
21. As a user, I want a right-click menu with Copy, Save, Save As…, Annotate, Pin, Close and Close All, so that every action, including the less common ones, is one click away.
22. As a user, I want Save As… to ask for a name, place and format, so that I can file a screenshot somewhere specific.
23. As a user, I want a failed save to show the error and keep the card, so that I don't lose the screenshot.

### Closing on their own

24. As a user, I want cards to stay until I act by default, so that nothing disappears while I'm busy.
25. As a user, I want an auto-close option (10 s, 30 s, 1 min), so that cards clear themselves if I prefer.
26. As a user, I want a card I'm hovering never to auto-close, and its countdown to carry on from where it was when I move away, so that it doesn't vanish under my pointer.
27. As a user, I want to turn off closing after dragging, so that I can drag the same card into several places.

## Implementation Decisions

### Modules

- **`CaptureUI.presentQuickAccess(for: CapturedImage)` replaces `presentPostCaptureToolbar(for:at:)`.** Cards don't go at the selection, so the region is dropped.
- **`AppCoordinator` routing.** Area, window and fullscreen screenshots (including the self-timer and Repeat Last Capture paths) all end in one `presentCapture(_:)`: the editor when `openInEditor`, otherwise Quick Access. Fullscreen used to call `openEditor` directly.
- **`QuickAccessSettings` (domain core, new, `Codable`).**
  - `side: .left | .right` (default `.left`);
  - `autoClose: QuickAccessAutoClose` — `.never` (default), `.after10s`, `.after30s` or `.after1min`, each with its seconds;
  - `closeAfterDragging: Bool` (default `true`).
  - `SettingsStore.quickAccess` stores it as JSON under `quickAccess.settings`, and fields missing from a stored blob decode to their defaults.
- **`QuickAccessStack` (domain core, new, value type).**
  - The ordered cards, oldest first; each has a `UUID` id and its `CapturedImage`.
  - `push(_:)` returns the new id; `remove(_:)` and `removeAll()`.
  - `overflow(cardHeights:available:spacing:)` returns the ids to close so the stack fits the available height. It closes the oldest first and always keeps the newest.
- **`QuickAccessLayout` (domain core, new, pure).**
  - `cardSize(pixelWidth:pixelHeight:)` gives a width of 220 pt with the height following the image's aspect ratio, clamped to 90–220 pt. A very tall or very wide image is letterboxed inside that clamp.
  - `frames(for sizes:in visible: Rect, side:)` stacks the cards bottom-up from the chosen bottom corner, with a 16 pt margin and 12 pt between cards. The newest card is at the bottom, and all rects are in the visible frame's space (bottom-left origin, as AppKit).
  - `arrange(_ stack:in:side:)` puts it together: each card's size from its image, the overflow to close, and a frame for every card kept.
- **`QuickAccessController` (App, new, replaces `PostCaptureToolbarController`).**
  - It owns the stack and one borderless, non-activating panel per card, placed from `QuickAccessLayout`. Panels sit at the screen-saver level, like the post-recording overlay. That's above floating, so **every** display grab (freeze stills, fullscreen, the self-timer area) leaves them out, as `SCCaptureService` drops Lightshot's own windows above the floating level.
  - The screen is the one under the pointer when a card arrives. Cards added later join the stack on that screen while it's up. If that display goes away, the stack moves to the main screen. A Position change in Settings moves the cards already up.
  - It moves panels with a short animation when the stack changes, and runs each card's auto-close timer. Hovering holds the timer, and leaving resumes it with what was left.
  - The card view is SwiftUI inside an `NSHostingView` subclass. The subclass starts an AppKit dragging session with the image written once per card to a temporary file (the coordinator's `dragItem` bytes and suggested name, in the default format's extension). The drag folder is emptied at launch. The file stays while the app runs, because receivers such as Finder copy a dropped file after the drag session ends. When the session ends with an operation, the card closes, unless close-after-dragging is off or ⌥ is held at the drop.
- **Actions reuse existing paths.**
  - Copy is `coordinator.copyToClipboard`.
  - Save is `coordinator.save(document)`, which doesn't reveal the file in Finder.
  - Save As… is the editor's save panel.
  - Annotate is `openEditor(with:)`, and Pin is the existing pin.
  - Each action closes the card: Copy and Save after about 0.6 s with a tick, the others at once. While the tick shows, the card takes no more actions. A failed save shows the existing alert and keeps the card.

### Settings

- Settings → Screenshots gets a **Quick Access** section:
  - **Position:** Bottom Left / Bottom Right;
  - **Close automatically:** Never / After 10 seconds / After 30 seconds / After 1 minute;
  - **Close after dragging:** a toggle. Footer: "Screenshots wait in a corner of the screen when After Capture is Show Quick Access Overlay. Hold ⌥ while dropping to keep the card."
- The After Capture table keeps its **Show Quick Access Overlay** row. It now opens cards.

## Testing Decisions

- **What makes a good test:** assert the observable routing and the pure stack and layout math. Panels, hover, drag and animation are checked by hand.
- **`AppCoordinator`:**
  - `openInEditor = false` sends area, window and fullscreen screenshots to `presentQuickAccess` with the captured image, and opens no editor.
  - `openInEditor = true` opens the editor for all three and never presents Quick Access.
  - The self-timer and Repeat Last Capture paths end in Quick Access too.
  - The existing toolbar tests become Quick Access tests with the same images.
- **`QuickAccessStack`:**
  - Push order and ids; removal.
  - `fitting` closes the oldest first until the rest fit.
  - The newest card is always kept, even if it's taller than the available height.
  - Empty stays empty.
- **`QuickAccessLayout`:**
  - Card sizes for landscape, portrait, square, extreme-tall and extreme-wide images.
  - Frames bottom-up with the margin and spacing on the left and on the right.
  - The newest card is at the bottom.
  - Frames follow an offset visible frame, as on a second display or with the Dock on the left.
- **`QuickAccessSettings`:** defaults; a JSON round-trip; a blob missing a field decodes to its default.
- **App side (manual, `.verify` build):**
  - DEBUG `-previewSurface quickAccess [-previewFile <png>]` shows three cards. It replaces the old `postCapture` surface.
  - Screenshot the stack on the left and on the right, and the hover state.
  - Drag a card to Finder and check the file.
  - Check that Copy puts the image on the pasteboard, and that auto-close works and pauses under the pointer.

## Out of Scope

- An overlay size setting, and choosing a fixed display for cards.
- Recordings in the same stack (the post-recording overlay stays as it is).
- Swipe to dismiss, a keyboard shortcut to close all cards, and hiding/showing all cards.
- Upload or share actions (local-only).
- Save that asks for a name every time (Save As… covers it).
- Restoring cards after quitting.

## Further Notes

- **Glossary additions** (`CONTEXT.md`):
  - **Quick Access card:** a screenshot waiting in the corner of the screen for an action (copy, save, annotate, pin, drag, close). _Avoid_: popup, thumbnail, toast.
  - **Card stack:** the Quick Access cards on screen, newest at the bottom.
- **Why fullscreen changes.** The After Capture table has one Screenshot column, and a fullscreen screenshot is a screenshot. Opening the editor regardless was a leftover from before the toolbar existed.
- **Why cards and the post-capture toolbar can't coexist.** Both answer "what happens after a screenshot" for the same setting. The toolbar's story 14 is superseded, and `PostCaptureToolbarController` is removed.

## As built

- **Verified in the `.verify` build** with `-previewSurface quickAccess`:
  - **Stack:** three 220 × 138 pt cards (for the 1.6:1 sample image) stacked from 16 pt above the bottom-left corner, 12 pt apart, newest at the bottom.
  - **Right side:** with Position set to Bottom Right, the cards hugged the right edge (x = 2560 − 16 − 220).
  - **Copy:** Copy on the bottom card put the image on the clipboard (PNG, TIFF and more) and showed the tick. After about 0.6 s the card faded out, and the cards above slid down into its place.
  - **Drag:** dragging a card into a Finder window dropped `Screenshot 2026-09-27 at 17.38.02.png` (the save pattern and format) and closed the card.
  - **Auto-close:** set to 10 s, every card closed except the one under the pointer, which slid down into place. (That run predates the resume fix, and the card closed a full 10 s after the pointer left; see the re-check below.)
  - **Settings:** the Quick Access section was checked in Settings → Screenshots.
- **Drag-out uses an AppKit dragging session** with a separate `NSDraggingSource` object. `NSHostingView` already conforms to the protocol, and its conformance can't be overridden, and SwiftUI's `onDrag` can't say whether the drop landed.
- **Cards sit at the screen-saver level**, like the post-recording overlay. That's above the floating level, so freeze stills leave them out of the next screenshot.
- **Self-review fixes:**
  - Live display grabs (fullscreen, self-timer area) now leave out Lightshot's own windows above floating, as freeze stills already did. Before this, a fullscreen screenshot taken with cards up would have captured them, and the OCR notice.
  - Hovering holds auto-close, and leaving resumes it with the time left instead of starting over.
  - A card showing its tick ignores further actions, so a double Save can't write twice.
  - Each card writes its drag file once, in its own folder, and the drag folder is emptied at launch. Deleting a card's folder when it closed was tried and lost the drop: Finder copies the file after the drag session ends, and the re-check caught it.
  - The stack follows a display being unplugged, and a Position change moves cards already on screen.
  - The core's `arrange` gives the whole placement, so the controller no longer joins sizes, overflow and frames itself.
- **Re-checked after the fixes** (`.verify` build):
  - Hovering the bottom card for 4 s of a 10 s auto-close, then leaving: the other cards closed on time, and the hovered one closed about 7 s after the pointer left, not 10.
  - Dragging a card into Finder still dropped the file, and the card closed.
- **Not verified by hand:**
  - A live Position change moving the cards. It rides on `UserDefaults.didChangeNotification`, which fires only for changes made inside the app (the Settings window), not for `defaults write` from a terminal.
  - Cards being left out of a live fullscreen grab. That path now uses the same exclusion as the freeze stills.
  - ⌥ at the drop keeping the card (the modifier can't be held through the synthetic drag), Save As… from the menu, and a real capture routed to cards. The routing is covered by the coordinator tests.
