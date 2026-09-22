# Spec 0005 — CleanShot-Style Menu-Bar Menu

**Status:** implemented on branch, not yet tracked in Linear
**Linear:** _none yet — create the issue and link it here_
**Platform:** Native macOS (Swift / AppKit + SwiftUI), macOS 14+
**Scope:** Local-only. The menu-bar status item and its drop-down menu only. Amends Spec 0001 (story 55) and Spec 0002 (stories 32, 34); adds no new seams.

Vocabulary used here is defined in [`CONTEXT.md`](../CONTEXT.md).

---

## Problem Statement

The menu-bar menu is a plain list of text rows. CleanShot X's menu — the reference — has an icon on every capture row, tall evenly spaced rows, the current shortcut beside each capture, and a clear split between capture actions, opening things, and app housekeeping. Ours also shows no shortcuts for the captures at all, and the one place it does show a chord (the settings window) writes ⇧⌘4 as "⇧⌘$".

## Solution

The menu is rebuilt as an AppKit status-item menu in CleanShot's layout: a capture section with a 24 pt template icon per row and the **live** global hotkey shown as its shortcut; an Open section; History; then About, Settings and Set Up Permissions as plain rows; then Quit. The menu is rebuilt every time it opens, so a rebound hotkey or a newly attached display appears immediately. Only actions Lightshot actually has appear — no All-In-One, scrolling capture, OCR, recording, desktop-icon toggle, pin-from-menu, or uploads.

## User Stories

1. As a user, I want each capture row to carry an icon, so that the menu reads at a glance like CleanShot's.
2. As a user, I want each capture row to show the shortcut currently bound to it, so that the menu teaches me the hotkeys I actually have — and stays correct after I rebind one.
3. As a user, I want a chord recorded as ⇧⌘4 to read "⇧⌘4" everywhere, not "⇧⌘$", so that shortcuts look the way the system writes them.
4. As a user, I want an About Lightshot… item, so that I can see the version without opening Settings.
5. As a user, I want the menu grouped the way CleanShot's is — capture, open, history, app, quit — so that I find things where I expect them.
6. As a user, I want the fullscreen row to keep offering one entry per display when I have more than one, so that nothing I could do before is lost.

## Implementation Decisions

- **AppKit `NSStatusItem` + `NSMenu`, not `MenuBarExtra`.** SwiftUI's menu cannot render a 24 pt icon per row, cannot show a shortcut that mirrors a rebindable global hotkey, and cannot be rebuilt on open. The SwiftUI `App` keeps a never-inserted `MenuBarExtra` purely to run the app lifecycle. The new `StatusMenuController` lives in the app target; nothing in `LightshotKit` changes.
- **Shortcuts are display-only.** A status-item menu is outside the key-equivalent responder path, so the global hotkeys registered through `HotkeyService` (story 56) stay authoritative; the menu reads the persisted `HotkeyBindings` on every open and mirrors them. Unbound actions show no shortcut.
- **Chord characters come from the key code.** The menu asks the current keyboard layout for the *unmodified* character of the bound key code, so an existing binding stored with a shifted label ("$") still renders as "4". The hotkey recorder is also fixed to store the unshifted label for new recordings.
- **Icons are SF Symbols drawn centred on a 24 × 24 pt bitmap-backed template canvas** — the same size as CleanShot's `menubar*` assets, which is what gives the rows their height. Mapping: area → `viewfinder`, repeat → `arrow.clockwise`, fullscreen → `desktopcomputer`, window → `macwindow`, open → `pencil`, history → `clock.arrow.circlepath`.
- **macOS 27 hides menu-item images by default.** Each icon row opts in with `preferredImageVisibility = .visible` (guarded by availability); earlier releases show images unconditionally.
- **About** is the standard `orderFrontStandardAboutPanel`, activated through `WindowPresenter` first so it fronts like every other window (LIG-23).
- **Labels** stay Lightshot's own where they already exist (`Capture Area`, `Repeat Last Capture`, `Open Image…`, `Settings…`, `Quit Lightshot`); the "Lightshot — core vN" text row is gone, the About panel carries the version.

## Testing

- The domain core is untouched, so `swift test` covers nothing new.
- The app shell has no unit tests; icons, row height, live shortcut rendering (⇧⌘4, ⌃⌘3), section order, About, ⌘, on Settings, and the display submenu were verified by hand against a debug build on macOS 27 (see `.context/menu-cleanshot-style.png` on the branch's workspace).

## Out of Scope

- CleanShot's All-In-One, Scrolling Capture, Capture Text (OCR), Record Screen, Hide Desktop Icons, Pin from the menu, and the recent-uploads section (uploads are cloud; v1 is local-only).
- A Self-Timer menu item: the timer is a capture option in Settings (LIG-20), not a separate flow.
- Replacing the `camera.viewfinder` status-bar glyph with a custom icon.
