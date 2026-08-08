import { useEffect, useState } from 'react'
import { BarePage } from './pages/BarePage.tsx'

const ROUTES = ['#/bare', '#/designed', '#/states'] as const
type Route = (typeof ROUTES)[number]

function currentRoute(): Route {
  const hash = window.location.hash
  return (ROUTES as readonly string[]).includes(hash) ? (hash as Route) : '#/bare'
}

export function App() {
  const [route, setRoute] = useState<Route>(currentRoute)

  useEffect(() => {
    const onHash = () => setRoute(currentRoute())
    window.addEventListener('hashchange', onHash)
    return () => window.removeEventListener('hashchange', onHash)
  }, [])

  if (route === '#/bare') return <BarePage />

  // Designed and states come after the bare page proves the behaviour is
  // complete. Nothing visual is decided until then.
  return (
    <div style={{ font: '13px ui-monospace, monospace', padding: 16 }}>
      <nav>
        <a href="#/bare" style={{ marginRight: 12 }}>
          bare
        </a>
        <a href="#/designed" style={{ marginRight: 12 }}>
          designed
        </a>
        <a href="#/states">states</a>
      </nav>
      <p>{route.slice(2)} — not built yet.</p>
    </div>
  )
}
