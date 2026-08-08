import { useEffect, useState } from 'react'
import { BarePage } from './pages/BarePage.tsx'
import { DesignedPage } from './pages/DesignedPage.tsx'
import { StatesPage } from './pages/StatesPage.tsx'

const ROUTES = ['#/bare', '#/designed', '#/states'] as const
type Route = (typeof ROUTES)[number]

/**
 * The chat is what a launch opens.
 *
 * It used to be `#/bare`, which was the first route in the list rather than a
 * decision. A stranger's first frame was then raw machine state and a row of
 * event buttons — a debugging surface, and not the "empty chat that works" a
 * fresh clone is owed. `#/bare` and `#/states` are still product code and still
 * addressable; the README says where they are.
 */
function currentRoute(): Route {
  const hash = window.location.hash
  return (ROUTES as readonly string[]).includes(hash) ? (hash as Route) : '#/designed'
}

export function App() {
  const [route, setRoute] = useState<Route>(currentRoute)

  useEffect(() => {
    const onHash = () => setRoute(currentRoute())
    window.addEventListener('hashchange', onHash)
    return () => window.removeEventListener('hashchange', onHash)
  }, [])

  if (route === '#/bare') return <BarePage />
  if (route === '#/designed') return <DesignedPage />
  return <StatesPage />
}
