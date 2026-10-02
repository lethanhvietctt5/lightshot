import { Captions, Film, MousePointer2, ZoomIn } from 'lucide-react'
import studio from '../assets/studio.webp'
import { Brackets, SectionHead } from '../components'

const features = [
  [ZoomIn, 'Auto Zoom', 'Zooms are suggested from your clicks. Pin them, retime them or follow the cursor.'],
  [MousePointer2, 'A cursor you can redraw', 'Change its size, smoothing and click effects, or hide it when idle.'],
  [Captions, 'Captions made on your Mac', 'Transcribe narration on-device, burn in captions, cut speech by selecting words.'],
  [Film, 'MP4 or GIF, up to 4K', 'H.264 or HEVC at 24, 30 or 60 fps, with a size estimate before you export.'],
] as const

export function Studio() {
  return (
    <section className="section-dark" id="studio">
      <div className="section container">
        <SectionHead
          index="03"
          label="Studio"
          title="Every take stays editable after you stop recording."
          body="Lightshot records the screen, pointer, clicks, keystrokes and camera separately. Change the zoom, the cursor or the captions later. Nothing is baked in until you export."
        />
        <div className="stage studio-stage">
          <img
            className="studio-shot"
            src={studio}
            width={1800}
            height={1182}
            loading="lazy"
            alt="The Studio editor. A preview shows a recorded app zoomed in on a New report dialog, on a teal-to-green wallpaper with padding and rounded corners, with the caption Pick the revenue template. The Background panel is on the left, and the timeline below has a filmstrip, an audio waveform and a purple 1.4x zoom pill."
          />
          <Brackets />
        </div>
        <ul className="columns studio-features">
          {features.map(([Icon, title, desc]) => (
            <li key={title}>
              <Icon size={22} aria-hidden="true" />
              <h3>{title}</h3>
              <p>{desc}</p>
            </li>
          ))}
        </ul>
      </div>
    </section>
  )
}
