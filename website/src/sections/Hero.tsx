import editor from '../assets/editor.webp'
import { Brackets, CtaButtons, Selection } from '../components'
import { useElementSize } from '../useElementSize'

export function Hero() {
  const [shotRef, shotSize] = useElementSize<HTMLImageElement>()

  return (
    <section className="hero container" id="top">
      <div className="hero-copy">
        <div className="hero-meta">
          {__LATEST_VERSION__ && <span className="version">v{__LATEST_VERSION__}</span>}
          <span className="eyebrow">Free and open source for macOS 14+</span>
        </div>
        <h1 className="hero-title">
          <span className="hero-line">
            Show <Selection>anything</Selection> on your screen.
          </span>{' '}
          <span className="hero-line hero-line-muted">Share nothing you didn't mean to.</span>
        </h1>
        <div className="hero-sub">
          <p className="hero-lede">
            Lightshot captures, annotates and records your Mac's screen, with a video editor built
            in. It all runs on your Mac: no account, no cloud, no uploads.
          </p>
          <div className="hero-cta">
            <CtaButtons />
            <p className="mono-meta">Free · Apple Silicon and Intel · macOS 14 Sonoma or later</p>
          </div>
        </div>
      </div>

      <div className="stage hero-stage">
        <img
          ref={shotRef}
          className="hero-shot"
          src={editor}
          width={1600}
          height={1194}
          alt="The Lightshot annotation editor showing a dashboard screenshot. Auto Redact has covered three email addresses and an API key with solid black boxes, and a notice reads: Redacted 4 items — 3 emails, 1 secret."
        />
        <Brackets />
        <p className="stage-caption" aria-hidden="true">
          <span className="rec-dot" />
          ⌃⌘4 · Area capture{shotSize && ` · ${shotSize.width} × ${shotSize.height}`}
        </p>
      </div>
    </section>
  )
}
