# Spec 0017 — Landing page

**Status:** in progress
**Linear:** [LIG-77](https://linear.app/light-shot/issue/LIG-77) (label `ready-for-agent`)
**Platform:** Static website — React + Vite + TypeScript, deployed on Vercel
**Scope:** A one-page marketing site for Lightshot in `website/`, built from the **"2. Clean"** variant of the landing-page design in Pencil. It is a static build with no backend, no analytics, no cookies and no third-party requests: fonts and images are served from the site itself, and the only way off the page is a link the visitor clicks (GitHub). Nothing in `App/` or `LightshotKit/` changes.

---

## Problem Statement

Lightshot has a README and a Releases page, but nowhere to send someone who asks "what is it, and why would I use it over the screenshot tool I have?" The README is written for people who already decided to install it. A visitor needs the pitch in one screen, proof that it's local-only, and an honest install path, including the first-launch warning, because the app isn't notarized.

## Solution

A single page at the site root, matching the Clean design at 1440 px wide and reflowing for tablets and phones. Sections, top to bottom:

1. **Nav** — app icon and wordmark, anchor links (Screenshots, Recording, Studio, Privacy, Install), GitHub, Download.
2. **Hero** — "Show anything on your screen. Share nothing you didn't mean to.", with "anything" drawn as a capture selection (handles and a live `W × H` readout). Subhead, **Download for macOS** and **Star on GitHub**, requirements line, and the editor screenshot on a stage with capture brackets.
3. **Trust strip** — no account, nothing uploaded, captions on-device, MIT licensed, Apple Silicon and Intel.
4. **01 Screenshots** — capture modes with their real default shortcuts (⌃⌘4 Area, ⌃⌘3 Full display; Window and OCR Text are rebindable with no default), the Auto Redact feature (⇧⌘R) with its "can miss things" caveat and the Blackout-vs-blur note, and the annotation toolbar.
5. **02 Recording** — recording options and the recording screenshot.
6. **03 Studio** (dark) — the Studio screenshot and four Studio features.
7. **04 Privacy** — "0 accounts · 0 uploads · 0 cloud transcription · 1 network request" (the optional update check).
8. **05 Everyday** — Quick Access Overlay, Pin, OCR + Translate, history, capture options, shortcuts, Light and Dark.
9. **06 Install** — three steps including Open Anyway and the `xattr` command (with a copy button), checksum / build-from-source / signed-updates notes.
10. **Final CTA and footer.**

Download links go to the latest GitHub release. The version badge comes from the newest file in `docs/releases/` at build time, so it can't drift from the shipped notes.

## User Stories

1. As a visitor, I want the first screen to tell me what Lightshot does, that it's free, and that it runs on my Mac, so that I can decide in seconds whether to read on.
2. As a visitor, I want a Download button that takes me to the latest release, so that I can install it without hunting.
3. As a visitor, I want to see real screenshots of the editor, the recorder and the Studio, so that I know what I'm getting.
4. As a privacy-minded visitor, I want the page to say exactly what leaves my Mac (one optional update check), so that I can trust the claim.
5. As a privacy-minded visitor, I want the site itself to make no tracking or third-party requests, so that the site behaves like the app.
6. As a visitor about to share redacted screenshots, I want the page to say Auto Redact can miss things and that only Blackout is secure, so that I'm not misled.
7. As a new user, I want honest install steps, including the first-launch warning and how to allow it, so that the warning doesn't look like malware.
8. As a new user, I want to copy the `xattr` command with one click, so that I don't mistype it.
9. As a phone or tablet visitor, I want the page to reflow without horizontal scrolling, so that I can read it anywhere.
10. As a keyboard or screen-reader user, I want real headings, link semantics, alt text and visible focus, so that the page is usable without a mouse.

## Implementation Decisions

* **Location:** `website/`, a standalone npm project. Vercel deploys it with Root Directory = `website`; the framework preset (Vite) needs no extra config.
* **Stack:** React 19 + Vite + TypeScript, plain CSS with custom properties mirroring the Pencil variables (`--ink`, `--muted`, `--line`, `--accent`, `--night*`). No CSS framework.
* **Fonts:** Geist and Geist Mono, self-hosted through `@fontsource-variable`. No Google Fonts request.
* **Icons:** `lucide-react`, matching the design's Lucide icons. The GitHub mark is an inline SVG (Lucide's brand icons are deprecated).
* **Images:** the README screenshots and the app icon, converted to WebP and sized for 2× display at their rendered width. Alt text reuses the README's.
* **Copy:** taken verbatim from the Clean design, which was checked against the code and specs (default hotkeys from `HotkeyBinding.defaults`, the trimmed window shadow from spec 0011, the Open Anyway order from the README).

## Testing Decisions

* `npm run build` (type check + production build) and `npm run lint` pass.
* Visual check against the Pencil export at 1440 px, section by section, plus phone (390 px) and tablet (~820 px) widths with no horizontal scroll.
* Network check: the built page loads with requests only to its own origin.

## Out of Scope

* A docs site, blog, changelog pages or localisation.
* Analytics, newsletter sign-up, or any form.
* A direct DMG download link (the DMG file name carries the version; the link goes to the release page instead).
* A custom domain and the Vercel project setup itself (the maintainer does that).
