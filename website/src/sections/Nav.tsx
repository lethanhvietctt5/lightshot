import { Download } from 'lucide-react'
import appIcon from '../assets/app-icon.webp'
import { GitHubMark } from '../components'
import { links } from '../links'

const sections = [
  ['Screenshots', '#screenshots'],
  ['Recording', '#recording'],
  ['Studio', '#studio'],
  ['Privacy', '#privacy'],
  ['Install', '#install'],
] as const

export function Nav() {
  return (
    <header className="nav">
      <div className="nav-inner">
        <a className="brand" href="#top" aria-label="Lightshot, back to top">
          <img src={appIcon} width={28} height={28} alt="" />
          <span className="wordmark">Lightshot</span>
        </a>
        <nav className="nav-links" aria-label="Sections">
          {sections.map(([label, href]) => (
            <a key={href} href={href}>
              {label}
            </a>
          ))}
        </nav>
        <div className="nav-actions">
          <a className="nav-github" href={links.repo}>
            <GitHubMark />
            <span className="nav-github-label">GitHub</span>
          </a>
          <a className="button button-primary button-small" href={links.latestRelease}>
            <Download size={16} aria-hidden="true" />
            Download
          </a>
        </div>
      </div>
    </header>
  )
}
