import { useEffect, useState } from 'react'
import { DesignedPage } from './pages/DesignedPage.tsx'
import { StatesPage } from './pages/StatesPage.tsx'
import { routeOf, cardOf } from './routing.ts'

/**
 * The chat is what a launch opens.
 *
 * Two renderings, and it used to be three. `#/bare` was the first route in the
 * list rather than a decision, so a stranger's first frame was raw machine
 * state and a row of event buttons — a debugging surface, and not the "empty
 * chat that works" a fresh clone is owed. It was moved out of the way, then
 * given a menu entry (ticket 41), then removed (ADR-0013): a surface that
 * exists to prove behaviour before design, on a product whose behaviour is
 * proved by 434 assertions in `drive.ts` and shown by `#/states`.
 */
export function App() {
  const [hash, setHash] = useState(() => window.location.hash)

  useEffect(() => {
    const onHash = () => setHash(window.location.hash)
    window.addEventListener('hashchange', onHash)
    return () => window.removeEventListener('hashchange', onHash)
  }, [])

  const route = routeOf(hash)
  if (route === '#/designed') return <DesignedPage />
  // The card travels as a prop rather than being read off `location` inside
  // the page: following an index link must scroll rather than remount, because
  // every card creates real actors on mount and a click that reset all
  // twenty-four of them is not a link, it is a reload.
  return <StatesPage card={cardOf(hash)} />
}
