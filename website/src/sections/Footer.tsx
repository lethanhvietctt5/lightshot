import appIcon from '../assets/app-icon.webp'
import { links } from '../links'

export function Footer() {
  return (
    <footer className="footer">
      <div className="footer-inner container">
        <div className="footer-brand">
          <img src={appIcon} width={22} height={22} alt="" loading="lazy" />
          <span className="footer-wordmark">Lightshot</span>
          <a className="mono-meta" href={links.license}>
            © 2026 Viet Le · MIT License
          </a>
        </div>
        <p className="footer-about">A free, local-only alternative to CleanShot X.</p>
        <nav className="footer-links" aria-label="Project">
          <a href={links.repo}>GitHub</a>
          <a href={links.releases}>Releases</a>
          <a href={links.releaseNotes}>Release notes</a>
          <a href={links.issues}>Report an issue</a>
        </nav>
      </div>
    </footer>
  )
}
