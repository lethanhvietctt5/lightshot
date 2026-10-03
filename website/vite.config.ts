import { readdirSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import react from '@vitejs/plugin-react'
import { defineConfig, type Plugin } from 'vite'
import { links, site } from './src/links.ts'

// The version badge shows the newest release that has notes in docs/releases/, read at build
// time so the page never makes a request for it. Missing folder (e.g. a build outside the repo)
// → null, and the badge is hidden.
function latestReleaseVersion(): string | null {
  try {
    const dir = fileURLToPath(new URL('../docs/releases', import.meta.url))
    const versions = readdirSync(dir)
      .map((name) => /^(\d+)\.(\d+)\.(\d+)\.md$/.exec(name))
      .filter((match) => match !== null)
      .map((match) => match.slice(1, 4).map(Number))
      .sort((a, b) => a[0] - b[0] || a[1] - b[1] || a[2] - b[2])
    return versions.length ? versions[versions.length - 1].join('.') : null
  } catch {
    return null
  }
}

const latestVersion = latestReleaseVersion()

// Everything search engines read, built from the one site URL in src/links.ts: `%SITE_URL%` in
// index.html, the JSON-LD (what the app is, what it runs on, that it's free; injected as JSON so
// it is always valid, with the version from the release notes), robots.txt and the sitemap.
function seo(): Plugin {
  const data = {
    '@context': 'https://schema.org',
    '@type': 'SoftwareApplication',
    name: 'Lightshot',
    description:
      'Free, open-source screenshot and screen recording app for macOS. Capture, annotate, redact and record your screen, and edit recordings in a built-in video editor. Everything runs on your Mac.',
    url: site,
    applicationCategory: 'MultimediaApplication',
    operatingSystem: 'macOS 14 or later',
    ...(latestVersion && { softwareVersion: latestVersion }),
    downloadUrl: links.latestRelease,
    license: links.license,
    isAccessibleForFree: true,
    offers: { '@type': 'Offer', price: '0', priceCurrency: 'USD' },
    image: `${site}og.png`,
    screenshot: `${site}og.png`,
    author: { '@type': 'Person', name: 'Viet Le', url: 'https://github.com/lethanhvietctt5' },
  }
  return {
    name: 'seo',
    transformIndexHtml: (html) => ({
      html: html.replaceAll('%SITE_URL%', site),
      tags: [
        {
          tag: 'script',
          attrs: { type: 'application/ld+json' },
          children: JSON.stringify(data),
          injectTo: 'head',
        },
      ],
    }),
    generateBundle() {
      this.emitFile({
        type: 'asset',
        fileName: 'robots.txt',
        source: `User-agent: *\nAllow: /\n\nSitemap: ${site}sitemap.xml\n`,
      })
      this.emitFile({
        type: 'asset',
        fileName: 'sitemap.xml',
        source: `<?xml version="1.0" encoding="UTF-8"?>\n<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n  <url>\n    <loc>${site}</loc>\n  </url>\n</urlset>\n`,
      })
    },
  }
}

// https://vite.dev/config/
export default defineConfig({
  plugins: [react(), seo()],
  define: {
    __LATEST_VERSION__: JSON.stringify(latestVersion),
  },
})
