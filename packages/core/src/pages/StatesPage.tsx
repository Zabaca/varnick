import { useMemo, useRef, useState } from 'react'
import { useMachine } from '@xstate/react'
import { ChatSurface } from '../components/chat-surface.tsx'
import { frozenHarness } from '../actors/frozen.ts'
import { useChildRevision, toPath } from '../hooks.ts'
import { SCENARIOS, uncoveredPaths, unknownPaths, type Scenario } from '../data/scenarios.ts'
import { SURFACE_STATE_PATHS } from '../machines/surface.ts'

/**
 * Every state of the chat surface, on one page.
 *
 * Each card renders the real component driven by a real actor parked in the
 * state it names — not a screenshot, not a mock. The machine is the shipped
 * machine with its actors and delays frozen (see actors/frozen.ts), so a card
 * holds still while it is read and still moves when a control is used.
 *
 * This is product code and it ships. It is the coverage check for the states no
 * prose predicts, and the surface a ticket points at: `#/states → turn.failed`
 * resolves to a card rather than to a copy of the design.
 */

export function StatesPage() {
  const uncovered = uncoveredPaths()
  const unknown = unknownPaths()

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

      <div className="grid gap-5 px-6 py-6 [grid-template-columns:repeat(auto-fill,minmax(560px,1fr))]">
        {SCENARIOS.map((scenario) => (
          <Card key={scenario.id} scenario={scenario} />
        ))}
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
      <div className="mt-2" style={{ color: 'var(--fg-faint)' }}>
        Waived by decision: {SURFACE_STATE_PATHS.map((p) => `surface.${p}`).join(', ')} — rendering
        a Surface is out of v1 scope (PRODUCT.md), so these have no card on purpose.
      </div>
    </div>
  )
}

function Card({ scenario }: { scenario: Scenario }) {
  // Remounting is the reset. Re-creating the actor from the same input is the
  // only way back that cannot disagree with how the card was set up.
  const [generation, setGeneration] = useState(0)
  return <CardBody key={generation} scenario={scenario} onReset={() => setGeneration((g) => g + 1)} />
}

function CardBody({ scenario, onReset }: { scenario: Scenario; onReset: () => void }) {
  const machine = useMemo(() => frozenHarness(), [])
  const [snapshot, send] = useMachine(machine, { input: scenario.input })

  const session = snapshot.context.session
  useChildRevision(session ? [session] : [])

  const now = liveState(snapshot, session)
  const initial = useRef(now)
  const drifted = now !== initial.current

  return (
    <section style={{ border: '1px solid var(--rule)', background: 'var(--ground-raised)' }}>
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
        <ChatSurface snapshot={snapshot} send={send} mode="seeded" />
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
