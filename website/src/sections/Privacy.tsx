import { SectionHead } from '../components'

const numbers = [
  ['0', 'accounts', 'There is nothing to sign up for. Open the app and capture.'],
  ['0', 'uploads', 'Shots and recordings are saved where you choose. History stays on disk.'],
  ['0', 'cloud transcription', 'Captions and text recognition use models built into macOS.'],
  ['1', 'network request', 'An update check against GitHub, about once a day. Turn it off in Settings.'],
] as const

export function Privacy() {
  return (
    <section className="section section-privacy container" id="privacy">
      <SectionHead
        index="04"
        label="Privacy"
        title={
          <span className="privacy-title">
            Your screen holds your passwords, your clients and your unread messages.{' '}
            <span className="muted-heading">
              None of it should leave your Mac just because you took a screenshot.
            </span>
          </span>
        }
      />
      <dl className="columns numbers">
        {numbers.map(([value, unit, desc]) => (
          <div key={unit} className="number">
            <dt>
              <span className={value === '1' ? 'number-value accent' : 'number-value'}>{value}</span>
              <span className="number-unit">{unit}</span>
            </dt>
            <dd>{desc}</dd>
          </div>
        ))}
      </dl>
    </section>
  )
}
