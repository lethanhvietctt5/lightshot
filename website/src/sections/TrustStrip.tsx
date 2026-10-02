import { CloudOff, Cpu, Laptop, Scale, UserX } from 'lucide-react'

const items = [
  [UserX, 'No account to create'],
  [CloudOff, 'Nothing uploaded'],
  [Cpu, 'Captions transcribed on-device'],
  [Scale, 'MIT licensed'],
  [Laptop, 'Apple Silicon and Intel'],
] as const

export function TrustStrip() {
  return (
    <div className="container trust">
      <ul className="trust-row">
        {items.map(([Icon, label]) => (
          <li key={label}>
            <Icon size={16} aria-hidden="true" />
            {label}
          </li>
        ))}
      </ul>
    </div>
  )
}
