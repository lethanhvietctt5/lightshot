# Spec 0013 — Hide desktop icons while capturing, hide notifications while recording

**Status:** implemented — see *As built* at the end
**Linear:** [LIG-71](https://linear.app/light-shot/issue/LIG-71) (label `ready-for-agent`)
**Platform:** Native macOS (Swift / AppKit + SwiftUI), macOS 14+
**Scope:** Local-only. Two settings that keep clutter out of captures:
- **Hide desktop icons while capturing** (General, off by default) leaves the desktop's icons out of screenshots and recordings. During a recording the icons are also hidden on screen, behind a picture of the wallpaper, until the take ends.
- **Hide notifications** (Screen Recording → While Recording, off by default) leaves notification banners out of recordings.

Neither changes the user's Finder or Focus settings.

Vocabulary is defined in [`CONTEXT.md`](../CONTEXT.md). New terms (**desktop cover**) are under *Further Notes*.

Parity reference: CleanShot X's General → "Desktop icons: Hide while capturing" (`captureWithoutDesktopIcons`, `hideDesktopIcons`, with a wallpaper choice when icons are hidden), and its "Do Not Disturb while recording" (`doNotDisturbWhileRecording`). Lightshot does the second without turning on Do Not Disturb. It keeps banners out of the file and leaves the user's Focus alone.

---

## Problem Statement

My desktop is covered in files: downloads, screenshots, half-finished work. Every full-screen screenshot and every recording of my whole screen shows them, and some names I'd rather not share. Cleaning the desktop before each capture is tedious. When I record a demo, a notification banner (a message preview, a calendar alert) can slide into the take, and I have to cut it out or record again.

## Solution

**Settings → General → Desktop** gets **Hide desktop icons while capturing**. With it on:
- Screenshots of any kind (Capture Area, Window picks with the frozen screen behind them, Fullscreen, OCR Text) show the wallpaper where the icons are. The frozen screen I select over already shows the wallpaper, so what I see is what I get.
- A recording hides the icons on screen as soon as it starts: every display shows a picture of its wallpaper where the icons were. The take shows the same wallpaper. The icons come back when the recording stops, is discarded, or fails.

**Settings → Screen Recording → While Recording** gets **Hide notifications**. With it on, notification banners (and anything else macOS shows through Notification Center) don't appear in the recording, although they still appear on my screen.

## User Stories

### Desktop icons

1. As a user, I want a setting to hide desktop icons while capturing, so that my files never show in screenshots or recordings.
2. As a user, I want it off by default, so that captures look the way they always have until I choose otherwise.
3. As a user, I want a full-screen screenshot to show the wallpaper where the icons are, so that I can share it without tidying up first.
4. As a user, I want Capture Area and OCR Text to select over the same icon-free screen they capture, so that the frozen screen matches the result.
5. As a user, I want Capture Window unchanged, so that picking a window still gives exactly that window.
6. As a user, I want the setting read at the moment I capture, so that a change applies to my next screenshot.
7. As a user, I want a recording to show the wallpaper where the icons are, so that a whole-screen demo doesn't show my files.
8. As a user, I want the icons hidden on screen while I record, so that I can see what the recording sees.
9. As a user, I want the icons back as soon as the recording stops, is discarded or fails, so that my desktop is never left hidden.
10. As a user, I want Finder windows I open during a recording to appear in it, so that hiding icons never hides my work.
11. As a user, I want my Finder settings untouched, so that nothing about my desktop changes permanently.
12. As a user, I want the wallpaper shown in place of the icons to be my own, on each display, so that the recording looks natural.

### Notifications

13. As a user, I want a setting to hide notifications while recording, so that a banner never lands in my demo.
14. As a user, I want it off by default, so that nothing changes until I choose it.
15. As a user, I want notifications to keep appearing on my screen, so that I don't miss anything while recording.
16. As a user, I want my Focus and Do Not Disturb settings left alone, so that Lightshot never changes how my Mac notifies me.
17. As a user, I want the setting to apply to studio takes and GIFs too, so that every kind of recording is covered.
18. As a user, I want screenshots unaffected, so that I can still capture a notification on purpose (spec 0011 freezes banners for that).

## Implementation Decisions

### Modules

- **`SettingsStore.hideDesktopIcons: Bool` (domain core, new).** Stored under `capture.hideDesktopIcons`, missing means `false`. It covers screenshots and recordings.
- **`RecordingDefaults.hideNotifications: Bool` (domain core, new field).** Decoded with `decodeIfPresent`, missing means `false`, so older settings blobs still load.
- **`RecordingOptions` gains `hideDesktopIcons` and `hideNotifications`.**
  - `resolve(region:output:defaults:overrides:hideDesktopIcons:)` copies `hideNotifications` from the defaults and takes `hideDesktopIcons` as a parameter (default `false`), because it's a general setting and not a recording default.
  - `AppCoordinator.startRecording` passes `settings.hideDesktopIcons`, read when the take is configured.
- **Screenshots (App, `SCCaptureService`).**
  - A new `hideDesktopIcons` closure is read live and off the main actor from the stored key, like `includeCursor`.
  - When it's on, every display grab (the freeze stills, fullscreen, and the self-timer area path) also excludes the **desktop icon windows**: `SCWindow`s owned by Finder (`com.apple.finder`) at the desktop-icon window level (`CGWindowLevelForKey(.desktopIconWindow)`). The wallpaper beneath is captured instead.
  - Window grabs are unchanged, because the icon window is never a picker candidate.
- **Recordings (App, `SCRecordingService`).** The stream filter already excludes Lightshot's own app, so Lightshot windows opened mid-take stay out. A window exclusion can't keep new Finder windows in, so icons are hidden by covering them.
  - **`DesktopCover` (App, new, main actor).** `show()` grabs each display's wallpaper: the windows below the desktop-icon level, via `SCScreenshotManager` with an including-windows filter. It then puts one borderless, non-activating panel per display at desktop-icon level + 1. Each panel draws that picture, sits above the icons and below every app window, and joins all Spaces. `show()` returns the panels' window IDs. `hide()` removes the panels.
  - With `hideDesktopIcons` on, `start` shows the cover first. It then builds the display filter excluding Lightshot's own app while **excepting the cover panels**, so the take shows the wallpaper. Every path that ends the stream (`stop`, `cancel`, a stream failure, a failed start) hides the cover.
  - With `hideNotifications` on, the Notification Center app (`com.apple.notificationcenterui`) is added to the excluded applications.

### Settings

- **General:** a new **Desktop** section with the toggle **Hide desktop icons while capturing**. Footer: "Screenshots and recordings show your wallpaper instead of desktop icons. While recording, the icons are hidden on your screen too, until the recording ends."
- **Screen Recording → While Recording:** the toggle **Hide notifications**, with help text "Notification banners are left out of the recording. They still appear on your screen."

## Testing Decisions

- **What makes a good test:** as elsewhere, assert what a fake service is handed and what persists. ScreenCaptureKit and windows are verified by hand.
- **`RecordingOptions.resolve`:** `hideNotifications` comes from the defaults, `hideDesktopIcons` comes from the parameter, and both default to `false`.
- **`RecordingDefaults` decoding:** a blob without `hideNotifications` decodes to `false`, and one with it round-trips.
- **`AppCoordinator` recording:** the options handed to the recording service carry `settings.hideDesktopIcons` and the defaults' `hideNotifications`.
- **App side (manual):**
  - Use a temporary file on the Desktop so there is an icon.
  - Grab with the real `SCCaptureService` filter on and off, and compare pixels at the icon.
  - Show `DesktopCover` in the verify build (a DEBUG switch) and shoot the screen.
  - Record a short take from the terminal-launched verify build (it borrows the terminal's Screen Recording grant) with both settings on, and check a frame for the wallpaper where the icon is.
  - Check that the cover is gone after stop.
  - Notification exclusion is verified by filter construction: the Notification Center app is found and passed. Posting a banner into a live take needs a notification sender and is best-effort.

## Out of Scope

- A custom wallpaper to show in place of the icons (CleanShot offers one).
- A menu-bar "Hide Desktop Icons" toggle outside of recording.
- Turning on Do Not Disturb or a Focus.
- Hiding other clutter: desktop widgets, the Dock, the menu bar.
- Hiding notifications in screenshots.
- Keeping the cover in step with a wallpaper that changes during a take (dynamic or rotating wallpapers show the picture taken at the start).

## Further Notes

- **Glossary addition** (`CONTEXT.md`):
  - **Desktop cover:** the wallpaper pictures Lightshot lays over the desktop icons for the length of a recording when hiding desktop icons. _Avoid_: overlay (taken by the selection and recording overlays).
- **Why two mechanisms.** A screenshot is one grab, so leaving one window out is exact and invisible. A recording is a stream whose filter is fixed at start: excluding Finder by app would also hide Finder windows opened mid-take, and excluding Lightshot by window would let Lightshot windows opened mid-take in. Covering the icons with Lightshot's own panels and excepting them from Lightshot's exclusion avoids both.
- **Desktop widgets.** macOS draws desktop widgets through Notification Center, so **Hide notifications** may leave them out of a recording too. That is accepted: widgets are desktop clutter like the icons.

## As built

- **Verified with the real code from the terminal** (which holds the Screen Recording grant), using a temporary file on the Desktop for an icon:
  - `SCCaptureService.desktopIconWindows` found Finder's one icon window.
  - Composites of the wallpaper plus the icon window differ from the wallpaper alone exactly at the icon (2404–2550 × 47–203 px).
  - Wallpaper + icons + the `DesktopCover` panel came out **identical** to the wallpaper alone (zero difference), so the cover hides the icons with a pixel-exact picture of the wallpaper.
  - A 2 s take through the real `SCRecordingService` with both settings on started and stopped cleanly. The cover panel was on screen during the take and gone after stop.
  - The test file was removed afterwards.
- **Couldn't be seen end to end on this Mac:** app windows filled the screen, so the desktop wasn't visible in a live frame. The layer composites above stand in for it.
- **Notification exclusion** was checked as far as the filter: `com.apple.notificationcenterui` is a shareable application here, and it is added to the excluded apps. No banner was posted into a live take.
- **The cover takes desktop clicks** without activating Lightshot, so a hidden icon can't be dragged by accident while recording.
- **DEBUG:** `-previewDesktopCover <seconds>` puts the cover up without recording.
