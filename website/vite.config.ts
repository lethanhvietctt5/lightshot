import { readdirSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import react from '@vitejs/plugin-react'
import { defineConfig, type Plugin } from 'vite'

// The production address; canonical, Open Graph and sitemap URLs are built from it.
const siteUrl = 'https://lightshot-mac.vercel.app/'
const repo = 'https://github.com/lethanhvietctt5/lightshot'

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

// Structured data for search engines: what the app is, what it runs on and that it's free.
// Injected as JSON so it is always valid, with the version read from the release notes.
function structuredData(): Plugin {
  const data = {
    '@context': 'https://schema.org',
    '@type': 'SoftwareApplication',
    name: 'Lightshot',
    description:
      'Free, open-source screenshot and screen recording app for macOS. Capture, annotate, redact and record your screen, and edit recordings in a built-in video editor. Everything runs on your Mac.',
    url: siteUrl,
    applicationCategory: 'MultimediaApplication',
    operatingSystem: 'macOS 14 or later',
    ...(latestVersion && { softwareVersion: latestVersion }),
    downloadUrl: `${repo}/releases/latest`,
    license: `${repo}/blob/main/LICENSE`,
    codeRepository: repo,
    isAccessibleForFree: true,
    offers: { '@type': 'Offer', price: '0', priceCurrency: 'USD' },
    image: `${siteUrl}og.png`,
    screenshot: `${siteUrl}og.png`,
    author: { '@type': 'Person', name: 'Viet Le', url: 'https://github.com/lethanhvietctt5' },
  }
  return {
    name: 'structured-data',
    transformIndexHtml: () => [
      {
        tag: 'script',
        attrs: { type: 'application/ld+json' },
        children: JSON.stringify(data),
        injectTo: 'head',
      },
    ],
  }
}

// https://vite.dev/config/
export default defineConfig({
  plugins: [react(), structuredData()],
  define: {
    __LATEST_VERSION__: JSON.stringify(latestVersion),
  },
})
