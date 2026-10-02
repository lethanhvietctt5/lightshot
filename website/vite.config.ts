import { readdirSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import react from '@vitejs/plugin-react'
import { defineConfig } from 'vite'

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

// https://vite.dev/config/
export default defineConfig({
  plugins: [react()],
  define: {
    __LATEST_VERSION__: JSON.stringify(latestReleaseVersion()),
  },
})
