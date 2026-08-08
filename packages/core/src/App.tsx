import { useEffect, useState } from 'react'
import { BarePage } from './pages/BarePage.tsx'
import { DesignedPage } from './pages/DesignedPage.tsx'
import { StatesPage } from './pages/StatesPage.tsx'

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
  if (route === '#/designed') return <DesignedPage />
  return <StatesPage />
}
