import {
  AppWindow,
  Crop,
  Focus,
  Highlighter,
  ListOrdered,
  Lock,
  Monitor,
  MoveUpRight,
  PenLine,
  ScanText,
  Square,
  SquareAsterisk,
  SquareDashed,
  Type,
  Undo2,
  WandSparkles,
} from 'lucide-react'
import { Handles, Keys, SectionHead } from '../components'

// Default hotkeys are the ones in LightshotKit's `HotkeyBindings.defaults`; the other two have
// none until the user sets one.
const modes = [
  {
    Icon: SquareDashed,
    title: 'Area',
    keys: { glyphs: '⌃⌘4', spoken: 'Control Command 4' },
    desc: 'Drag to select, with live pixel size and edges you can adjust before you shoot.',
  },
  {
    Icon: AppWindow,
    title: 'Window',
    keys: null,
    desc: 'Hover to highlight a window, click to capture just that window, with nothing overlapping it.',
  },
  {
    Icon: Monitor,
    title: 'Full display',
    keys: { glyphs: '⌃⌘3', spoken: 'Control Command 3' },
    desc: 'Grab a whole screen, or pick which one on a multi-display setup.',
  },
  {
    Icon: ScanText,
    title: 'OCR Text',
    keys: null,
    desc: 'Drag over anything to copy its text. QR codes and barcodes are decoded too.',
  },
]

const redactedRows = [
  ['To', 188],
  ['Cc', 232],
  ['API key', 260],
  ['Card', 168],
  ['Reply-to', 204],
] as const

const tools = [
  [MoveUpRight, 'Arrows'],
  [Square, 'Shapes'],
  [PenLine, 'Freehand'],
  [Type, 'Text'],
  [Highlighter, 'Highlight'],
  [ListOrdered, 'Step numbers'],
  [Focus, 'Focus'],
  [Crop, 'Crop'],
  [SquareAsterisk, 'Redact'],
  [Undo2, 'Undo / redo'],
] as const

export function Screenshots() {
  return (
    <section className="section container" id="screenshots">
      <SectionHead
        index="01"
        label="Screenshots"
        title="Capture it, mark it up, and it's on your clipboard."
        body="Drag out an area, click a window or take the whole display, each from its own shortcut. Every tool sits in one toolbar row, and copy, save and pin are one click away."
      />

      <ul className="columns modes">
        {modes.map(({ Icon, title, keys, desc }) => (
          <li key={title} className="mode">
            <Icon size={24} aria-hidden="true" />
            <div className="mode-title">
              <h3>{title}</h3>
              {keys ? <Keys {...keys} /> : <span className="keys">Rebindable</span>}
            </div>
            <p>{desc}</p>
          </li>
        ))}
      </ul>

      <div className="redact">
        <div className="redact-visual" aria-hidden="true">
          <div className="redact-stack">
            <div className="mock">
              <div className="mock-bar">
                <span className="light red" />
                <span className="light yellow" />
                <span className="light green" />
              </div>
              <div className="mock-rows">
                {redactedRows.map(([key, width]) => (
                  <div key={key} className="mock-row">
                    <span className="mock-key">{key}</span>
                    {key === 'API key' ? (
                      <span className="mock-selection">
                        <span className="blackout" style={{ width }} />
                        <Handles />
                      </span>
                    ) : (
                      <span className="blackout" style={{ width }} />
                    )}
                  </div>
                ))}
                <p className="mock-message">
                  Hi team, sharing the staging keys so you can test the export flow before Friday.
                </p>
              </div>
            </div>
            <div className="toast">
              <span className="toast-icon">
                <WandSparkles size={18} />
              </span>
              <span className="toast-text">
                <strong>Redacted 5 items: 3 emails, 1 card, 1 secret</strong>
                <span>Text recognition can miss things. Check before sharing.</span>
              </span>
            </div>
          </div>
        </div>

        <div className="redact-copy">
          <p className="kicker">
            <WandSparkles size={16} aria-hidden="true" />
            Auto Redact
            <Keys glyphs="⇧⌘R" spoken="Shift Command R" />
          </p>
          <h3 className="h3">Find keys, emails and card numbers, and redact them in one keystroke.</h3>
          <p className="body-lg">
            Text recognition runs on your Mac, finds what shouldn't leave the screenshot and redacts
            it in the style you've picked. It can miss things, so check before you share.
          </p>
          <div className="detects">
            <p className="detects-label">Detects</p>
            <p className="detects-list">
              API keys · Passwords · Card numbers · IBANs · Emails · Phone numbers · IP addresses ·
              QR codes
            </p>
          </div>
          <p className="secure-note">
            <Lock size={16} aria-hidden="true" />
            <span>
              Pick Blackout for anything secret: it erases the pixels underneath. Blur and pixelate
              only obscure, so never use them for secrets.
            </span>
          </p>
        </div>
      </div>

      <div className="tools">
        <ul className="toolbar" aria-labelledby="tools-label">
          {tools.map(([Icon, label], index) => (
            <li key={label} className={index === 0 ? 'tool tool-active' : 'tool'}>
              <Icon size={16} aria-hidden="true" />
              {label}
            </li>
          ))}
        </ul>
        <p id="tools-label" className="mono-meta">
          Every annotation tool in one toolbar row
        </p>
      </div>
    </section>
  )
}
