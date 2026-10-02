import { BellOff, Keyboard, Mic, MousePointerClick, Video } from 'lucide-react'
import recording from '../assets/recording.webp'
import { Brackets, SectionHead } from '../components'

const options = [
  [Mic, 'Microphone and computer audio', null],
  [Video, 'Camera bubble', 'Drag it anywhere'],
  [MousePointerClick, 'Click highlights', null],
  [Keyboard, 'Keystrokes', 'Hidden in password fields'],
  [BellOff, 'Hide notifications', 'Leaves your Focus settings alone'],
] as const

export function Recording() {
  return (
    <section className="section section-recording container" id="recording">
      <SectionHead
        index="02"
        label="Recording"
        title="Record exactly the part that matters."
        body="Record an area, a window or a display as video or GIF. Dim everything outside the frame if you like, and a small pill keeps pause, stop, restart and discard in reach."
      />

      <div className="recording-split">
        <ul className="options">
          {options.map(([Icon, label, detail]) => (
            <li key={label}>
              <Icon size={18} aria-hidden="true" />
              <span>
                <span className="option-label">{label}</span>
                {detail && <span className="option-detail">{detail}</span>}
              </span>
            </li>
          ))}
        </ul>
        <div className="stage recording-stage">
          <img
            className="recording-shot"
            src={recording}
            width={1600}
            height={1039}
            loading="lazy"
            alt="A screen recording in progress. A red border marks the recorded area around a dashboard's charts, the rest of the screen is dimmed, and a small controls pill at the bottom shows 00:12, a microphone level meter, and pause, stop, restart and discard buttons."
          />
          <Brackets />
        </div>
      </div>
    </section>
  )
}
