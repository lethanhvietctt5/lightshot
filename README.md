# Lightshot

A native **macOS (Swift / SwiftUI, macOS 14+)** screenshot and screen-recording app — a local-only alternative to CleanShot X: **capture → annotate → copy / save / pin**, and **record → edit in the Studio → export**.

Everything happens on your machine. No cloud, no accounts, no network — even captions are transcribed on your Mac.

## Features

**Screenshots**

- **Capture** an area (drag-to-select with live pixel dimensions and adjustable edges), a window (with hover highlight), or a full display — all via rebindable global hotkeys and a CleanShot-style menu-bar menu.
- **Capture options** — self-timer, cursor inclusion, repeat last capture, and multi-display selection.
- **Annotation editor** in one compact toolbar row — arrows, lines, rectangles, ellipses, freehand, text boxes, highlights, auto-numbered step markers, a **Focus** tool that dims everything outside chosen areas, and an adjustable, reversible crop. Full undo/redo.
- **Redaction** — `blackout` (secure, erases pixels), plus `blur` / `pixelate` (obscure only — **not** safe for secrets).
- **Auto Redact** (⇧⌘R) — on-device text recognition finds keys, passwords, cards, IBANs, emails, phone numbers, IPs and QR codes and redacts them in the current style. It can miss things; check before sharing.
- **Finish** — copy to the clipboard, save as PNG/JPEG, drag out, or **pin** the shot so it floats on top while you work.
- **Open existing images** in the editor.

**Screen recording**

- **Record** an area, a window's area, or a display as a **video** or a **GIF**, with an aspect-ratio lock or an exact size.
- Toggles for **microphone**, **computer audio**, **camera** (a draggable bubble), **click highlighting**, and **keystrokes** (never shown while a password field has focus).
- Pause / resume, stop, restart, and discard from a controls pill or the menu-bar timer; optional countdown, sounds, dimming outside the recorded area, and crash recovery.
- A post-recording overlay to copy, save, rename, drag out, Quick Look, or delete the take.

**Studio editor** — every recording stays editable after the take

- The screen, pointer, clicks, keystrokes, and camera are recorded separately, so cursor, zooms, camera, and keystrokes can all be changed later.
- **Auto Zoom** from your clicks, manual zooms that follow the cursor or a fixed point, and a cursor redrawn from data (size, smoothing, motion blur, click effects, hide when idle).
- Canvas backgrounds (colour, gradient, wallpaper, image), padding, rounded corners, shadow, and aspect ratios from 16:9 to 9:16.
- Timeline with split, trim, delete, per-clip speed, zoom and text lanes, snapping, audio waveform, undo/redo, and autosave.
- **On-device captions**: transcribe narration, burn in styled captions, cut speech by selecting words, or **Remove Silences**.
- Export MP4 or GIF — H.264 or HEVC, up to 4K, 24/30/60 fps — with a size estimate.

**Everything else**

- **Local history** of screenshots and recordings — reopen, reveal in Finder, or delete, with configurable retention.
- **Light and Dark mode** throughout, with **Settings → General → Appearance** (Match System, Light, or Dark).
- **Settings** — sidebar of panes, rebindable shortcuts, an **After Capture** table for screenshots and recordings, and launch at login.
- **First-run onboarding** for Screen Recording, with recovery when it's revoked; other permissions are asked for only when you turn their feature on.

The full contracts live in [`specs/`](specs); per-version highlights are in [`docs/releases/`](docs/releases).

## Install

**Requirements:** a Mac running **macOS 14 (Sonoma) or later**, Apple Silicon or Intel.

There are two ways to install Lightshot:

- **[Download a release](#option-1--download-a-release-recommended)** — the quick way, no developer tools needed.
- **[Build from source](#option-2--build-from-source)** — if you want the latest `main`, or the [Releases page](https://github.com/lethanhvietctt5/lightshot/releases) has no download yet.

### Option 1 — Download a release (recommended)

1. **Download** `Lightshot-<version>.dmg` from the [latest release](https://github.com/lethanhvietctt5/lightshot/releases/latest) (under **Assets**).
2. **Install.** Open the DMG and drag **Lightshot** into **Applications**. Eject the DMG afterwards. Always run Lightshot from Applications, not from the DMG or your Downloads folder — otherwise macOS runs it from a temporary location, which breaks launch-at-login and confuses the permission entry.
3. **Get past the first-launch warning.** Lightshot is open source and **not notarized by Apple** (that requires a paid developer account), so macOS blocks the first launch with *"Apple could not verify…"*. This is expected. Allow it once:
   - **macOS 15 (Sequoia) or later:** open Lightshot and dismiss the warning with **Done**. Go to **System Settings → Privacy & Security**, scroll down to the message about Lightshot, click **Open Anyway**, and confirm.
   - **macOS 14 (Sonoma):** in Applications, right-click (or Control-click) **Lightshot** → **Open**, then click **Open** in the dialog.
   - **Or, on any version, in Terminal:**

     ```bash
     xattr -dr com.apple.quarantine /Applications/Lightshot.app
     ```

4. **[Grant Screen Recording](#grant-screen-recording)** when the app asks.

**Verify your download (optional).** Each release's notes include a SHA-256 checksum. Compare it with your file's:

```bash
shasum -a 256 ~/Downloads/Lightshot-*.dmg
```

### Option 2 — Build from source

Takes a few minutes and needs no Apple Developer account.

1. **Get the tools.** Install **Xcode** (with Swift 6) from the Mac App Store and open it once to finish setup, then install [XcodeGen](https://github.com/yonaskolb/XcodeGen) with [Homebrew](https://brew.sh):

   ```bash
   brew install xcodegen
   ```

2. **Build the app** and wait for `** BUILD SUCCEEDED **`:

   ```bash
   git clone https://github.com/lethanhvietctt5/lightshot.git
   cd lightshot
   xcodegen generate
   xcodebuild -project Lightshot.xcodeproj -scheme Lightshot -configuration Release \
     -destination 'platform=macOS' -derivedDataPath build build
   ```

3. **Move it to Applications and launch.** Because you built it on your own Mac, there is no first-launch warning:

   ```bash
   cp -R build/Build/Products/Release/Lightshot.app /Applications/
   open /Applications/Lightshot.app
   ```

4. **[Grant Screen Recording](#grant-screen-recording)** when the app asks.

### Grant Screen Recording

Lightshot is a **menu-bar app** — it has no main window, and appears in the Dock only while the editor is open. Look for its icon in the menu bar.

On first launch, follow the in-app onboarding to allow **Screen Recording** in **System Settings → Privacy & Security → Screen & System Audio Recording** (named **Screen Recording** on macOS 14), then relaunch Lightshot if macOS asks. Without it captures come back black or empty.

Other permissions are optional and requested only when you first use the feature that needs them: **Microphone** and **Camera** for recordings, **Input Monitoring** for the keystroke overlay, and **Speech Recognition** for captions (always on-device).

### Updating

Lightshot never connects to the network, so it does not update itself. Choose **Quit Lightshot** from its menu-bar menu, then:

- **Release download:** download the new DMG and drag Lightshot into Applications again, choosing **Replace**. The first-launch warning appears once more for each new download.
- **Source build:** `git pull`, repeat the `xcodegen generate` and `xcodebuild` commands above, then replace the installed copy:

  ```bash
  rm -rf /Applications/Lightshot.app
  cp -R build/Build/Products/Release/Lightshot.app /Applications/
  ```

> **If captures come back black or empty after an update,** macOS has lost the Screen Recording grant even though System Settings still shows the toggle as on. Run `tccutil reset All dev.lightshot.app`, relaunch, and grant the permission again. Source builds hit this on **every** rebuild unless you set up [local code signing](#local-code-signing--keep-permissions-across-rebuilds) once (a free Apple ID is enough).

### Uninstalling

Quit Lightshot, then remove the app and its permission entries:

```bash
rm -rf /Applications/Lightshot.app
tccutil reset All dev.lightshot.app
```

## Architecture

Everything interesting is a pure function over a value type; everything OS-facing hides behind a protocol. The app depends on the package, never the reverse.

- **[`LightshotKit/`](LightshotKit)** — the SwiftPM domain core. Pure Swift, **no AppKit / ScreenCaptureKit imports**, so it tests fast and screen-free. It holds:
  - `AnnotationDocument` — a value type mutated only through a command API (`add`, `select`, `transform`, `setStyle`, `updateText`, `delete`, `reorder`, `applyCrop`, `undo`, `redo`). Owns undo/redo history, step-number auto-increment, crop math, and hit-testing. Geometry is stored in **image pixel coordinates**.
  - `render(document) -> image` — a pure, deterministic flatten of base image + elements, respecting crop and z-order.
  - `StudioDocument` — the Studio editor's value type: timeline clips, zoom regions, captions, and canvas settings behind the same command-and-undo style, plus the pure models it draws on (`ZoomCamera`, `CursorPath`, `CanvasLayout`, `StudioTimeline`, `GIFFramePlan`).
  - `RecordingSession`, `HistoryStore`, `AppCoordinator`, `ThemePalette`, and the service *protocols* (`CaptureService`, `RecordingService`, `ImageSource`, `ImageSink`, `MediaSink`, `HotkeyService`, `AudioInputService`, `CameraService`, `InputEventSource`, `OverlayController`, `SettingsStore`, …).
- **[`App/`](App)** — the SwiftUI / AppKit menu-bar app shell (`LSUIElement`) plus the concrete ScreenCaptureKit / AVFoundation / AppKit implementations of those protocols, including the Studio compositor and exporter.
- **[`scripts/`](scripts)** — `release.sh`, which builds, signs, and packages a release DMG. See [`scripts/README.md`](scripts/README.md).
- **[`project.yml`](project.yml)** — the XcodeGen spec. **`Lightshot.xcodeproj` is generated, not committed** — run `xcodegen generate` after cloning or after editing `project.yml`.

## Getting started

For contributors — if you just want to use the app, see [Install](#install).

**Prerequisites:** macOS 14+, Xcode with Swift 6, and [XcodeGen](https://github.com/yonaskolb/XcodeGen):

```bash
brew install xcodegen
```

### Domain core (SwiftPM package) — the fast inner loop

```bash
cd LightshotKit
swift build
swift test
swift test --filter CropTests                                   # one suite
swift test --filter AddSelectDeleteTests/addDoesNotChangeSelection # one test
```

### Full app (Xcode project) — requires a real macOS destination

```bash
# Regenerate the (gitignored) project from project.yml first:
xcodegen generate
xcodebuild -project Lightshot.xcodeproj -scheme Lightshot -destination 'platform=macOS' build
xcodebuild -project Lightshot.xcodeproj -scheme Lightshot -destination 'platform=macOS' test
```

### Local code signing — keep permissions across rebuilds

The committed default builds **unsigned** ([`App/Config/Signing.xcconfig`](App/Config/Signing.xcconfig)), so CI and fresh clones need no certificate. The catch: an unsigned build gets a new code identity on every rebuild, so macOS forgets Screen Recording (and every other granted permission) each time — while System Settings still shows the stale toggle as on.

To fix it, sign with your own stable identity via a gitignored override:

1. In Xcode → **Settings → Accounts**, add your Apple ID (a free one works), then **Manage Certificates → + → Apple Development**.
2. Find your **team ID** — it is the certificate's `OU` field, *not* the code in parentheses in the certificate name:

   ```bash
   security find-certificate -a -c "Apple Development" -p | openssl x509 -noout -subject
   # subject=UID=…, CN=Apple Development: you@example.com (NOT-THIS-ONE), OU=ABCDE12345, …
   ```

3. Create `App/Config/Local.xcconfig`:

   ```
   CODE_SIGNING_ALLOWED = YES
   CODE_SIGNING_REQUIRED = YES
   CODE_SIGN_STYLE = Automatic
   DEVELOPMENT_TEAM = ABCDE12345
   ```

4. Regenerate, rebuild, and clear the grants left over from unsigned builds (one time), then grant the permissions once more:

   ```bash
   xcodegen generate
   xcodebuild -project Lightshot.xcodeproj -scheme Lightshot -destination 'platform=macOS' build
   tccutil reset All dev.lightshot.app
   ```

Verify with `codesign -dr - <path-to>/Lightshot.app` — the designated requirement should name your certificate rather than a `cdhash`.

Don't set `CODE_SIGN*` keys in `project.yml`: target build settings there override the xcconfig. If you use [Conductor](https://conductor.build), [`.conductor/settings.toml`](.conductor/settings.toml) copies `Local.xcconfig` from your main checkout into each new workspace, so create it there.

## Contributing

This project is spec-driven and issue-tracked. Read [`AGENTS.md`](AGENTS.md) first — it is the single source of truth for the working agreement.

1. **Spec** lives in `specs/NNNN-*.md` and as a Linear issue (team **Lightshot**) — keep the two in sync.
2. A spec ready to build carries the **`ready-for-agent`** label.
3. **Branch per issue** off `main`, using Linear's suggested branch name.
4. **PR targets `main`**, titled `<type>(LIG-<n>): <title>` (e.g. `feat(LIG-100): add scrolling capture`).
5. Verify the change (`swift test`, plus the app build for app-side work) before merging.

### Guardrails

- **Local-only** — no networking, accounts, analytics, or cloud upload.
- **Never present blur/pixelate as secure redaction** — only `blackout` is safe for secrets.
- **macOS 14+ / ScreenCaptureKit only** — no deprecated `CGWindowListCreateImage`.
