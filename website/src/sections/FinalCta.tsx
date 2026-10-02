import appIcon from '../assets/app-icon.webp'
import { CtaButtons, Selection } from '../components'

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
