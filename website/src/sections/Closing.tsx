import appIcon from '../assets/app-icon.webp'
import { CtaButtons, Selection } from '../components'
import { links } from '../links'

export function FinalCta() {
  return (
    <section className="final container" aria-labelledby="final-title">
      <img src={appIcon} width={104} height={104} alt="" loading="lazy" />
      <h2 id="final-title" className="final-title">
        Try it on your <Selection>next screenshot.</Selection>
      </h2>
      <p className="final-sub">Free, MIT licensed, and yours to read line by line.</p>
      <CtaButtons />
      <p className="mono-meta">macOS 14 Sonoma or later · Apple Silicon and Intel</p>
    </section>
  )
}

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
