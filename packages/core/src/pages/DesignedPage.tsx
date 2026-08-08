import { useEffect, useRef, useState } from 'react'
import { useHarness, useChildRevision, toPath } from '../hooks.ts'
import { defaultSeedControls } from '../actors/seeded.ts'
import { ClaudeHeader } from '../components/brainless/claude/claude-header.tsx'
import { ClaudeMessage } from '../components/brainless/claude/claude-message.tsx'
import { ClaudeThinking } from '../components/brainless/claude/claude-thinking.tsx'
import { ClaudePrompt } from '../components/brainless/claude/claude-prompt.tsx'
import { SlashMenu, type Command } from '../components/slash-menu.tsx'
import { commandQuery } from '../domain.ts'
import type { SessionEvent } from '../machines/session.ts'

/**
 * The chat surface: a Claude Code session, rendered with brainless.
 *
 * Every control is filtered through `snapshot.can()`.
 *
 * The harness starts itself. Loading a credential, establishing the sandbox and
 * spawning the agent are not user commands — a launch does them, and asking the
 * user to run them was debug wearing a product's clothes.
 *
 * Harness state is therefore silent while it holds. It appears only when
 * something is wrong, because a permanent row of green dots reporting on seeded
 * actors is a claim the product cannot currently back. `#/bare` shows the full
 * machine state at all times; that is what it is for.
 */

export function DesignedPage() {
  const { snapshot, send } = useHarness(defaultSeedControls)
  const [draft, setDraft] = useState('')
  const scrollRef = useRef<HTMLDivElement>(null)

  const ctx = snapshot.context
  const session = ctx.session
  useChildRevision([...ctx.surfaces, ...(session ? [session] : [])])
  const s = session?.getSnapshot()

  const agentState = toPath((snapshot.value as Record<string, unknown>).agent)
  const turn = s ? toPath((s.value as Record<string, unknown>).turn) : null
  const working = turn === 'sending' || turn === 'streaming'
  const sessionCan = (e: SessionEvent) => Boolean(s?.can(e))

  // Bring the harness up on its own, in order.
  useEffect(() => {
    if (ctx.credentialState === 'absent') send({ type: 'READ_CREDENTIAL' })
  }, [ctx.credentialState, send])

  useEffect(() => {
    if (ctx.credentialState === 'present' && ctx.sandboxState === 'unchecked') {
      send({ type: 'CHECK_SANDBOX' })
    }
  }, [ctx.credentialState, ctx.sandboxState, send])

  useEffect(() => {
    if (ctx.credentialState === 'present' && ctx.sandboxState === 'available' && agentState === 'down') {
      send({ type: 'START' })
    }
  }, [ctx.credentialState, ctx.sandboxState, agentState, send])


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
      name: '/save',
      description: 'Write the session now',
      available: sessionCan({ type: 'SAVE' }),
      run: () => session?.send({ type: 'SAVE' }),
    },
    {
      name: '/restart',
      description: 'Restart the agent',
      available: snapshot.can({ type: 'RESTART' }),
      run: () => send({ type: 'RESTART' }),
    },
    {
      name: '/stop',
      description: 'Stop the agent',
      available: snapshot.can({ type: 'STOP' }),
      run: () => send({ type: 'STOP' }),
    },
  ]

  const query = commandQuery(draft).toLowerCase()
  const commands = allCommands.filter(
    (c) => c.available && c.name.slice(1).toLowerCase().startsWith(query),
  )
  const menuOpen = Boolean(s?.context.menuOpen)
  const menuIndex = Math.min(s?.context.menuIndex ?? 0, Math.max(commands.length - 1, 0))

  const pick = (i: number) => {
    const c = commands[i]
    if (!c) return
    c.run()
    session?.send({ type: 'MENU_COMMIT' })
    setDraft('')
  }

  // Only what is actually wrong, and only while it is wrong.
  const problem = harnessProblem(ctx, agentState)
  const starting = !session && !problem

  return (
    <div className="flex h-full flex-col" style={{ background: 'var(--ground)' }}>
      <div className="flex min-h-0 flex-1">
        <div className="flex min-w-0 flex-1 flex-col">
          <div ref={scrollRef} className="min-h-0 flex-1 overflow-y-auto px-6 py-4">
            <div className="space-y-3" style={{ maxWidth: 'var(--measure)' }}>
              {/*
                Every prop is passed explicitly. The component's defaults carry
                another project's user, org and release notes, and PRODUCT.md is
                clear that nothing fabricated ships.
              */}
              <ClaudeHeader
                cwd="~/Projects/zabaca/varnick"
                model="Opus 5"
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
                    <button onClick={() => send(problem.event!)} style={{ color: 'var(--accent)' }}>
                      {problem.action}
                    </button>
                  )}
                </div>
              )}

              {(s?.context.messages ?? []).map((m) => (
                <ClaudeMessage key={m.id} role={m.role === 'user' ? 'user' : 'assistant'}>
                  {m.text}
                </ClaudeMessage>
              ))}

              {s?.context.partial && <ClaudeMessage>{s.context.partial}</ClaudeMessage>}

              {working && <ClaudeThinking running showTokens={false} />}

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

          <div className="px-6 pb-4" style={{ maxWidth: 'var(--measure)' }}>
            {menuOpen && (
              <SlashMenu
                commands={commands}
                activeIndex={menuIndex}
                onHover={(i) => session?.send({ type: 'MENU_MOVE', delta: i - menuIndex, count: commands.length })}
                onPick={pick}
              />
            )}
            <ClaudePrompt
              value={draft}
              placeholder={
                working ? 'working — esc to interrupt' : 'What should the agent build?  /  for commands'
              }
              effort="xhigh"
              mode="auto"
              onChange={(e) => {
                setDraft(e.target.value)
                session?.send({ type: 'EDIT_DRAFT', text: e.target.value })
              }}
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
                  if (e.key === 'Enter' || e.key === 'Tab') {
                    e.preventDefault()
                    pick(menuIndex)
                    return
                  }
                  if (e.key === 'Escape') {
                    e.preventDefault()
                    session?.send({ type: 'MENU_DISMISS' })
                    return
                  }
                }
                if (e.key === 'Enter' && sessionCan({ type: 'SEND' })) {
                  session?.send({ type: 'SEND' })
                  setDraft('')
                }
                if (e.key === 'Escape' && sessionCan({ type: 'INTERRUPT' })) {
                  session?.send({ type: 'INTERRUPT' })
                }
              }}
            />
          </div>
        </div>

      </div>
    </div>
  )
}

type Problem = { text: string; action?: string; event?: Parameters<ReturnType<typeof useHarness>['send']>[0] }

/** Nothing while the harness holds. A named problem and its recovery when it does not. */
function harnessProblem(
  ctx: ReturnType<typeof useHarness>['snapshot']['context'],
  agentState: string,
): Problem | null {
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
