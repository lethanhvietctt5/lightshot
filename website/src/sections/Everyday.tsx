import { Command, History, Languages, Layers, Pin, SunMoon, Timer } from 'lucide-react'
import { SectionHead } from '../components'

const features = [
  [Layers, 'Quick Access Overlay', 'Each capture waits as a card in a corner of the screen. Copy, save, annotate, pin, or drag it straight into another app.'],
  [Pin, 'Pin it on top', 'Float a screenshot above every window while you type from it.'],
  [Languages, 'Copy text, then translate it', "Recognised on your Mac, translated with macOS's built-in translation."],
  [History, 'Local history', 'Reopen, reveal in Finder or delete. You set how long it keeps things.'],
  [Timer, 'Capture options', 'Self-timer, cursor, repeat last capture, hide desktop icons.'],
  [Command, 'Rebindable shortcuts', 'Give any capture its own global hotkey. Clashes are flagged.'],
  [SunMoon, 'Light and Dark', 'Follows the system, or pick one in Settings.'],
] as const

export function Everyday() {
  return (
    <section className="section section-everyday container" id="everyday">
      <SectionHead
        index="05"
        label="Everyday"
        title={
          <>
            And the small things <br className="desktop-break" />
            you'll use every day.
          </>
        }
      />
      <ul className="feature-list">
        {features.map(([Icon, title, desc]) => (
          <li key={title}>
            <span className="feature-title">
              <Icon size={20} aria-hidden="true" />
              <h3>{title}</h3>
            </span>
            <p>{desc}</p>
          </li>
        ))}
      </ul>
    </section>
  )
}
