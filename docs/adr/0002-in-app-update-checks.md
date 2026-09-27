# In-app update checks are Lightshot's one network access

**Status:** accepted (spec 0015, LIG-73)

Lightshot promised "no cloud, no accounts, no network", and the guardrail in `AGENTS.md` forbade networking outright. Spec 0015 makes one exception: the app checks GitHub Releases for a newer version and installs it, through **Sparkle 2**. Everything else in the guardrail stands: no accounts, analytics, telemetry or cloud upload, and screenshots, recordings, OCR text and captions never leave the Mac.

What goes over the network, and only this:

- an HTTPS GET for `https://github.com/lethanhvietctt5/lightshot/releases/latest/download/appcast.xml` (the update feed), and, when the user installs, a GET for that release's DMG;
- Sparkle's standard `User-Agent` (app name and version). `SUEnableSystemProfiling` is off, so no system profile is sent.

When it happens: only after the user agrees. There is no `SUEnableAutomaticChecks` in `Info.plist`, so nothing is checked until Sparkle's second-launch question is answered yes or the user chooses **Check for Updates…**. Automatic checks can be turned off in Settings → General → Updates.

Trust: every DMG is signed with the maintainer's EdDSA update signing key, and the app refuses one that doesn't verify against `SUPublicEDKey`. Sparkle also requires the new app to satisfy the running app's designated requirement, which the pinned self-signed certificate (spec 0002) guarantees.

A future feature that needs the network is not covered by this exception; it needs its own decision.

## Considered options

- **Stay offline; users update from the DMG by hand.** It keeps the promise literally, but in practice users stay on old builds, and every manual update brings back the Gatekeeper warning.
- **A hand-rolled updater (GitHub API → download → mount → replace → relaunch).** Same network use, more code, less scrutiny, and no signature scheme unless we invent one.
- **Automatic checks on by default.** Fewer stale installs, but it would reach the network before the user said yes.
