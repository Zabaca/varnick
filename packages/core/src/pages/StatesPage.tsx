import { useEffect, useMemo, useRef, useState } from 'react'
import { useMachine } from '@xstate/react'
import { ChatSurface } from '../components/chat-surface.tsx'
import { frozenHarness } from '../actors/frozen.ts'
import { useChildRevision, toPath } from '../hooks.ts'
import { linkToCard } from '../routing.ts'
import {
  GROUPS,
  SCENARIOS,
  matches,
  uncoveredPaths,
  unknownPaths,
  type Group,
  type Scenario,
} from '../data/scenarios.ts'

/**
 * Every state of the chat surface, on one page.
 *
 * Each card renders the real component driven by a real actor parked in the
 * state it names — not a screenshot, not a mock. The machine is the shipped
 * machine with its actors and delays frozen (see actors/frozen.ts), so a card
 * holds still while it is read and still moves when a control is used.
 *
 * This is product code and it ships. It is the coverage check for the states no
 * prose predicts, and the surface a ticket points at: `#/states/turn-failed`
 * resolves to a card rather than to a copy of the design.
 *
 * ## The index, and why a long scroll needs one
 *
 * Twenty-four cards is past the point where the page can be read by scrolling
 * it. Without a map you cannot see what is on the page without paging through
 * it, you cannot get back to a card you passed, and you cannot tell anyone else
 * where one is. The nav on the left answers all three, and the third is the one
 * that matters most here — a ticket that says "see `#/states`" is pointing at
 * forty screens.
 *
 * One predicate feeds the index and the grid, so the count in the nav and the
 * number of cards beside it cannot disagree. There is deliberately no
 * scroll-spy: an observer that rewrites the nav as the page settles is a page
 * that never settles, and everything about this surface is meant to hold still.
 */

export function StatesPage({ card }: { card?: string | null }) {
  const uncovered = uncoveredPaths()
  const unknown = unknownPaths()

  const [query, setQuery] = useState('')
  const [group, setGroup] = useState<Group | 'all'>('all')

  const shown = useMemo(() => SCENARIOS.filter(matches(query, group)), [query, group])

  /*
    Arriving at a link, and following one, are the same act.

    The scroll runs on the second frame rather than the first: every card
    creates real actors on mount and grows as they settle, so a target measured
    before that lands somewhere else entirely. Nothing remounts — following an
    index entry must not reset twenty-four running actors.
  */
  useEffect(() => {
    if (!card) return
    let second = 0
    const first = requestAnimationFrame(() => {
      second = requestAnimationFrame(() => {
        document.getElementById(card)?.scrollIntoView({ block: 'start' })
      })
    })
    return () => {
      cancelAnimationFrame(first)
      cancelAnimationFrame(second)
    }
  }, [card])

  return (
    <div className="min-h-full" style={{ background: 'var(--ground)', color: 'var(--fg)' }}>
      <header className="px-6 pt-5 pb-4" style={{ borderBottom: '1px solid var(--rule)' }}>
        <nav className="mb-4 flex gap-4" style={{ color: 'var(--fg-faint)' }}>
          <a href="#/bare">bare</a>
          <a href="#/designed">designed</a>
          <a href="#/states" style={{ color: 'var(--fg)' }}>
            states
          </a>
        </nav>

        <h1 className="text-[15px]">varnick — states</h1>
        <p className="mt-1" style={{ color: 'var(--fg-dim)', maxWidth: 'var(--prose)' }}>
          {SCENARIOS.length} scenarios over the real machines. Actors never settle and delays are
          held, so nothing advances on its own.
        </p>

        <Coverage uncovered={uncovered} unknown={unknown} />
      </header>

      <div className="grid items-start gap-8 px-6 py-6 [grid-template-columns:232px_minmax(0,1fr)]">
        <Index
          query={query}
          onQuery={setQuery}
          group={group}
          onGroup={setGroup}
          shown={shown}
          card={card ?? null}
        />

        <div>
          {shown.length === 0 ? (
            // Filtered-empty is a different problem from empty, and says so:
            // there are cards, this filter found none of them.
            <p style={{ color: 'var(--fg-dim)' }}>
              No card matches <code style={{ color: 'var(--fg)' }}>{query}</code>
              {group !== 'all' && <> in {group}</>}. Every state is still on the page — clear the
              filter to see them.
            </p>
          ) : (
            <div className="grid gap-5 [grid-template-columns:repeat(auto-fill,minmax(560px,1fr))]">
              {shown.map((scenario) => (
                <Card key={scenario.id} scenario={scenario} linked={scenario.id === card} />
              ))}
            </div>
          )}
        </div>
      </div>
    </div>
  )
}

/**
 * The banner. Amber means a state exists with no card — a real gap, not a
 * cosmetic one, because the states no prose predicts are exactly the ones that
 * get shipped broken.
 */
function Coverage({ uncovered, unknown }: { uncovered: string[]; unknown: string[] }) {
  const ok = uncovered.length === 0 && unknown.length === 0
  return (
    <div
      className="mt-3 p-3 text-[12px]"
      style={{
        border: `1px solid ${ok ? 'var(--ok)' : 'var(--warn)'}`,
        color: ok ? 'var(--ok)' : 'var(--warn)',
      }}
    >
      {ok ? (
        <span>✓ Every declared state has a scenario.</span>
      ) : (
        <div className="space-y-1">
          {uncovered.length > 0 && (
            <div>
              ⚠ {uncovered.length} state{uncovered.length === 1 ? '' : 's'} with no card:{' '}
              <span style={{ color: 'var(--fg-dim)' }}>{uncovered.join(', ')}</span>
            </div>
          )}
          {unknown.length > 0 && (
            <div>
              ⚠ {unknown.length} scenario path{unknown.length === 1 ? '' : 's'} no machine declares:{' '}
              <span style={{ color: 'var(--fg-dim)' }}>{unknown.join(', ')}</span>
            </div>
          )}
        </div>
      )}
    </div>
  )
}

function Index({
  query,
  onQuery,
  group,
  onGroup,
  shown,
  card,
}: {
  query: string
  onQuery: (value: string) => void
  group: Group | 'all'
  onGroup: (value: Group | 'all') => void
  shown: readonly Scenario[]
  card: string | null
}) {
  return (
    <nav
      aria-label="States"
      // `dvh` rather than `vh`: on a short window the difference is the last
      // few entries being unreachable, which is the one failure an index may
      // not have.
      className="sticky top-6 flex max-h-[calc(100dvh-4rem)] flex-col gap-3 overflow-auto pr-1 text-[12px]"
    >
      <input
        value={query}
        onChange={(event) => onQuery(event.target.value)}
        placeholder="Filter by name or state…"
        aria-label="Filter states"
        className="w-full px-2 py-1.5 text-[12px]"
        style={{
          background: 'var(--ground-raised)',
          border: '1px solid var(--rule)',
          color: 'var(--fg)',
        }}
      />

      <div style={{ color: 'var(--fg-faint)' }}>
        {shown.length} of {SCENARIOS.length} cards
      </div>

      <div className="flex flex-wrap gap-1">
        {(['all', ...GROUPS] as const).map((name) => (
          <button
            key={name}
            onClick={() => onGroup(name)}
            className="px-1.5 py-0.5 text-[11px]"
            style={{
              border: '1px solid var(--rule)',
              color: name === group ? 'var(--fg)' : 'var(--fg-faint)',
              background: name === group ? 'var(--ground-raised)' : 'transparent',
            }}
          >
            {name}
          </button>
        ))}
      </div>

      {GROUPS.map((name) => {
        const entries = shown.filter((scenario) => scenario.group === name)
        if (entries.length === 0) return null
        return (
          <div key={name}>
            <div className="mb-1" style={{ color: 'var(--fg-faint)' }}>
              {name}
            </div>
            <ul className="space-y-0.5">
              {entries.map((scenario) => (
                <li key={scenario.id}>
                  <a
                    href={linkToCard(scenario.id)}
                    style={{ color: scenario.id === card ? 'var(--accent)' : 'var(--fg-dim)' }}
                  >
                    {scenario.title}
                  </a>
                </li>
              ))}
            </ul>
          </div>
        )
      })}
    </nav>
  )
}

function Card({ scenario, linked }: { scenario: Scenario; linked: boolean }) {
  // Remounting is the reset. Re-creating the actor from the same input is the
  // only way back that cannot disagree with how the card was set up.
  const [generation, setGeneration] = useState(0)
  return (
    <CardBody
      key={generation}
      scenario={scenario}
      linked={linked}
      onReset={() => setGeneration((g) => g + 1)}
    />
  )
}

function CardBody({
  scenario,
  linked,
  onReset,
}: {
  scenario: Scenario
  linked: boolean
  onReset: () => void
}) {
  const machine = useMemo(() => frozenHarness(scenario.surfaceOutcome), [scenario.surfaceOutcome])
  const [snapshot, send] = useMachine(machine, { input: scenario.input })

  // Discovery is an event, not an input — a Surface arrives when the filesystem
  // is scanned. drive.ts sends the same list from the same field, so a card and
  // the coverage check cannot disagree about what this scenario found.
  const surfaces = scenario.surfaces
  useEffect(() => {
    if (surfaces) send({ type: 'DISCOVER_SURFACES', descriptors: [...surfaces] })
  }, [surfaces, send])

  const session = snapshot.context.session
  useChildRevision(session ? [session] : [])

  const now = liveState(snapshot, session)
  const initial = useRef(now)
  const drifted = now !== initial.current

  return (
    <section
      // The card a link addresses. Not an `id` on an anchor — this app routes
      // on the hash, so there is one of those and the route owns it.
      id={scenario.id}
      style={{
        border: `1px solid ${linked ? 'var(--accent)' : 'var(--rule)'}`,
        background: 'var(--ground-raised)',
      }}
    >
      <div className="px-4 pt-3 pb-3" style={{ borderBottom: '1px solid var(--rule)' }}>
        <div className="flex items-baseline gap-3">
          <h2 className="text-[13px]">{scenario.title}</h2>
          <code className="text-[11.5px]" style={{ color: 'var(--accent)' }}>
            {scenario.covers.join('  ')}
          </code>
          {drifted && (
            <button className="ml-auto text-[11.5px]" style={{ color: 'var(--warn)' }} onClick={onReset}>
              moved — reset
            </button>
          )}
        </div>
        <p className="mt-1.5 text-[12px]" style={{ color: 'var(--fg-dim)' }}>
          {scenario.blurb}
        </p>
        <p className="mt-1 text-[12px]" style={{ color: 'var(--fg-faint)' }}>
          {scenario.question}
        </p>
        <code className="mt-2 block text-[11px]" style={{ color: 'var(--fg-faint)' }}>
          {now}
        </code>
      </div>

      {/* The real surface, at a size that shows the composer and the transcript
          together — the two halves whose relationship is the thing to judge. */}
      <div className="h-[440px] overflow-hidden">
        <ChatSurface
          snapshot={snapshot}
          send={send}
          mode="seeded"
          restoredRedacted={scenario.restoredRedacted}
        />
      </div>
    </section>
  )
}

/** Flattened state of the whole system, parent regions and Session together. */
function liveState(
  snapshot: { value: unknown },
  session: { getSnapshot: () => { value: unknown } } | null,
): string {
  const parent = Object.entries(snapshot.value as Record<string, unknown>)
    .map(([region, value]) => `${region}.${toPath(value)}`)
    .join('  ')
  if (!session) return parent
  const child = Object.entries(session.getSnapshot().value as Record<string, unknown>)
    .map(([region, value]) => `${region}.${toPath(value)}`)
    .join('  ')
  return `${parent}  |  ${child}`
}
