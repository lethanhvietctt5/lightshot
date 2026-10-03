# Spec 0018 — Landing page: SEO and motion

**Status:** implemented — see *As built* at the end
**Linear:** [LIG-79](https://linear.app/light-shot/issue/LIG-79) (label `ready-for-agent`)
**Platform:** Static website — React + Vite + TypeScript, deployed on Vercel
**Scope:** `website/` only. Follows [spec 0017](0017-landing-page.md); its rules still hold (no third-party requests, copy true to the app). Nothing in `App/` or `LightshotKit/` changes.

---

## Problem Statement

The landing page at https://lightshot-mac.vercel.app is a client-rendered SPA. `index.html` ships an empty `#root`, so crawlers and link previews that don't run JavaScript see no content. It has no canonical URL, no share image, no structured data, and no robots.txt or sitemap. The page is also entirely static.

## Solution

**SEO**

* **Prerender.** `npm run build` also builds `src/entry-server.tsx` for SSR and runs `prerender.mjs`, which writes the rendered page into `dist/index.html`. The client hydrates it (`hydrateRoot`); the dev server still renders from scratch. No new dependency, and Vercel still runs `npm run build`.
* **Head metadata.** Canonical URL, `og:url`, `og:site_name`, a 1200×630 `og:image` (`public/og.png`) with its size and alt text, and a `summary_large_image` Twitter card.
* **Structured data.** A JSON-LD `SoftwareApplication` (free, macOS 14 or later, MIT, download URL, share image, author), injected by a Vite plugin so it is always valid JSON. `softwareVersion` comes from `docs/releases/`, like the version badge. It makes the page eligible for richer listings; Google's software rich result also needs ratings or reviews, which the site doesn't have.
* **Crawl files.** `robots.txt` and `sitemap.xml`, generated at build time by the same plugin.
* **One site URL.** `site` in `src/links.ts`. The plugin fills `%SITE_URL%` in `index.html` and builds the JSON-LD, robots.txt and sitemap from it.
* **Copy aimed at real queries.** The title and description say "free, open-source screenshot and screen recorder for Mac". The hero eyebrow says the same. The footer says "A free, local-only alternative to CleanShot X", from AGENTS.md's description of the app.
* **LCP.** The hero screenshot is in the prerendered HTML with `fetchPriority="high"`, so the browser finds it without running the bundle.

**Motion**

* CSS only, no motion library. Every animation sits inside `prefers-reduced-motion: no-preference`.
* Every animation is an entrance or a hover that ends on the static design. Nothing is hidden waiting for JavaScript, so the prerendered page is complete with scripts off.
* On load, the hero copy rises line by line, the selection draws itself around "anything", its handles pop, the screenshot tilts up into place, and its brackets snap in. The capture caption's dot pulses.
* On scroll, where `animation-timeline` is supported, section heads, columns and list rows rise into view. The recording and Studio screenshots settle into their stages. In the Auto Redact mock, the blackout boxes wipe across one by one before the toast arrives. The final CTA's selection draws itself as it arrives. The nav picks up a shadow once the page scrolls. Browsers without scroll timelines show the static page.
* On hover, buttons lift, and the primary button catches a sweep of light while its icon nudges down. Nav links get an underline, and the icons in the trust strip, capture modes and feature list tilt.

## Testing Decisions

* `npm run build` and `npm run lint` pass. `dist/index.html` contains the page copy and valid JSON-LD.
* Headless Chrome on the production build (`vite preview`) logs no console messages, so there are no hydration errors.
* The page makes requests only to its own origin.
* No horizontal scroll at 390 px (mobile emulation), 820 px or 1440 px.
* With JavaScript disabled, the page renders in full.

## Out of Scope

* Off-site work that decides ranking: Search Console, directory listings and launch posts. The maintainer does these.
* Analytics, a custom domain, an FAQ section, or new pages.
* Changing the design's headlines.

## As built

* **Verified** on the production build in headless Chrome over CDP:
  * At 1440, 820 and 390 px (mobile), `scrollWidth` equals the viewport width.
  * The console is empty, and the only requests go to `localhost`.
  * The live selection readouts show `349 × 92` at 1440 px, as before, so hydration ran.
  * With scripts disabled, the full page renders without the readouts.
  * Mid-scroll captures show the redact wipes progressing.
* **The nav shadow only.** The scroll-linked nav first also lowered the background's opacity. Headless screenshots skip `backdrop-filter`, which exposed how much content showed through, so the background is unchanged.
* **Self-review fixes:**
  * **Share image alt text.** It first said Auto Redact covered emails and an API key, without the "can miss things" caveat. It now describes the image itself.
  * **One site URL.** The address was hard-coded in six places across four files. It is now `site` in `src/links.ts`, and robots.txt and the sitemap are generated. The JSON-LD reuses `links.latestRelease` and `links.license`, and drops `codeRepository`, which isn't a `SoftwareApplication` property.
  * **Selection draw.** It now uses `backwards` fill, so no clip-path lingers after it draws. The final CTA's selection draws on scroll instead of at load, where nobody would see it. Only the hero's brackets animate at load.
  * **Redact timing.** The toast now starts after the last box finishes wiping.
  * **Buttons.** `position: relative` and `overflow: hidden` moved to the base `.button` rule, so layout doesn't depend on the motion preference.
* The page is 8,449 px tall at 1440 px. It was 8,413 px; the footer's added line accounts for the difference.
