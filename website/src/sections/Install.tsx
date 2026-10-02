import { useEffect, useState } from 'react'
import { Check, Code, Copy, RefreshCw, ShieldCheck } from 'lucide-react'
import { SectionHead } from '../components'
import { links } from '../links'

const quarantineCommand = 'xattr -dr com.apple.quarantine /Applications/Lightshot.app'

function CommandBlock() {
  const [copied, setCopied] = useState(false)

  useEffect(() => {
    if (!copied) return
    const timer = setTimeout(() => setCopied(false), 2000)
    return () => clearTimeout(timer)
  }, [copied])

  const copy = async () => {
    try {
      await navigator.clipboard.writeText(quarantineCommand)
      setCopied(true)
    } catch {
      // Clipboard access can be refused (e.g. an insecure context); the command stays selectable.
    }
  }

  return (
    <div className="command">
      <span className="command-prompt" aria-hidden="true">
        $
      </span>
      <code>{quarantineCommand}</code>
      <button
        type="button"
        className="command-copy"
        onClick={copy}
        aria-label={copied ? 'Copied' : 'Copy command'}
      >
        {copied ? <Check size={14} aria-hidden="true" /> : <Copy size={14} aria-hidden="true" />}
      </button>
    </div>
  )
}

export function Install() {
  return (
    <section className="section section-install container" id="install">
      <SectionHead
        index="06"
        label="Install"
        title="Up and running in about a minute."
        body="Lightshot is open source and not notarized by Apple, which takes a paid developer account. macOS asks you to allow it once. After that it updates itself."
      />

      <ol className="columns steps">
        <li>
          <p className="step-num">Step 01</p>
          <h3>Download and drag to Applications</h3>
          <p>
            Open the DMG and drag Lightshot into Applications. Run it from there, not from
            Downloads.
          </p>
        </li>
        <li>
          <p className="step-num">Step 02</p>
          <h3>Allow it once</h3>
          <p>
            On macOS 15 or later, open Lightshot and dismiss the warning, then click Open Anyway in
            System Settings → Privacy &amp; Security. On macOS 14, Control-click the app and choose
            Open.
          </p>
          <CommandBlock />
        </li>
        <li>
          <p className="step-num">Step 03</p>
          <h3>Grant Screen Recording</h3>
          <p>
            Follow the onboarding. Microphone, camera and the rest are only requested when you turn
            on the feature that needs them.
          </p>
        </li>
      </ol>

      <ul className="alt-paths">
        <li>
          <ShieldCheck size={15} aria-hidden="true" />
          <a href={links.verifyDownload}>Every release lists a SHA-256 checksum</a>
        </li>
        <li>
          <Code size={15} aria-hidden="true" />
          <a href={links.buildFromSource}>Prefer to build it yourself? Build from source with Xcode</a>
        </li>
        <li>
          <RefreshCw size={15} aria-hidden="true" />
          <a href={links.updates}>Updates are signature-checked before they install</a>
        </li>
      </ul>
    </section>
  )
}
