import { useEffect, useState } from 'react'
import { BarePage } from './pages/BarePage.tsx'
import { DesignedPage } from './pages/DesignedPage.tsx'
import { StatesPage } from './pages/StatesPage.tsx'
import { routeOf, cardOf } from './routing.ts'

/**
 * The chat is what a launch opens.
 *
 * It used to be `#/bare`, which was the first route in the list rather than a
 * decision. A stranger's first frame was then raw machine state and a row of
 * event buttons — a debugging surface, and not the "empty chat that works" a
 * fresh clone is owed. `#/bare` and `#/states` are still product code and still
 * addressable — from the View menu now (ticket 41), which is what made them
 * surfaces a developer uses rather than surfaces that exist.
 */
export function App() {
  const [hash, setHash] = useState(() => window.location.hash)

  useEffect(() => {
    const onHash = () => setHash(window.location.hash)
    window.addEventListener('hashchange', onHash)
    return () => window.removeEventListener('hashchange', onHash)
  }, [])

  const route = routeOf(hash)
  if (route === '#/bare') return <BarePage />
  if (route === '#/designed') return <DesignedPage />
  // The card travels as a prop rather than being read off `location` inside
  // the page: following an index link must scroll rather than remount, because
  // every card creates real actors on mount and a click that reset all
  // twenty-four of them is not a link, it is a reload.
  return <StatesPage card={cardOf(hash)} />
}
