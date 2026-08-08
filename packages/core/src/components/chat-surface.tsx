import { useEffect, useRef, useState, type ComponentType } from 'react'
import type { ActorRefFrom, SnapshotFrom } from 'xstate'
import { useChildRevision, toPath } from '../hooks.ts'
import { UNIMPLEMENTED, type ActorMode } from '../actors/index.ts'
import type { surfaceMachine } from '../machines/surface.ts'
import { ClaudeHeader } from './brainless/claude/claude-header.tsx'
import { ClaudeMessage } from './brainless/claude/claude-message.tsx'
import { ClaudeThinking } from './brainless/claude/claude-thinking.tsx'
import { ClaudePrompt } from './brainless/claude/claude-prompt.tsx'
import { SlashMenu, type Command } from './slash-menu.tsx'
import {
  commandQuery,
  invokedCommand,
  formatContext,
  CONTEXT_WINDOW,
  EFFORTS,
  MODELS,
} from '../domain.ts'
import type { SubscriptionUsage } from '../domain.ts'
import type { harnessMachine, HarnessEvent } from '../machines/harness.ts'
import type { SessionEvent } from '../machines/session.ts'

/**
 * The chat surface: a Claude Code session, rendered with brainless.
 *
 * A pure function of `(snapshot, send)` — ADR-0001. It holds no machine of its
 * own, which is what lets the live app and the states page render the same
 * component rather than two copies that drift. Start-up, retry policy and mode
 * selection belong to whoever owns the actor.
 *
 * Every control is filtered through `snapshot.can()`.
 *
 * Harness state is silent while it holds. It appears only when something is
 * wrong, because a permanent row of green dots reporting on seeded actors is a
 * claim the product cannot currently back. `#/bare` shows the full machine state
 * at all times; that is what it is for.
 */

export type HarnessSnapshot = SnapshotFrom<typeof harnessMachine>

export interface ChatSurfaceProps {
  snapshot: HarnessSnapshot
  send: (event: HarnessEvent) => void
  mode: ActorMode
  /**
   * Whether this conversation was restored from the mirror with something
   * redacted out of it.
   *
   * A prop rather than machine context, for the same reason `mode` is one: it
   * is a fact about how this run started, and start-up belongs to whoever owns
   * the actor. The machines stay unchanged by resume — a restored Session is
   * `turn.idle` with messages, which is a state that already existed.
   */
  restoredRedacted?: boolean
  /** Called before a recovery event, so the owner can re-arm its start-up. */
  onRecover?: () => void
  /**
   * What a loaded Surface renders, looked up by module path.
   *
   * A prop rather than a lookup this component does for itself, for the same
   * reason `mode` is one: the loader is a module that scans the filesystem, and
   * ADR-0001 keeps this surface a function of its arguments. The live pages pass
   * the real loader's record; `#/states` passes nothing, because Userspace
   * content is not Core's to invent and a card that faked one would be the mock
   * the states page exists to avoid.
   */
  resolveSurface?: (modulePath: string) => ComponentType | undefined
}

export function ChatSurface({
  snapshot,
  send,
  mode,
  restoredRedacted,
  onRecover,
  resolveSurface,
}: ChatSurfaceProps) {
  const scrollRef = useRef<HTMLDivElement>(null)

  const ctx = snapshot.context
  const session = ctx.session
  // Surfaces run on their own clocks, so one failing has to reach React here or
  // the panel keeps claiming `loading` for a module that gave up.
  useChildRevision([...ctx.surfaces, ...(session ? [session] : [])])
  const s = session?.getSnapshot()

  const agentState = toPath((snapshot.value as Record<string, unknown>).agent)
  const turn = s ? toPath((s.value as Record<string, unknown>).turn) : null
  // One check, because there is one state: a Turn is in flight or it is not.
  const working = turn?.startsWith('answering') ?? false
  const sessionCan = (e: SessionEvent) => Boolean(s?.can(e))

  /*
    The draft lives in the machine, not beside it.

    A local mirror was the earlier arrangement and it gave the composer two
    sources of truth — MENU_COMPLETE writes the draft, so the mirror had to be
    written twice on every path. It also made a seeded composer unrenderable,
    which is precisely what the states page needs.
  */
  const draft = s?.context.draft ?? ''

  useEffect(() => {
    scrollRef.current?.scrollTo({ top: scrollRef.current.scrollHeight, behavior: 'smooth' })
  }, [s?.context.messages.length, s?.context.partial, turn])

  /*
    Commands are the events the machines currently accept, nothing more. A
    command that cannot run is not offered — the same rule as every other
    control here, so the menu cannot drift into advertising capability the
    product does not have.
  */
  const allCommands: Command[] = [
    {
      name: '/clear',
      description: 'Clear the conversation',
      available: sessionCan({ type: 'CLEAR' }) && (s?.context.messages.length ?? 0) > 0,
      run: () => session?.send({ type: 'CLEAR' }),
    },
    {
      name: '/compact',
      description: 'Summarise the conversation to free context',
      available: sessionCan({ type: 'COMPACT' }) && (s?.context.messages.length ?? 0) > 0,
      run: () => session?.send({ type: 'COMPACT' }),
    },
    {
      name: '/retry',
      description: 'Retry the turn that failed',
      available: sessionCan({ type: 'RETRY_TURN' }),
      run: () => session?.send({ type: 'RETRY_TURN' }),
    },
    {
      name: '/interrupt',
      description: 'Stop the turn in progress',
      available: sessionCan({ type: 'INTERRUPT' }),
      run: () => session?.send({ type: 'INTERRUPT' }),
    },
    {
      name: '/restart',
      description: 'Restart the agent',
      available: snapshot.can({ type: 'RESTART' }),
      run: () => send({ type: 'RESTART' }),
    },
    /*
      Values are separate entries rather than an argument to parse. Typing
      `/eff` filters to the five levels, Tab completes one, Enter runs it — no
      argument parsing, and no error surface for a value that was never typed.

      Every value is listed, including the one in force, marked rather than
      hidden: the list doubles as the answer to "what is this set to", which is
      most of why anyone types /model.
    */
    ...EFFORTS.map((e) => ({
      name: `/effort ${e}`,
      description:
        e === s?.context.effort ? `Current — next turn runs at ${e}` : `Run the next turn at ${e} effort`,
      available: Boolean(session),
      run: () => session?.send({ type: 'SET_EFFORT', effort: e }),
    })),
    ...MODELS.map((m) => ({
      name: `/model ${m.label}`,
      description:
        m.id === s?.context.model ? `Current — next turn runs on ${m.label}` : `Run the next turn on ${m.label}`,
      available: Boolean(session),
      run: () => session?.send({ type: 'SET_MODEL', model: m.id }),
    })),
  ]

  const query = commandQuery(draft).toLowerCase()
  const commands = allCommands.filter(
    (c) => c.available && c.name.toLowerCase().startsWith(query),
  )
  const availableNames = allCommands.filter((c) => c.available).map((c) => c.name)
  const menuOpen = Boolean(s?.context.menuOpen)
  const menuIndex = Math.min(s?.context.menuIndex ?? 0, Math.max(commands.length - 1, 0))

  // The machine derives menu state from the names, so they have to stay current
  // as availability changes.
  const nameKey = availableNames.join('\u0000')
  useEffect(() => {
    session?.send({ type: 'SET_COMMANDS', names: nameKey ? nameKey.split('\u0000') : [] })
  }, [nameKey, session])

  /** Tab, or a click: put the command in the draft and stop there. */
  const complete = (i: number) => {
    const c = commands[i]
    if (!c) return
    session?.send({ type: 'MENU_COMPLETE', name: c.name })
  }

  /** Enter: send. A draft that names a command runs it instead of posting it. */
  const submit = () => {
    const name = invokedCommand(draft, allCommands.map((c) => c.name))
    const command = name ? allCommands.find((c) => c.name === name) : undefined
    if (command?.available) {
      command.run()
      session?.send({ type: 'EDIT_DRAFT', text: '' })
      return
    }
    if (sessionCan({ type: 'SEND' })) session?.send({ type: 'SEND' })
  }

  // One label, read by the welcome box and by the composer, so the two cannot
  // disagree about what the next turn runs on.
  const modelLabel = MODELS.find((m) => m.id === s?.context.model)?.label ?? 'opus-5'

  // Only what is actually wrong, and only while it is wrong.
  const problem = harnessProblem(ctx, agentState)
  const starting = !session && !problem

  return (
    <div className="flex h-full flex-col" style={{ background: 'var(--ground)' }}>
      <PlanUsage usage={ctx.subscription} mode={mode} />
      <div className="flex min-h-0 flex-1">
        <div className="flex min-w-0 flex-1 flex-col">
          <div ref={scrollRef} className="min-h-0 flex-1 overflow-y-auto px-6 py-4">
            <div className="space-y-3" style={{ maxWidth: 'var(--prose)' }}>
              {/*
                Every prop is passed explicitly. The component's defaults carry
                another project's user, org and release notes, and PRODUCT.md is
                clear that nothing fabricated ships.

                `cwd` and `org` are empty for the same reason, one step further
                on: a stranger's clone is not the author's. This surface is a
                pure function of `(snapshot, send)` — ADR-0001 — so it has no
                filesystem to ask and nothing true to put here. An invented path
                would be a lie on the first frame of a fresh clone, which is
                exactly what it used to be.

                The model is read from the Session rather than written down, so
                the welcome box and the composer cannot disagree about what the
                next turn runs on.
              */}
              <ClaudeHeader
                cwd=""
                model={modelLabel}
                user="you"
                org=""
                version="v0.0.0"
                tips={['Describe what you want built and the agent goes and builds it']}
                whatsNew={[]}
              />

              {starting && <div style={{ color: 'var(--fg-faint)' }}>Starting the agent…</div>}

              {problem && (
                <div style={{ color: 'var(--bad)' }}>
                  <span aria-hidden>✗ </span>
                  {problem.text}{' '}
                  {problem.event && (
                    <button
                      onClick={() => {
                        onRecover?.()
                        send(problem.event!)
                      }}
                      style={{ color: 'var(--accent)' }}
                    >
                      {problem.action}
                    </button>
                  )}
                </div>
              )}

              {/*
                The one thing a restored conversation owes the developer.

                The mirror is redacted on the way in, so a message can read
                `[redacted]` where a secret value was. That is not undone —
                reading a secret back onto the screen after deliberately keeping
                it off disk would defeat the redaction, and a second unredacted
                copy would be a durable plaintext secret store kept for looks.
                What is owed is that the developer can tell they are reading the
                record rather than what they typed. Said once, above the
                transcript it is about, in the same shape as every other thing
                this surface admits — and gone once the transcript is.
              */}
              {restoredRedacted && (s?.context.messages.length ?? 0) > 0 && (
                <div style={{ color: 'var(--warn)' }}>
                  <span aria-hidden>⚠ </span>
                  Restored from the Session mirror — secret values are kept off disk, so{' '}
                  <span style={{ color: 'var(--fg-dim)' }}>[redacted]</span> stands where one was.
                </div>
              )}

              {(s?.context.messages ?? []).map((m) => (
                <ClaudeMessage key={m.id} role={m.role === 'user' ? 'user' : 'assistant'}>
                  {m.text}
                </ClaudeMessage>
              ))}

              {s?.context.partial && <ClaudeMessage>{s.context.partial}</ClaudeMessage>}

              {working && <ClaudeThinking running showTokens={false} />}

              {turn === 'compacting' && (
                <div style={{ color: 'var(--fg-dim)' }}>Summarising the conversation…</div>
              )}

              {s?.context.compactError && turn !== 'compacting' && (
                <div style={{ color: 'var(--warn)' }}>
                  <span aria-hidden>⚠ </span>
                  Could not compact — {s.context.compactError}. The conversation is unchanged.
                </div>
              )}

              {turn === 'failed' && s?.context.turnError && (
                <div className="flex flex-wrap items-baseline gap-x-3" style={{ color: 'var(--bad)' }}>
                  <span>
                    <span aria-hidden>✗ </span>
                    {s.context.turnError}
                  </span>
                  {sessionCan({ type: 'RETRY_TURN' }) && (
                    <button onClick={() => session?.send({ type: 'RETRY_TURN' })} style={{ color: 'var(--accent)' }}>
                      retry
                    </button>
                  )}
                  {sessionCan({ type: 'DISMISS_TURN_ERROR' }) && (
                    <button
                      onClick={() => session?.send({ type: 'DISMISS_TURN_ERROR' })}
                      style={{ color: 'var(--fg-dim)' }}
                    >
                      dismiss
                    </button>
                  )}
                </div>
              )}

              {s?.context.saveError && (
                <div className="flex flex-wrap items-baseline gap-x-3" style={{ color: 'var(--warn)' }}>
                  <span>
                    <span aria-hidden>⚠ </span>
                    Not saved — {s.context.saveError}
                  </span>
                  {sessionCan({ type: 'RETRY_SAVE' }) && (
                    <button onClick={() => session?.send({ type: 'RETRY_SAVE' })} style={{ color: 'var(--accent)' }}>
                      retry
                    </button>
                  )}
                </div>
              )}
            </div>
          </div>

          <div className="px-6 pb-4">
            {menuOpen && (
              <SlashMenu
                commands={commands}
                activeIndex={menuIndex}
                onHover={(i) => session?.send({ type: 'MENU_MOVE', delta: i - menuIndex, count: commands.length })}
                onPick={complete}
              />
            )}
            <ClaudePrompt
              value={draft}
              placeholder={
                working ? 'working — esc to interrupt' : 'What should the agent build?  /  for commands'
              }
              effort={s?.context.effort ?? 'xhigh'}
              model={`${modelLabel} · ${formatContext(
                s?.context.tokensUsed ?? 0,
                CONTEXT_WINDOW[s?.context.model ?? 'claude-opus-5'],
              )}`}
              // No mode cycling in varnick, so the mode line would describe a
              // control that does not exist.
              mode={false}
              onChange={(e) => session?.send({ type: 'EDIT_DRAFT', text: e.target.value })}
              onKeyDown={(e) => {
                if (menuOpen) {
                  // While the menu is open the keyboard belongs to it. SEND is
                  // already refused by the machine's guard; this is the rest.
                  if (e.key === 'ArrowDown' || e.key === 'ArrowUp') {
                    e.preventDefault()
                    session?.send({
                      type: 'MENU_MOVE',
                      delta: e.key === 'ArrowDown' ? 1 : -1,
                      count: commands.length,
                    })
                    return
                  }
                  if (e.key === 'Tab') {
                    e.preventDefault()
                    complete(menuIndex)
                    return
                  }
                  if (e.key === 'Escape') {
                    e.preventDefault()
                    session?.send({ type: 'MENU_DISMISS' })
                    return
                  }
                }
                if (e.key === 'Enter') {
                  e.preventDefault()
                  submit()
                }
                if (e.key === 'Escape' && sessionCan({ type: 'INTERRUPT' })) {
                  session?.send({ type: 'INTERRUPT' })
                }
              }}
            />
          </div>
        </div>

        {/*
          The Surfaces, beside the conversation that built them.

          Stacked in the order discovery found them, and that is the whole of the
          arrangement — a way to place several is a layout system, which is what
          a fork builds. What must be true here is narrower and load-bearing: one
          Surface failing leaves its siblings rendered and the chat on the left
          untouched (ADR-0004).
        */}
        {ctx.surfaces.length > 0 && (
          <aside
            className="min-h-0 w-[320px] shrink-0 overflow-y-auto"
            style={{ borderLeft: '1px solid var(--rule)' }}
          >
            {ctx.surfaces.map((ref) => (
              <SurfacePanel
                key={ref.id}
                surface={ref}
                resolveSurface={resolveSurface}
                onUnload={(id) => send({ type: 'UNLOAD_SURFACE', id })}
              />
            ))}
          </aside>
        )}
      </div>
    </div>
  )
}

/**
 * One Surface, in whichever of its states it is in.
 *
 * Every branch is the machine's, read rather than inferred, and `retry` appears
 * because `failed` accepts `RETRY` — the same rule as every other control here.
 * A loaded Surface has no retry button because the state has no handler.
 */
function SurfacePanel({
  surface,
  resolveSurface,
  onUnload,
}: {
  surface: ActorRefFrom<typeof surfaceMachine>
  resolveSurface?: (modulePath: string) => ComponentType | undefined
  onUnload: (id: string) => void
}) {
  const snap = surface.getSnapshot()
  const { descriptor, error, attempts } = snap.context
  const state = toPath(snap.value)
  const View = state === 'loaded' ? resolveSurface?.(descriptor.modulePath) : undefined

  return (
    <section className="px-4 py-3" style={{ borderBottom: '1px solid var(--rule)' }}>
      <div className="flex items-baseline gap-2 text-[12px]">
        <h2 style={{ color: 'var(--fg)' }}>{descriptor.name}</h2>
        <code style={{ color: 'var(--fg-faint)' }}>{state}</code>
        {/*
          UNLOAD_SURFACE to the parent, not UNLOAD to the child. The child event
          drives the Surface to `unloaded`, which is final — but the parent keeps
          the ref, so the id stays in the set discovery treats as already known
          and the panel can never come back. One dead panel until relaunch.
        */}
        {snap.can({ type: 'UNLOAD' }) && (
          <button
            className="ml-auto"
            onClick={() => onUnload(descriptor.id)}
            style={{ color: 'var(--fg-faint)' }}
          >
            unload
          </button>
        )}
      </div>

      <div className="mt-2">
        {state === 'loading' && (
          <p className="text-[12px]" style={{ color: 'var(--fg-faint)' }}>
            Loading {descriptor.modulePath}
            {attempts > 1 ? ` — attempt ${attempts}` : ''}…
          </p>
        )}

        {/*
          What a module that does not compile looks like: the reason, in full,
          against the Surface it belongs to. Not a toast and not a console line —
          the failure has a place on screen because the Surface does, and the
          chat is still there to ask about it.
        */}
        {state === 'failed' && (
          <div className="text-[12px]" style={{ color: 'var(--bad)' }}>
            <p>
              <span aria-hidden>✗ </span>
              {error ?? 'The module did not load.'}
            </p>
            {/*
              Which attempt this was. A retry that lands back on the same
              sentence is indistinguishable from a button that did nothing, and
              "did the retry run?" is the first thing a developer asks when the
              module they just fixed still will not load.
            */}
            {attempts > 1 && (
              <p style={{ color: 'var(--fg-faint)' }}>attempt {attempts}</p>
            )}
            {snap.can({ type: 'RETRY' }) && (
              <button
                className="mt-1.5"
                onClick={() => surface.send({ type: 'RETRY' })}
                style={{ color: 'var(--accent)' }}
              >
                retry
              </button>
            )}
          </div>
        )}

        {/*
          Userspace's code, running in Core's window. `View` is whatever the
          module default-exported; if this build never imported one there is
          nothing here to draw, and nothing is drawn.
        */}
        {View && <View />}
      </div>
    </section>
  )
}

/**
 * Plan usage, outside the chat shell.
 *
 * Whether these numbers are measured or seeded is answered once, by the marker
 * beside them, rather than by this component second-guessing each value.
 */
function PlanUsage({ usage, mode }: { usage: SubscriptionUsage | null; mode: ActorMode }) {
  if (!usage) return null
  return (
    <div
      className="flex items-center gap-5 px-6 py-1.5 text-[11.5px]"
      style={{ borderBottom: '1px solid var(--rule)', color: 'var(--fg-faint)' }}
    >
      <span>plan usage</span>
      <span>
        5h{' '}
        <span data-numeric style={{ color: 'var(--fg-dim)' }}>
          {usage.fiveHourPct}%
        </span>
      </span>
      <span>
        week{' '}
        <span data-numeric style={{ color: 'var(--fg-dim)' }}>
          {usage.weeklyPct}%
        </span>
      </span>
      <SeededMarker mode={mode} />
    </div>
  )
}

/**
 * The one place the build admits what it is.
 *
 * It gates on `mode`, and only on `mode`. A seeded run invents every number on
 * this screen — plausibly and deliberately — so the warning is true whatever
 * else is wired, and it goes away when a run stops being seeded rather than when
 * some list empties.
 *
 * `UNIMPLEMENTED` is read for the tooltip and for nothing else. This was written
 * the other way round once, and driving it showed the difference: a list-driven
 * marker goes quiet on the last wiring while a seeded surface is still rendering
 * seeded figures, which is the exact claim it exists to stop anyone making.
 */
function SeededMarker({ mode }: { mode: ActorMode }) {
  const [open, setOpen] = useState(false)
  if (mode === 'live') return null
  return (
    <span className="relative ml-auto">
      <button
        onClick={() => setOpen((o) => !o)}
        style={{ color: 'var(--warn)' }}
        aria-expanded={open}
      >
        seeded data — nothing here is measured
      </button>
      {open && (
        <span
          className="absolute right-0 z-10 mt-1 block w-[380px] p-3 text-left leading-relaxed"
          style={{
            background: 'var(--ground-raised)',
            border: '1px solid var(--rule)',
            color: 'var(--fg-dim)',
          }}
        >
          These actors have no live implementation yet:
          <span className="mt-1.5 block" style={{ color: 'var(--fg-faint)' }}>
            {UNIMPLEMENTED.join(', ')}
          </span>
          <span className="mt-2 block">
            Machines, states and refusals are real; the services behind them are
            stubs. Append <span style={{ color: 'var(--fg-dim)' }}>?actors=live</span> to fail on
            the first one that is missing.
          </span>
        </span>
      )}
    </span>
  )
}

type Problem = { text: string; action?: string; event?: HarnessEvent }

/** Nothing while the harness holds. A named problem and its recovery when it does not. */
function harnessProblem(ctx: HarnessSnapshot['context'], agentState: string): Problem | null {
  if (ctx.sandboxState === 'unavailable') {
    return {
      text: `The sandbox could not be established${ctx.sandboxError ? ` — ${ctx.sandboxError}` : ''}. The agent will not run unconfined.`,
      action: 'try again',
      event: { type: 'CHECK_SANDBOX' },
    }
  }
  if (ctx.credentialState === 'rejected') {
    return { text: 'The stored credential was rejected.', action: 'try again', event: { type: 'READ_CREDENTIAL' } }
  }
  if (ctx.credentialState === 'absent' && ctx.credentialError) {
    return {
      text: `Could not read a credential — ${ctx.credentialError}`,
      action: 'try again',
      event: { type: 'READ_CREDENTIAL' },
    }
  }
  if (ctx.credentialState === 'absent' && ctx.sandboxState !== 'unchecked') {
    return { text: 'No credential is available.', action: 'try again', event: { type: 'READ_CREDENTIAL' } }
  }
  if (agentState === 'crashed') {
    return {
      text: `The agent stopped${ctx.agentError ? ` — ${ctx.agentError}` : ''}.`,
      action: 'restart',
      event: { type: 'RESTART' },
    }
  }
  return null
}
