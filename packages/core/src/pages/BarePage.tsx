import { useState } from 'react'
import { useHarness, useChildRevision, toPath } from '../hooks.ts'
import { canStartAgent } from '../domain.ts'
import { defaultSeedControls, type SeedControls } from '../actors/seeded.ts'
import { discoverSurfaces } from '../actors/surface-loader.ts'
import type { HarnessEvent } from '../machines/harness.ts'
import type { SessionEvent } from '../machines/session.ts'
import type { SurfaceEvent } from '../machines/surface.ts'
import '../styles/bare.css'

/**
 * Candidate events, declared once.
 *
 * Every button below is filtered from these lists through `can()`. Nothing here
 * hard-codes which state gets which button — if a control appears, it is
 * because the machine accepts the event.
 */
const HARNESS_EVENTS: HarnessEvent[] = [
  { type: 'READ_CREDENTIAL' },
  { type: 'CHECK_SANDBOX' },
  { type: 'START' },
  { type: 'STOP' },
  { type: 'RESTART' },
  { type: 'AGENT_EXIT', detail: 'killed from the bare page' },
  { type: 'CREDENTIAL_REJECTED', detail: '401 from the API' },
  // Accepted only in `credential.absent`, like the paste — so the button is
  // gone the moment there is a credential to replace.
  { type: 'MINT_CREDENTIAL' },
  // The one thing a running mint says. A literal here rather than a real
  // authorize URL, because the seeded mint invents none and this page's job is
  // to reach the state, not to send anybody to an authorization.
  { type: 'MINT_URL', url: 'https://claude.com/cai/oauth/authorize?state=from-the-bare-page' },
  // Accepted only under a Credential Kind of `subscription`, so this button is
  // simply not here under an API key — which is the gate itself, shown on the
  // one surface with nothing covering for it. The strip's absence in the app
  // and this button's absence here are the same fact (ADR-0011).
  { type: 'READ_SUBSCRIPTION' },
  // The real scan, not a seed. The bare page's job is to prove behaviour with
  // nothing covering for it, and a seeded descriptor list would prove that a
  // literal can be spawned from.
  { type: 'DISCOVER_SURFACES', descriptors: discoverSurfaces() },
]

const SESSION_EVENTS: SessionEvent[] = [
  { type: 'SEND' },
  { type: 'INTERRUPT' },
  { type: 'RETRY_TURN' },
  { type: 'DISMISS_TURN_ERROR' },
  { type: 'SAVE' },
  { type: 'RETRY_SAVE' },
]

const SURFACE_EVENTS: SurfaceEvent[] = [{ type: 'RETRY' }, { type: 'UNLOAD' }]

export function BarePage() {
  const [controls, setControls] = useState<SeedControls>(defaultSeedControls)
  const { snapshot, send, transitions, mode } = useHarness(controls)
  const [draft, setDraft] = useState('')
  /*
    The paste, held for exactly as long as it takes to send.

    Not in the machine, and not in the transition log this page renders — a
    credential is the one string in Core that must not survive the interaction,
    and this page's whole job is to show everything. Cleared on send.

    In live mode this writes the developer's own keychain, which is the point:
    the bare page proves behaviour with nothing covering for it.
  */
  const [pasting, setPasting] = useState('')

  const ctx = snapshot.context
  const surfaces = ctx.surfaces
  useChildRevision([...surfaces, ...(ctx.session ? [ctx.session] : [])])

  const session = ctx.session
  const sessionSnap = session?.getSnapshot()

  // START always reports can() === true because its refusal is an unguarded
  // fallback. Readiness comes from the predicate the guard uses.
  const ready = canStartAgent({
    credential: ctx.credentialState,
    sandbox: ctx.sandboxState,
  })

  const toggle = (key: keyof SeedControls) => () =>
    setControls((c) => ({ ...c, [key]: !c[key] }))

  return (
    <div className="bare">
      <nav>
        <a href="#/bare">bare</a>
        <a href="#/designed">designed</a>
        <a href="#/states">states</a>
      </nav>

      <h1>varnick — bare</h1>
      <p>
        actors: <strong>{mode}</strong>
        {mode === 'seeded' ? ' — every service behind these machines is a stub' : ''}
      </p>
      <p>No design system. Every control is filtered through <code>can()</code>.</p>

      <h2>Seeds</h2>
      <section>
        {(
          [
            ['failSandbox', 'sandbox check fails'],
            ['failCredential', 'credential read fails'],
            ['failStore', 'credential store fails'],
            ['failMint', 'token mint fails'],
            ['failTurn', 'turn fails'],
            ['failSave', 'save fails'],
          ] as const
        ).map(([key, label]) => (
          <label key={key}>
            <input type="checkbox" checked={controls[key]} onChange={toggle(key)} /> {label}
          </label>
        ))}
        <p>Changing a seed restarts the Harness — the transition log resets with it.</p>
      </section>

      <h2>Harness</h2>
      <section>
        <dl>
          <dt>credential</dt>
          <dd>{String((snapshot.value as Record<string, unknown>).credential)}</dd>
          <dt>sandbox</dt>
          <dd>{String((snapshot.value as Record<string, unknown>).sandbox)}</dd>
          <dt>agent</dt>
          <dd>{String((snapshot.value as Record<string, unknown>).agent)}</dd>
          {/*
            The fourth region, and the fact that gates it.

            Both are here because the one thing plan usage is hard to tell apart
            from the outside is a read that was refused from a read that was
            never made: each leaves the strip absent. A region that passed
            through `reading` was attempted; one sitting in `unread` beside a
            kind of `api-key` was never asked for. That is the distinction this
            page exists to make visible.
          */}
          <dt>subscription</dt>
          <dd>{String((snapshot.value as Record<string, unknown>).subscription)}</dd>
          <dt>credential kind</dt>
          <dd>{ctx.credentialKind ?? '— none read'}</dd>
          <dt>plan usage</dt>
          <dd>
            {ctx.subscription
              ? `5h ${ctx.subscription.fiveHourPct}% · week ${ctx.subscription.weeklyPct}% (${ctx.subscription.source})`
              : '— nothing measured'}
          </dd>
          <dt>can start</dt>
          <dd>{ready ? 'yes' : 'no — START will be refused and say why'}</dd>
          <dt>refusal</dt>
          <dd>{ctx.refusal ? JSON.stringify(ctx.refusal) : '—'}</dd>
          <dt>sandbox error</dt>
          <dd>{ctx.sandboxError ?? '—'}</dd>
          <dt>agent error</dt>
          <dd>{ctx.agentError ?? '—'}</dd>
          <dt>credential error</dt>
          <dd>{ctx.credentialError ?? '—'}</dd>
          <dt>kind a store would write</dt>
          <dd>{ctx.storingKind}</dd>
          {/*
            The mint's one signal, shown whether or not a mint is running.

            A URL sitting here outside `credential.minting` would be the bug the
            machine's `exit` action exists to prevent — a link from an attempt
            that has ended, offered as though it were live — so it is worth
            being able to see that it is not there.
          */}
          <dt>sign-in URL</dt>
          <dd>{ctx.mintUrl ?? '— no mint running'}</dd>
        </dl>

        {/*
          STORE_CREDENTIAL is the one Harness event with an argument a person
          types, so it cannot be a button in the list below with a literal in it.
          Both controls come from `can()` like every other one here: the kind
          buttons because `absent` accepts the choice, the store button because
          the machine accepts *this* value.
        */}
        <div style={{ marginTop: 8 }}>
          {(['subscription', 'api-key'] as const)
            .filter((kind) => snapshot.can({ type: 'CHOOSE_CREDENTIAL_KIND', kind }))
            .map((kind) => (
              <button
                key={kind}
                onClick={() => send({ type: 'CHOOSE_CREDENTIAL_KIND', kind })}
                aria-pressed={kind === ctx.storingKind}
              >
                CHOOSE_CREDENTIAL_KIND {kind}
              </button>
            ))}
        </div>
        <div style={{ marginTop: 8 }}>
          <input
            type="password"
            autoComplete="off"
            value={pasting}
            placeholder="credential to store"
            onChange={(ev) => setPasting(ev.target.value)}
          />
          {snapshot.can({ type: 'STORE_CREDENTIAL', kind: ctx.storingKind, value: pasting }) && (
            <button
              onClick={() => {
                send({ type: 'STORE_CREDENTIAL', kind: ctx.storingKind, value: pasting })
                setPasting('')
              }}
            >
              STORE_CREDENTIAL
            </button>
          )}
        </div>

        <div style={{ marginTop: 8 }}>
          {HARNESS_EVENTS.filter((e) => snapshot.can(e)).map((e) => (
            <button
              key={e.type}
              className={e.type === 'START' && !ready ? 'refused' : undefined}
              onClick={() => send(e)}
            >
              {e.type}
            </button>
          ))}
        </div>
      </section>

      <h2>Session</h2>
      <section>
        {!session || !sessionSnap ? (
          <p>No Session. One is spawned when the agent starts, and outlives every restart.</p>
        ) : (
          <>
            <dl>
              <dt>turn</dt>
              <dd>{toPath((sessionSnap.value as Record<string, unknown>).turn)}</dd>
              <dt>persistence</dt>
              <dd>{toPath((sessionSnap.value as Record<string, unknown>).persistence)}</dd>
              <dt>partial</dt>
              <dd>{sessionSnap.context.partial || '—'}</dd>
              <dt>turn error</dt>
              <dd>{sessionSnap.context.turnError ?? '—'}</dd>
              <dt>save error</dt>
              <dd>{sessionSnap.context.saveError ?? '—'}</dd>
            </dl>

            <div style={{ margin: '8px 0' }}>
              <input
                type="text"
                value={draft}
                placeholder="draft"
                onChange={(ev) => {
                  setDraft(ev.target.value)
                  session.send({ type: 'EDIT_DRAFT', text: ev.target.value })
                }}
              />
            </div>

            <div>
              {SESSION_EVENTS.filter((e) => sessionSnap.can(e)).map((e) => (
                <button
                  key={e.type}
                  onClick={() => {
                    session.send(e)
                    if (e.type === 'SEND') setDraft('')
                  }}
                >
                  {e.type}
                </button>
              ))}
              <button
                onClick={() => session.send({ type: 'STREAM_DELTA', text: 'chunk ' })}
              >
                STREAM_DELTA
              </button>
            </div>

            <h2>Transcript</h2>
            <ol>
              {sessionSnap.context.messages.map((m) => (
                <li key={m.id}>
                  <strong>{m.role}</strong>: {m.text}
                </li>
              ))}
            </ol>
          </>
        )}
      </section>

      <h2>Surfaces</h2>
      <section>
        {surfaces.length === 0 ? (
          <p>None discovered. Surfaces are found on disk, never registered in Core.</p>
        ) : (
          <ul>
            {surfaces.map((ref) => {
              const s = ref.getSnapshot()
              return (
                <li key={ref.id}>
                  <strong>{s.context.descriptor.name}</strong> — {toPath(s.value)}
                  {s.context.error ? ` — ${s.context.error}` : ''}
                  {' '}
                  {SURFACE_EVENTS.filter((e) => s.can(e)).map((e) => (
                    <button key={e.type} onClick={() => ref.send(e)}>
                      {e.type}
                    </button>
                  ))}
                </li>
              )
            })}
          </ul>
        )}
      </section>

      <h2>Transitions ({transitions.length})</h2>
      <section className="log">
        <ol>
          {transitions.map((t, i) => (
            <li key={i}>
              {t.actor} — {t.event} — {t.from} to {t.to}
            </li>
          ))}
        </ol>
      </section>
    </div>
  )
}
