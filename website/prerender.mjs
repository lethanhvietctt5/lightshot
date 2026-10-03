// Runs after both Vite builds: renders the page with the SSR bundle and writes the HTML into
// dist/index.html, so search engines and link previews see the content without running JavaScript.
import { readFile, rm, writeFile } from 'node:fs/promises'

const ssrDir = new URL('./dist-ssr/', import.meta.url)
const indexFile = new URL('./dist/index.html', import.meta.url)

const { render } = await import(new URL('entry-server.js', ssrDir).href)
const template = await readFile(indexFile, 'utf8')
const placeholder = '<div id="root"></div>'
if (!template.includes(placeholder)) throw new Error(`${placeholder} not found in dist/index.html`)

await writeFile(indexFile, template.replace(placeholder, `<div id="root">${render()}</div>`))
await rm(ssrDir, { recursive: true, force: true })
console.log('prerendered dist/index.html')
