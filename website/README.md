# Lightshot website

The one-page landing site for Lightshot ([spec 0017](../specs/0017-landing-page.md)), built from the **"2. Clean"** design in Pencil. React + Vite + TypeScript, plain CSS.

```bash
cd website
npm install
npm run dev       # http://localhost:5173
npm run build     # type-check + production build into dist/, then prerender the page into dist/index.html
npm run lint      # oxlint
npm run preview   # serve dist/ locally
```

## Layout

- `src/sections/` — one component per page section, in page order in `src/App.tsx`.
- `src/components.tsx` — the shared pieces: the capture `Selection` (with its live `W × H` readout), stage `Brackets`, `Keys`, `SectionHead`, the CTA buttons and the GitHub mark.
- `src/index.css` — design tokens (mirroring the Pencil variables) and all styles, section by section, with the responsive rules at the end.
- `src/links.ts` — every outbound link (all to the GitHub repo).
- `src/assets/` — the README screenshots and the app icon as WebP. If a screenshot in `docs/images/` changes, re-export it here.

## SEO and prerendering

`npm run build` runs two Vite builds: the client bundle, then `src/entry-server.tsx` for SSR. Then `prerender.mjs` renders the page into `dist/index.html`, so crawlers and link previews get the full content without JavaScript; the client hydrates it. Components must render the same on the server as on the first client render, so anything measured in the browser (like the selection readouts) starts as `null`. Head metadata lives in `index.html`; the JSON-LD comes from the `structuredData` plugin in `vite.config.ts`. `public/` holds `og.png` and Google Search Console's verification file; the matching `google-site-verification` meta tag is in `index.html`. Keep both, or Search Console loses ownership. `robots.txt` and `sitemap.xml` are generated. If the domain changes, update it in `index.html`, `vite.config.ts`, `robots.txt` and `sitemap.xml` ([spec 0018](../specs/0018-landing-seo-and-motion.md)).

Motion is CSS only, in the *Motion* section at the end of `src/index.css`. Every animation ends on the static design and respects `prefers-reduced-motion`. Don't hide content that waits for JavaScript to reveal it.

The version badge in the hero is the newest `docs/releases/<version>.md`, read at build time by `vite.config.ts`; it updates with each release's notes and needs no code change.

## Rules

- **No third-party requests.** Fonts are self-hosted (`@fontsource-variable`), images are local, and there are no analytics or embeds. The only way off the page is a link the visitor clicks. Keep it that way — it's the product's promise.
- **Copy must stay true to the app.** Default hotkeys come from `HotkeyBindings.defaults`; only Blackout is ever described as secure redaction; Auto Redact always carries its "can miss things" caveat.

## Deploying on Vercel

Import the repository in Vercel and set **Root Directory** to `website`. Vercel detects Vite and uses `npm run build` with `dist` as the output — no `vercel.json` needed. Leave "Include files outside the Root Directory in the Build Step" on (the default), so the build can read `docs/releases/` for the version badge; without it, the badge is simply hidden.
