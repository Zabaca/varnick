import { useEffect, useRef, useState } from 'react'
import { useHarness, useChildRevision, toPath } from '../hooks.ts'
import { canStartAgent } from '../domain.ts'
import { defaultSeedControls } from '../actors/seeded.ts'
import { seedSurfaces } from '../data/seed.ts'
import { CreaseSquare, ActiveDot, Condition, type CreaseState } from '../components/crease.tsx'
import type { HarnessEvent } from '../machines/harness.ts'
import type { SessionEvent } from '../machines/session.ts'

/**
 * The chat surface. One continuous sheet that keeps every crease it has taken.
 *
 * Every control is filtered through `can()`. Readiness for START comes from
 * canStartAgent(), never from can(), whose unguarded refusal fallback makes it
 * permanently true.
 */

/* --- readings: the product's own language, recovery named ---------------- */

function credentialReading(state: string): { crease: CreaseState; reading: string; detail?: string } {
  switch (state) {
    case 'present':
      return { crease: 'folded', reading: 'Held by the host' }
    case 'reading':
      return { crease: 'creased', reading: 'Reading the keychain' }
    case 'rejected':
      return { crease: 'released', reading: 'Rejected', detail: 'Read it again once the token is replaced.' }
    default:
      return { crease: 'open', reading: 'None stored', detail: 'Read one to let the agent authenticate.' }
  }
}

function sandboxReading(state: string, error: string | null) {
  switch (state) {
    case 'available':
      return { crease: 'folded' as CreaseState, reading: 'Established' }
    case 'checking':
      return { crease: 'creased' as CreaseState, reading: 'Establishing' }
    case 'unavailable':
      return {
        crease: 'released' as CreaseState,
        reading: 'Could not be established',
        detail: error ? `${error}. Check again to retry.` : 'Check again to retry.',
      }
    default:
      return { crease: 'open' as CreaseState, reading: 'Not yet checked', detail: 'The agent will not start until it is.' }
  }
}

function agentReading(state: string, error: string | null, refusal: unknown) {
  const r = refusal as { kind?: string; detail?: string } | null
  switch (state) {
    case 'running':
      return { crease: 'folded' as CreaseState, reading: 'Running, confined' }
    case 'starting':
      return { crease: 'creased' as CreaseState, reading: 'Starting' }
    case 'crashed':
      return {
        crease: 'released' as CreaseState,
        reading: 'Stopped unexpectedly',
        detail: error ? `${error}. Restart to try again.` : 'Restart to try again.',
      }
    case 'startRefused':
      return {
        crease: 'open' as CreaseState,
        reading: 'Refused to start',
        detail:
          r?.kind === 'no-credential'
            ? 'No credential is stored yet.'
            : r?.kind === 'credential-rejected'
              ? 'The stored credential was rejected.'
              : 'The sandbox is not established.',
      }
    default:
      return { crease: 'open' as CreaseState, reading: 'Not running' }
  }
}

/* --- controls ------------------------------------------------------------ */

const HARNESS_CONTROLS: { event: HarnessEvent; label: string }[] = [
  { event: { type: 'READ_CREDENTIAL' }, label: 'Read credential' },
  { event: { type: 'CHECK_SANDBOX' }, label: 'Check sandbox' },
  { event: { type: 'START' }, label: 'Start agent' },
  { event: { type: 'RESTART' }, label: 'Restart agent' },
  { event: { type: 'STOP' }, label: 'Stop agent' },
  { event: { type: 'DISCOVER_SURFACES', descriptors: seedSurfaces }, label: 'Discover surfaces' },
]

function RailButton({
  label,
  onClick,
  emphasis = false,
}: {
  label: string
  onClick: () => void
  emphasis?: boolean
}) {
  return (
    <button
      onClick={onClick}
      className="font-display w-full px-3 py-2 text-left text-[12px] uppercase transition-colors duration-150"
      style={{
        letterSpacing: '0.1em',
        color: 'var(--fold)',
        border: '1px solid',
        borderColor: emphasis ? 'var(--fold)' : 'var(--rail-rule)',
        background: emphasis ? 'var(--rail-raised)' : 'transparent',
      }}
      onMouseEnter={(e) => {
        e.currentTarget.style.background = 'var(--rail-raised)'
      }}
      onMouseLeave={(e) => {
        e.currentTarget.style.background = emphasis ? 'var(--rail-raised)' : 'transparent'
      }}
    >
      {label}
    </button>
  )
}

/* --- page ---------------------------------------------------------------- */

export function DesignedPage() {
  const { snapshot, send } = useHarness(defaultSeedControls)
  const [draft, setDraft] = useState('')
  const sheetRef = useRef<HTMLDivElement>(null)

  const ctx = snapshot.context
  const session = ctx.session
  useChildRevision([...ctx.surfaces, ...(session ? [session] : [])])
  const s = session?.getSnapshot()

  const turn = s ? toPath((s.value as Record<string, unknown>).turn) : null
  const persistence = s ? toPath((s.value as Record<string, unknown>).persistence) : null
  const inFlight = turn === 'sending' || turn === 'streaming' || turn === 'interrupting'

  const ready = canStartAgent({ credential: ctx.credentialState, sandbox: ctx.sandboxState })
  const cred = credentialReading(ctx.credentialState)
  const sand = sandboxReading(ctx.sandboxState, ctx.sandboxError)
  const agent = agentReading(toPath((snapshot.value as Record<string, unknown>).agent), ctx.agentError, ctx.refusal)

  // Folds are user turns; each keeps the crease it took.
  const folds = (s?.context.messages ?? []).filter((m) => m.role === 'user')

  useEffect(() => {
    sheetRef.current?.scrollTo({ top: sheetRef.current.scrollHeight, behavior: 'smooth' })
  }, [s?.context.messages.length, s?.context.partial])

  const sessionCan = (e: SessionEvent) => Boolean(s?.can(e))

  return (
    <div className="flex h-full" style={{ background: 'var(--sumi)' }}>
      {/* ---- the rail: vermilion owns this field entirely ---- */}
      <aside
        className="flex shrink-0 flex-col overflow-y-auto"
        style={{ width: 'var(--rail-w)', background: 'var(--vermilion-deep)' }}
      >
        <div className="px-5 pt-5 pb-4">
          <div
            className="font-display text-[15px] font-medium uppercase"
            style={{ letterSpacing: '0.28em', color: 'var(--fold)' }}
          >
            varnick
          </div>
          <div
            className="mt-1.5 text-[11.5px] leading-snug"
            style={{ color: 'var(--fold-on-vermilion)' }}
          >
            One sheet. Every crease kept.
          </div>
        </div>

        <div
          className="px-5 py-4"
          style={{ borderTop: '1px solid var(--rail-rule)' }}
        >
          <Condition label="Sandbox" state={sand.crease} reading={sand.reading} detail={sand.detail} />
          <Condition label="Credential" state={cred.crease} reading={cred.reading} detail={cred.detail} />
          <Condition label="Agent" state={agent.crease} reading={agent.reading} detail={agent.detail} />
        </div>

        <div
          className="flex flex-col gap-2 px-5 py-4"
          style={{ borderTop: '1px solid var(--rail-rule)' }}
        >
          {HARNESS_CONTROLS.filter((c) => snapshot.can(c.event)).map((c) => (
            <RailButton
              key={c.label}
              label={c.label}
              emphasis={c.event.type === 'START' && ready}
              onClick={() => send(c.event)}
            />
          ))}
        </div>

        {ctx.surfaces.length > 0 && (
          <div
            className="px-5 py-4"
            style={{ borderTop: '1px solid var(--rail-rule)' }}
          >
            <div
              className="font-display mb-2.5 text-[10px] uppercase"
              style={{ letterSpacing: '0.16em', color: 'var(--fold-on-vermilion)' }}
            >
              Surfaces
            </div>
            {ctx.surfaces.map((ref) => {
              const snap = ref.getSnapshot()
              const state = toPath(snap.value)
              return (
                <div key={ref.id} className="flex items-start gap-2.5 py-1.5">
                  <CreaseSquare
                    state={state === 'loaded' ? 'folded' : state === 'failed' ? 'released' : 'creased'}
                    title={`${snap.context.descriptor.name}: ${state}`}
                    className="mt-0.5 shrink-0"
                  />
                  <div className="min-w-0 flex-1">
                    <div className="text-[12.5px] leading-snug" style={{ color: 'var(--fold)' }}>
                      {snap.context.descriptor.name}
                    </div>
                    {snap.context.error && (
                      <>
                        <div
                          className="mt-0.5 text-[11.5px] leading-snug"
                          style={{ color: 'var(--fold-on-vermilion)' }}
                        >
                          {snap.context.error}
                        </div>
                        {snap.can({ type: 'RETRY' }) && (
                          <button
                            onClick={() => ref.send({ type: 'RETRY' })}
                            className="font-display mt-1.5 text-[10.5px] uppercase underline"
                            style={{ letterSpacing: '0.12em', color: 'var(--fold)', textUnderlineOffset: '3px' }}
                          >
                            Fold again
                          </button>
                        )}
                      </>
                    )}
                  </div>
                </div>
              )
            })}
          </div>
        )}

        <div className="mt-auto px-5 py-4">
          <nav
            className="font-display flex gap-3 text-[10px] uppercase"
            style={{ letterSpacing: '0.14em', color: 'var(--fold-on-vermilion)' }}
          >
            <a href="#/bare">Bare</a>
            <a href="#/designed" style={{ color: 'var(--fold)' }}>
              Designed
            </a>
            <a href="#/states">States</a>
          </nav>
        </div>
      </aside>

      {/* ---- the sheet ---- */}
      <main className="crease-ground flex min-w-0 flex-1 flex-col">
        {!session ? (
          <EmptySheet ready={ready} />
        ) : (
          <>
            <div ref={sheetRef} className="min-h-0 flex-1 overflow-y-auto px-12 py-10">
              <div style={{ maxWidth: 'var(--sheet-measure)' }}>
                {folds.length === 0 && (
                  <p className="text-[14px]" style={{ color: 'var(--fold-dim)' }}>
                    The sheet is flat. The first thing you send takes the first fold.
                  </p>
                )}

                {(s?.context.messages ?? []).map((m, i) => {
                  const foldNumber = (s?.context.messages ?? [])
                    .slice(0, i + 1)
                    .filter((x) => x.role === 'user').length
                  const isUser = m.role === 'user'
                  return (
                    <article key={m.id} className="mb-7">
                      {isUser && (
                        <div className="mb-2 flex items-baseline gap-3">
                          <span
                            data-numeric
                            className="font-display text-[11px]"
                            style={{ letterSpacing: '0.1em', color: 'var(--gold)' }}
                          >
                            {String(foldNumber).padStart(2, '0')}
                          </span>
                          <span
                            className="font-display text-[10px] uppercase"
                            style={{ letterSpacing: '0.16em', color: 'var(--fold-dim)' }}
                          >
                            You
                          </span>
                        </div>
                      )}
                      <p
                        className="text-[14px] leading-[1.75]"
                        style={{
                          color: isUser ? 'var(--fold)' : 'var(--fold-agent)',
                          paddingLeft: isUser ? 0 : '2.1rem',
                          borderLeft: isUser ? 'none' : '1px solid var(--crease)',
                        }}
                      >
                        {m.text}
                      </p>
                    </article>
                  )
                })}

                {s?.context.partial && (
                  <article className="fold-taking mb-7">
                    <p
                      className="text-[14px] leading-[1.75]"
                      style={{
                        color: 'var(--fold-agent)',
                        paddingLeft: '2.1rem',
                        borderLeft: '1px solid var(--gold)',
                      }}
                    >
                      {s.context.partial}
                    </p>
                  </article>
                )}

                {turn === 'failed' && s?.context.turnError && (
                  <div
                    className="mb-7 py-3"
                    style={{ borderTop: '1px solid var(--crease)', borderBottom: '1px solid var(--crease)' }}
                  >
                    <div className="flex items-start gap-2.5">
                      <CreaseSquare state="released" className="mt-0.5 shrink-0" title="The fold was released" />
                      <div>
                        <p className="text-[13.5px]" style={{ color: 'var(--fold)' }}>
                          The fold was released. {s.context.turnError}.
                        </p>
                        <div className="mt-2 flex gap-4">
                          {sessionCan({ type: 'RETRY_TURN' }) && (
                            <button
                              onClick={() => session.send({ type: 'RETRY_TURN' })}
                              className="font-display text-[10.5px] uppercase underline"
                              style={{ letterSpacing: '0.12em', color: 'var(--gold)', textUnderlineOffset: '3px' }}
                            >
                              Fold again
                            </button>
                          )}
                          {sessionCan({ type: 'DISMISS_TURN_ERROR' }) && (
                            <button
                              onClick={() => session.send({ type: 'DISMISS_TURN_ERROR' })}
                              className="font-display text-[10.5px] uppercase underline"
                              style={{ letterSpacing: '0.12em', color: 'var(--fold-dim)', textUnderlineOffset: '3px' }}
                            >
                              Leave it
                            </button>
                          )}
                        </div>
                      </div>
                    </div>
                  </div>
                )}
              </div>
            </div>

            {/* ---- composer, flush on the sheet ---- */}
            <div style={{ borderTop: '1px solid var(--crease)' }}>
              <div className="px-12 py-5" style={{ maxWidth: 'calc(var(--sheet-measure) + 6rem)' }}>
                <div className="flex items-end gap-4">
                  <div className="flex-1">
                    <textarea
                      rows={2}
                      value={draft}
                      placeholder={inFlight ? 'A fold is being taken.' : 'Say what to build.'}
                      onChange={(ev) => {
                        setDraft(ev.target.value)
                        session.send({ type: 'EDIT_DRAFT', text: ev.target.value })
                      }}
                      onKeyDown={(ev) => {
                        if (ev.key === 'Enter' && (ev.metaKey || ev.ctrlKey) && sessionCan({ type: 'SEND' })) {
                          session.send({ type: 'SEND' })
                          setDraft('')
                        }
                      }}
                      className="w-full resize-none bg-transparent text-[14px] leading-[1.7] outline-none"
                      style={{ color: 'var(--fold)' }}
                    />
                  </div>
                  <div className="flex shrink-0 items-center gap-3 pb-1">
                    {inFlight && <ActiveDot />}
                    {sessionCan({ type: 'SEND' }) && (
                      <button
                        onClick={() => {
                          session.send({ type: 'SEND' })
                          setDraft('')
                        }}
                        className="font-display px-4 py-2 text-[11px] uppercase transition-colors duration-150"
                        style={{
                          letterSpacing: '0.14em',
                          background: 'var(--fold)',
                          color: 'var(--sumi)',
                        }}
                        onMouseEnter={(e) => (e.currentTarget.style.background = 'var(--paper-grey)')}
                        onMouseLeave={(e) => (e.currentTarget.style.background = 'var(--fold)')}
                      >
                        Fold
                      </button>
                    )}
                    {sessionCan({ type: 'INTERRUPT' }) && (
                      <button
                        onClick={() => session.send({ type: 'INTERRUPT' })}
                        className="font-display px-4 py-2 text-[11px] uppercase"
                        style={{
                          letterSpacing: '0.14em',
                          color: 'var(--fold)',
                          border: '1px solid var(--crease)',
                        }}
                      >
                        Release
                      </button>
                    )}
                  </div>
                </div>

                <div className="mt-3 flex items-center gap-4">
                  <span className="text-[11px]" style={{ color: 'var(--fold-dim)' }}>
                    {persistence === 'saveFailed'
                      ? `Not written: ${s?.context.saveError}.`
                      : persistence === 'saving'
                        ? 'Writing the sheet.'
                        : 'Sheet written.'}
                  </span>
                  {sessionCan({ type: 'RETRY_SAVE' }) && (
                    <button
                      onClick={() => session.send({ type: 'RETRY_SAVE' })}
                      className="font-display text-[10.5px] uppercase underline"
                      style={{ letterSpacing: '0.12em', color: 'var(--gold)', textUnderlineOffset: '3px' }}
                    >
                      Write again
                    </button>
                  )}
                  <span className="ml-auto text-[11px]" style={{ color: 'var(--fold-dim)' }}>
                    <span data-numeric>{folds.length}</span> {folds.length === 1 ? 'fold' : 'folds'}
                  </span>
                </div>
              </div>
            </div>
          </>
        )}
      </main>
    </div>
  )
}

function EmptySheet({ ready }: { ready: boolean }) {
  return (
    <div className="flex h-full items-center justify-center px-12">
      <div style={{ maxWidth: '42ch' }}>
        <h1
          className="font-display text-[30px] leading-[1.15] font-light"
          style={{ color: 'var(--fold)', letterSpacing: '-0.01em' }}
        >
          The sheet is flat.
        </h1>
        <p className="mt-4 text-[14px] leading-[1.75]" style={{ color: 'var(--fold-dim)' }}>
          {ready
            ? 'The sandbox holds and the credential is read. Start the agent and the first fold can be taken.'
            : 'Nothing is folded until the sandbox is established and a credential is read. Both conditions are drawn in the rail, and both must close before the agent will start.'}
        </p>
      </div>
    </div>
  )
}
