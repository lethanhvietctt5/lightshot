# Spec 0015 — Software updates: check, download and install new versions

**Status:** implemented (LIG-73). The real update through GitHub before the first public release is still pending; see *Testing Decisions*.
**Linear:** [LIG-73](https://linear.app/light-shot/issue/LIG-73) (label `ready-for-agent`)
**Platform:** Native macOS (Swift / AppKit + SwiftUI), macOS 14+
**Scope:** Lightshot finds out when a newer version is published, shows what's new, then downloads, verifies and installs it and relaunches. Settings let me turn automatic checks and automatic installs on or off. This is the **one deliberate exception to the local-only guardrail**. The only network traffic is fetching the update feed and the update file from GitHub Releases. It sends no account, no analytics and no system profile, and I can turn automatic checks off.
**Depends on:** spec 0002 (the release script, the pinned signing identity, GitHub Releases as the download home). This spec supersedes 0002's out-of-scope item "Auto-update / in-app update checks (e.g. Sparkle)".

Vocabulary is defined in [`CONTEXT.md`](../CONTEXT.md). New terms (**update check**, **update feed**, **update signing key**) are under *Further Notes*.

Parity reference: CleanShot X ships **Sparkle** (`Sparkle.framework` in its bundle). Its `Info.plist` sets `SUFeedURL` and `SUPublicEDKey`, and its binary has "Check for Updates", "automatically check for updates" and a `menubarUpdateIndicator` (a mark on the menu-bar icon when an update is waiting).

---

## Problem Statement

Lightshot never tells me when a new version is out. To update, I have to remember to visit the GitHub Releases page, see whether there's something newer than what I run, download the DMG, quit Lightshot, drag the new app over the old one and relaunch. Each new DMG also brings back the "Apple could not verify…" Gatekeeper warning, which I have to click past again. Most people will never bother, so they keep old bugs long after the fixes ship. As the maintainer, I can't get a fix to users without asking each of them to redo the manual install.

## Solution

Lightshot checks GitHub for a newer version once a day, but only after I agree. On the second launch it asks once: "Check for updates automatically?" I can also check at any time with **Check for Updates…** in the menu-bar menu, the About pane or Settings.

When a newer version exists, a window shows its version and its highlights (the same notes as the GitHub release) with **Install Update**, **Remind Me Later** and **Skip This Version**. **Install Update** downloads the update, checks its signature, replaces the app in place and relaunches it. My Screen Recording and other permissions carry over, and there's no Gatekeeper warning. If a daily check finds an update while I'm working, no window jumps in front of me. The menu-bar icon gets a small dot, and the menu gets an **Update Available…** row that opens the same window.

If a recording, a GIF conversion or an archive is in progress, the relaunch waits until it finishes. I never lose a take to an update.

Settings → General gets an **Updates** section:
- **Check for updates automatically** (on or off);
- **Download and install updates automatically**, which installs quietly the next time Lightshot quits;
- **Check Now**, with when it last checked.

## User Stories

### Finding out about a new version

1. As a user, I want Lightshot to tell me when a newer version is available, so that I don't have to watch the GitHub Releases page.
2. As a user, I want to be asked once whether Lightshot may check for updates automatically, so that the app never goes online without my consent.
3. As a user, I want that question on the second launch, not the first, so that my first run is about capturing, not about prompts.
4. As a user, I want automatic checks to happen about once a day, so that I hear about fixes quickly without constant network traffic.
5. As a user, I want a **Check for Updates…** item in the menu-bar menu, so that I can check right now.
6. As a user, I want the same action in the About pane, next to my version number, so that I can check where I'm looking at the version.
7. As a user, when I check by hand and I'm already up to date, I want to be told so, with my version number, so that I know the check worked.
8. As a user, when a check fails (offline, GitHub unreachable, a bad feed), I want a clear message on a manual check and silence on an automatic one, so that a flaky network never nags me.
9. As a user, when a daily check finds an update, I want a small dot on the menu-bar icon and an **Update Available…** row in the menu instead of a window, so that nothing steals focus while I'm capturing.
10. As a user, I want the update window to show the new version, my current version and the highlights, so that I can decide whether to install now.
11. As a user, I want **Remind Me Later**, so that I can put off an update without turning checks off.
12. As a user, I want **Skip This Version**, so that I'm not asked about a version I've chosen not to take; a later version still gets offered.
13. As a user on an older macOS than a new version supports, I want not to be offered that version, so that I never install something that won't launch.

### Installing

14. As a user, I want **Install Update** to download, install and relaunch Lightshot in one step, so that updating takes a single click.
15. As a user, I want download progress with a Cancel button, so that I know it's working and can stop it.
16. As a user, I want the download's signature checked before anything is installed, so that a tampered or corrupt file is never installed.
17. As a user, I want the new version to replace the app where it already lives, so that my Dock, login item and Finder shortcuts keep working.
18. As a user, I want my Screen Recording, Microphone, Camera and Accessibility grants to survive the update, so that capturing keeps working afterwards.
19. As a user, I want no Gatekeeper warning after an in-app update, so that I only click past it once, on the first install.
20. As a user, I want my settings, hotkeys and capture history kept across the update, so that nothing resets.
21. As a user, I want the relaunch held while I'm recording, converting a GIF or archiving a take, so that an update never cuts off my work.
22. As a user, I want the app to relaunch on its own once the install is done, so that I'm back in the menu bar without doing anything.
23. As a user whose install fails (no write access to the app's folder, app run from the DMG, a bad signature), I want a message that says why and what to do, so that I'm not left on a half-installed app.

### Settings

24. As a user, I want an **Updates** section in Settings → General, so that update behavior is in one place.
25. As a user, I want a **Check for updates automatically** toggle, so that I can stop Lightshot going online at all.
26. As a user, I want a **Download and install updates automatically** toggle, so that I can stay current without ever seeing the update window.
27. As a user, I want automatic installs to happen when Lightshot quits, not while I'm using it, so that the update never interrupts me.
28. As a user, I want the automatic-install toggle disabled while automatic checks are off, so that the settings can't contradict each other.
29. As a user, I want a **Check Now** button and a "Last checked: …" line, so that I can see the checks are happening.
30. As a user, I want the section's footer to say what goes over the network and what doesn't, so that I trust the local-only promise still holds for my captures.
31. As a user, I want my answer to the second-launch question to show in these toggles, so that there is one source of truth.

### Maintainer publishing an update

32. As the maintainer, I want `scripts/release.sh` to produce the update feed and sign the DMG for updates in the same run, so that shipping an update is no extra work.
33. As the maintainer, I want the release to fail if the update signing key is missing or if the feed's signature doesn't verify against the public key in the app, so that I can never ship an update users will reject.
34. As the maintainer, I want the feed published with the GitHub Release, so that publishing the draft is the one step that makes an update go live.
35. As the maintainer, I want the feed to carry each version's highlights from `docs/releases/<version>.md`, so that the update window and the GitHub release say the same thing.
36. As the maintainer, I want the feed to carry the minimum macOS version, so that users on unsupported systems aren't offered a build that won't launch.
37. As the maintainer, I want a documented one-time procedure to create and back up the update signing key, so that losing a laptop doesn't strand every user on their current version.
38. As the maintainer, I want the Sparkle helpers inside the app signed with the same pinned identity, so that the designated-requirement check still passes and permissions still carry over.

## Implementation Decisions

### Why Sparkle

- **Updater: Sparkle 2** (latest 2.x, at least 2.9 for Markdown release notes), added as a Swift package dependency of the **app target only** in `project.yml`. It's the standard updater for apps distributed outside the App Store. CleanShot X uses it, and it already handles the hard parts: the feed, EdDSA verification, the install-and-relaunch helper, removing the download quarantine, skipping versions and the standard windows. A hand-rolled updater (GitHub API → download DMG → mount → replace → relaunch) would re-implement all of that with less scrutiny.
- **LightshotKit doesn't depend on Sparkle.** The domain core stays free of it and of networking.

### The update feed

- **Feed URL (`SUFeedURL`):** `https://github.com/lethanhvietctt5/lightshot/releases/latest/download/appcast.xml`.
  - GitHub's `latest` redirect points at the newest **published**, non-prerelease release. Drafts stay invisible, so clicking **Publish release** is what ships an update, and nothing changes in the maintainer's flow.
  - The repo is public, so the URL needs no token.
- **One item per feed.** Each release uploads an `appcast.xml` that describes only its own version. Sparkle needs only the newest item, and there are no delta updates, so there's no feed history to keep.
- **The update file is the release DMG.** Sparkle installs from DMGs, so there's no second archive. The item carries:
  - `sparkle:version` = `CFBundleVersion`, the commit-count build number, which only goes up on `main`;
  - `sparkle:shortVersionString` = the marketing version;
  - `sparkle:minimumSystemVersion` = 14.0;
  - the DMG's EdDSA signature and length;
  - the GitHub release page as the full release notes link.
- **Release notes:** `docs/releases/<version>.md`, embedded as Markdown (Sparkle 2.9+, macOS 12+). With no highlights file, a one-line "See the release page" note links to the GitHub release.

### The update signing key

- **An EdDSA (ed25519) key pair from Sparkle's `generate_keys`.** The private key lives in the maintainer's login keychain, where `generate_keys` stores it by default. The **public key goes in `Info.plist` as `SUPublicEDKey`** and is committed.
- **Backup.** `generate_keys -x` exports the key, which is stored in a password manager next to the code-signing `.p12`, never in the repo. `scripts/README.md` documents creating, backing up and restoring it.
- **Losing the key strands users.** Existing installs can't auto-update to a build signed with a new key and must download it by hand once. Sparkle also checks that the new app's code signature satisfies the old one's designated requirement, which our pinned self-signed identity already guarantees (spec 0002).
- **Invariant, next to the bundle id and the certificate:** don't change `SUPublicEDKey` without a deliberate, announced break.

### Release script changes (`scripts/release.sh`)

- **Preflight** fails early when:
  - Sparkle's `sign_update` / `generate_appcast` tools can't be found (they come from the resolved Sparkle package artifacts, so no Homebrew install is needed);
  - the update signing key isn't in the keychain;
  - `Info.plist`'s `SUPublicEDKey` doesn't match that private key.
- **Sign.** The "no nested Mach-O" assertion becomes an **allow-list of Sparkle's helpers**, and the script signs nested code inside-out, with no `--deep` and with the same pinned identity:
  1. Autoupdate;
  2. Updater.app;
  3. the XPC services, which a non-sandboxed app doesn't need, so they're stripped instead of signed;
  4. the framework;
  5. the app.

  Anything nested and not on the list still fails the build. Hardened Runtime stays off (spec 0002); Sparkle doesn't need it.
- **Verify.** The designated requirement is checked as before (the app's own requirement is unchanged). After packaging, `sign_update --verify` checks the DMG against the keychain key, which preflight and verify tie to the committed key (both require it to equal `SUPublicEDKey`, in the source and in the built app). `appcast.xml` must carry the expected version, build number, minimum system version and a signature that verifies.
- **Package** writes `build/release/appcast.xml` next to the DMG. **Publish** uploads both to the draft release. `--dry-run` produces and verifies both and uploads nothing.

### App side

- **`SoftwareUpdater` (App, new).** A thin owner of Sparkle's `SPUStandardUpdaterController`, created at launch by `AppController`. It exposes:
  - `checkForUpdates()` and `canCheckForUpdates`;
  - `automaticallyChecks`, `automaticallyInstalls` and `lastCheckDate`.

  These read and write Sparkle's `SPUUpdater` properties directly (`automaticallyChecksForUpdates`, `automaticallyDownloadsUpdates`, `lastUpdateCheckDate`). Sparkle persists them in the app's user defaults (`SUEnableAutomaticChecks`, `SUAutomaticallyUpdate`). **No new `SettingsStore` keys:** Sparkle's defaults are the single source of truth, and its docs warn against mirroring them (story 31).
- **No `LightshotKit` protocol wraps the updater.** It holds no domain logic to test with a fake, and the settings UI and menu are App-side. The one domain decision it needs is the query below.
- **`AppCoordinator.hasWorkInProgress` (domain core, new, pure).** It's true while a take is starting, counting down, recording, paused or stopping. It stays true from the moment the take finishes until its result is routed: the Studio render, the GIF conversion and the keep-the-video question are all covered. It's also true while any take is being filed into history. It's composed from state the coordinator already owns (`recordingSession`, `isStartingRecording`, `gifConversion`, `isArchiving`), plus one new flag set for the length of the finish.
  - `SoftwareUpdater` implements Sparkle's `updater(_:shouldPostponeRelaunchForUpdate:untilInvokingBlock:)`: while the query is true, it holds the relaunch and invokes the block when the work ends (story 21).
  - An automatic install runs only after Lightshot has quit, so it needs no hold; the user's quit ends any take first.
- **Info.plist:**
  - `SUFeedURL` and `SUPublicEDKey`;
  - `SUEnableSystemProfiling` = NO, so the permission prompt shows no "send system profile" checkbox;
  - `SUScheduledCheckInterval` = 86400 (one day);
  - **no `SUEnableAutomaticChecks` key**, so Sparkle asks on the second launch (stories 2–3; confirmed with the user).
- **Gentle reminders for a menu-bar app (story 9).** `SoftwareUpdater` is the standard user driver's delegate with `supportsGentleScheduledUpdateReminders = true`.
  - When a **scheduled** check finds an update outside Sparkle's "immediate focus" (right after launch or activation), it doesn't show the window. `StatusMenuController` badges the menu-bar icon with a dot and adds **Update Available: Lightshot X.Y.Z…** at the top of the app section.
  - Choosing that row calls `checkForUpdates()`, which brings up the found update.
  - The badge and row clear once the update window has had the user's attention, or when the update session ends (installed, skipped or dismissed), following Sparkle's gentle-reminder pattern.
  - A user-initiated check always shows the window and brings it forward, like other Lightshot windows (`WindowPresenter.activateApp`).
- **Menu-bar menu:** **Check for Updates…** right below **About Lightshot…**. It's disabled while Sparkle's `canCheckForUpdates` is false, which Sparkle reports through KVO.
- **Settings → General → Updates** (after Startup):
  - **Check for updates automatically:** a toggle;
  - **Download and install updates automatically:** a toggle, disabled while the first is off;
  - **Check Now** with "Last checked: <relative date>" or "Never";
  - footer: "Lightshot contacts GitHub only to look for new versions. Your screenshots and recordings never leave your Mac. Automatic updates install when you quit Lightshot."
- **About pane:** a **Check for Updates…** button under the version line. The tagline becomes "Screenshots, annotations and screen recordings that never leave your Mac — no account, no cloud."; that wording still holds.
- **Failure paths are Sparkle's own messages** (story 23): no network, a bad signature, an app it can't write to, an app running translocated from the DMG or Downloads. Lightshot doesn't add a "move to Applications" prompt (out of scope).

### Guardrail and docs changes

- **New ADR `docs/adr/0002-in-app-update-checks.md`.** In-app update checks are Lightshot's **only** network access. The ADR sets:
  - what is sent: an HTTPS GET to the feed and the DMG, with Sparkle's standard User-Agent and no system profile;
  - that it's gated on the user's consent;
  - that it's the one exception to "local-only", and that everything else in the guardrail stands (no accounts, analytics, cloud upload or telemetry).
- **AGENTS.md** *Guardrails*: "Local-only" gains "— except the in-app update check, ADR 0002". *Releasing* mentions the appcast and the update signing key as a third invariant.
- **README:**
  - line 5 ("no network") becomes "no network, except checking for updates, which you can turn off";
  - the "Updating" section describes the in-app update, and the manual DMG route for users on 0.6.0 and earlier (story 19 applies only once a Sparkle-enabled version is installed);
  - the Local-only bullet is reworded to match.
- **Spec 0002:** its out-of-scope bullet about Sparkle gets a pointer: "superseded by spec 0015".

## Testing Decisions

- **What makes a good test:** assert behavior a user or the maintainer can observe: the relaunch-hold decision, and what the release script produces and refuses. Don't test Sparkle's internals (its windows, scheduling, download and install); Sparkle's own test suite covers those. Check the App-side wiring by hand, as for every other App surface.
- **`AppCoordinator.hasWorkInProgress` (Swift Testing, `swift test`).** Prior art: the existing `AppCoordinator` tests with fake `RecordingService` / `CaptureUI`.
  - False when idle.
  - True from `startRecording` through the countdown, recording and paused states, and still true while stopping.
  - False after stop, discard, and a countdown that's cancelled.
  - True during a GIF conversion and while the keep-the-video question is open, and false once the result is routed.
  - True while a Studio export is being filed into history, and false after it's filed.
- **Release script (`scripts/release.sh <v> --dry-run`).** Prior art: the designated-requirement pin in spec 0002.
  - A green dry run leaves `build/release/appcast.xml` and the DMG. `sign_update --verify` passes against the keychain key, which equals the built app's `SUPublicEDKey`.
  - The appcast item's `sparkle:version`, `shortVersionString`, `minimumSystemVersion`, length and enclosure URL (`…/releases/download/v<v>/Lightshot-<v>.dmg`) match.
  - With the key absent from the keychain (or `SUPublicEDKey` altered in a scratch branch), preflight fails before building.
  - An unexpected nested Mach-O (not a Sparkle helper) still fails the sign step.
  - `codesign --verify --strict` passes on the app and on each Sparkle helper, and the designated requirement still matches `release-identity.txt`.
- **App side (manual, `.verify` build).** A DEBUG-only launch argument `-updateFeedURL <url>` points Sparkle at a local feed, served by `python3 -m http.server` from a scratch folder. `-checkForUpdatesInBackground YES` runs a scheduled-style check at launch, for the gentle reminder. Sparkle refuses a background check while automatic checks are off, so this turns them on in the running build's defaults; use the `.verify` bundle id and reset its `SU*` defaults before re-testing the second-launch question. `-previewUpdateAvailable <version>` shows the menu-bar dot and the **Update Available…** row without a feed.
  1. Build version N with `--dry-run`, install it to a scratch location, and grant Screen Recording.
  2. Build N+1 with `--dry-run` and serve its DMG and appcast locally.
  3. Launch N with the override, choose **Check for Updates…**, and check the update window: versions and Markdown highlights.
  4. **Install Update**. The app relaunches as N+1 in the same place with no Gatekeeper prompt, and a capture still works (grants carried over).
  5. Repeat with a recording running: the relaunch waits until stop.
  6. A tampered DMG (one byte changed) is refused with Sparkle's signature error.
  7. **Skip This Version**, then a re-check: nothing is offered.
  8. Up to date: a manual check says so. Offline: a manual check shows the error, and a scheduled one is silent.
  9. Gentle reminder: launch with `-checkForUpdatesInBackground YES` and the local feed, leave the app in the background, and screenshot the badged menu-bar icon and the **Update Available…** row (see the macOS 27 status-menu screenshot notes).
  10. Settings: the toggles reflect the second-launch answer, the second toggle disables with the first, and **Check Now** updates "Last checked".
- **Before the first public release with Sparkle:** do one real update through GitHub. Publish N as a normal (not prerelease) release with its feed, install it, publish N+1, and update in-app on a Mac that has never run Lightshot. This observes the permission carry-over and the missing Gatekeeper prompt, which spec 0002 also left as reasoned but unobserved.

## Out of Scope

- Delta updates, update channels (beta or nightly) and phased rollouts.
- A "move to Applications" prompt (LetsMove) for apps run from the DMG or Downloads; Sparkle's error covers it.
- Sending a system profile or any anonymous usage data; `SUEnableSystemProfiling` stays off.
- Sandboxing, Hardened Runtime, notarization and Developer ID (spec 0002's out-of-scope stands).
- Update notifications through Notification Center, which would need a notifications permission; the menu-bar badge covers it.
- A custom update window. Sparkle's standard windows are used as they are.
- Downgrades, and rolling a user back to an earlier version.
- Updating installs older than the first Sparkle-enabled version, which have no updater and update once by hand.

## Further Notes

- **Glossary additions** (`CONTEXT.md`, new *Updates* section):
  - **Update check:** asking the update feed whether a newer version exists. It's either scheduled (daily, only with consent) or manual (Check for Updates…). _Avoid_: ping, phone home, version poll.
  - **Update feed:** the `appcast.xml` published with each GitHub Release that describes the newest version, its DMG, its signature and its highlights. _Avoid_: RSS, manifest.
  - **Update signing key:** the EdDSA key pair that signs the DMG for updates. It's separate from the code-signing certificate, which ties permissions to the app. _Avoid_: Sparkle key, private key (ambiguous with the certificate).
- **Two keys, two jobs.** The code-signing certificate (spec 0002) makes macOS treat each version as the same app, so grants carry over. The update signing key makes Lightshot trust that a download came from the maintainer. Losing either is recoverable but forces every user through a manual step, so both are backed up and pinned.
- **Why the DMG and not a zip.** One artifact serves both the manual download and the in-app update, and the published SHA-256 still describes the file users actually get.
- **Why no `SettingsStore` keys.** Sparkle owns and persists its preferences and reads them at every scheduled check. A mirrored copy in `SettingsStore` could disagree with what Sparkle actually does.
- **First Sparkle release.** Users on 0.6.0 and earlier update to it by hand one last time. That release's notes should say so.
- **Spike results (2026-09-27, Sparkle 2.10.0, macOS 27, throwaway branch).**
  - **In-place update.** An app signed with `Lightshot Release Signing` updated itself from 0.6.90 (build 9000) to 0.6.91 (9001) through a local feed in about 1 s. It relaunched in the same folder with no Gatekeeper prompt, and the new bundle carries no quarantine flag.
  - **Permissions carried over.** `CGPreflightScreenCaptureAccess()` was YES both before and after the update. The designated requirement was unchanged and still matches `release-identity.txt`.
  - **Signing with Sparkle inside.** Stripping Sparkle's XPC services and signing Autoupdate → Updater.app → framework → app, without `--deep`, passes `codesign --verify --strict --deep`.
  - **Update list.** `generate_appcast --ed-key-file` works from a key file (no keychain) and embeds `<version>.md` as `sparkle:format="markdown"`. It adds `sparkle:hardwareRequirements` when the build isn't universal; the release build is universal. `sign_update --verify` rejects a DMG with one changed byte.
  - **Untrusted certificate.** Sparkle checks the new app against the old one's designated requirement. That check passes on a Mac that doesn't trust the certificate (`CSSMERR_TP_NOT_TRUSTED`), tested by calling `SecStaticCodeCheckValidityWithErrors` directly. A different certificate is rejected (`errSecCSReqFailed`). `codesign` can sign with an untrusted identity when it's given the SHA-1 hash and `--keychain`.
  - **Gotchas.**
    - `automaticallyDownloadsUpdates` has no effect while automatic checks are off; Sparkle shows its update window instead. That matches story 28.
    - Release builds redact `NSLog` arguments (`<private>`), so debug logging needs `os_log` with `privacy: .public`.
    - Sparkle warns about an http feed on 127.0.0.1 but allows it, so a local feed works for the manual check.
  - **Not observed.** The first install from a quarantined DMG approved with "Open Anyway", followed by an in-app update, on a Mac that has never run Lightshot. That's the pre-release check above.
