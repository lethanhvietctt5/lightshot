import type { ReactNode } from 'react'
import { Download } from 'lucide-react'
import { links } from './links'
import { useElementSize } from './useElementSize'

/** GitHub's mark, inline: Lucide no longer ships brand icons. */
export function GitHubMark({ size = 16 }: { size?: number }) {
  return (
    <svg width={size} height={size} viewBox="0 0 24 24" fill="currentColor" aria-hidden="true">
      <path d="M12 .297c-6.63 0-12 5.373-12 12 0 5.303 3.438 9.8 8.205 11.385.6.113.82-.258.82-.577 0-.285-.01-1.04-.015-2.04-3.338.724-4.042-1.61-4.042-1.61C4.422 18.07 3.633 17.7 3.633 17.7c-1.087-.744.084-.729.084-.729 1.205.084 1.838 1.236 1.838 1.236 1.07 1.835 2.809 1.305 3.495.998.108-.776.417-1.305.76-1.605-2.665-.3-5.466-1.332-5.466-5.93 0-1.31.465-2.38 1.235-3.22-.135-.303-.54-1.523.105-3.176 0 0 1.005-.322 3.3 1.23.96-.267 1.98-.399 3-.405 1.02.006 2.04.138 3 .405 2.28-1.552 3.285-1.23 3.285-1.23.645 1.653.24 2.873.12 3.176.765.84 1.23 1.91 1.23 3.22 0 4.61-2.805 5.625-5.475 5.92.42.36.81 1.096.81 2.22 0 1.606-.015 2.896-.015 3.286 0 .315.21.69.825.57C20.565 22.092 24 17.592 24 12.297c0-6.627-5.373-12-12-12" />
    </svg>
  )
}

/**
 * Wraps text in Lightshot's capture selection: a blue outline with corner handles and a live
 * `W × H` readout of its own size, the way the Capture Area overlay shows it.
 */
export function Selection({ children }: { children: ReactNode }) {
  const [ref, size] = useElementSize<HTMLSpanElement>()
  return (
    <span ref={ref} className="selection">
      {children}
      <span className="selection-handle tl" aria-hidden="true" />
      <span className="selection-handle tr" aria-hidden="true" />
      <span className="selection-handle bl" aria-hidden="true" />
      <span className="selection-handle br" aria-hidden="true" />
      {size && (
        <span className="selection-size" aria-hidden="true">
          {size.width} × {size.height}
        </span>
      )}
    </span>
  )
}

/** Four capture-corner brackets inside a positioned stage. */
export function Brackets() {
  return (
    <>
      <span className="bracket tl" aria-hidden="true" />
      <span className="bracket tr" aria-hidden="true" />
      <span className="bracket bl" aria-hidden="true" />
      <span className="bracket br" aria-hidden="true" />
    </>
  )
}

export function Keys({ children, label }: { children: ReactNode; label?: string }) {
  return (
    <kbd className="keys" aria-label={label}>
      {children}
    </kbd>
  )
}

export function SectionHead({
  index,
  label,
  title,
  body,
}: {
  index: string
  label: string
  title: ReactNode
  body?: ReactNode
}) {
  return (
    <div className="section-head">
      <div className="section-index" aria-hidden="true">
        <span className="section-num">{index}</span>
        <span className="section-rule" />
        <span className="section-label">{label}</span>
      </div>
      <div className="section-copy">
        <h2 className="h2">{title}</h2>
        {body && <p className="section-body">{body}</p>}
      </div>
    </div>
  )
}

export function CtaButtons() {
  return (
    <div className="ctas">
      <a className="button button-primary" href={links.latestRelease}>
        <Download size={18} aria-hidden="true" />
        Download for macOS
      </a>
      <a className="button button-secondary" href={links.repo}>
        <GitHubMark size={18} />
        Star on GitHub
      </a>
    </div>
  )
}
