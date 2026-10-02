import { Footer, FinalCta } from './sections/Closing'
import { Everyday } from './sections/Everyday'
import { Hero } from './sections/Hero'
import { Install } from './sections/Install'
import { Nav } from './sections/Nav'
import { Privacy } from './sections/Privacy'
import { Recording } from './sections/Recording'
import { Screenshots } from './sections/Screenshots'
import { Studio } from './sections/Studio'
import { TrustStrip } from './sections/TrustStrip'

export default function App() {
  return (
    <>
      <Nav />
      <main>
        <Hero />
        <TrustStrip />
        <Screenshots />
        <Recording />
        <Studio />
        <Privacy />
        <Everyday />
        <Install />
        <FinalCta />
      </main>
      <Footer />
    </>
  )
}
