import { useEffect, useRef, useState } from 'react'
import { useHarness, useChildRevision, toPath } from '../hooks.ts'
import { canStartAgent } from '../domain.ts'
import { defaultSeedControls } from '../actors/seeded.ts'
import { seedSurfaces } from '../data/seed.ts'
import { readings, ConditionRun, ConditionStack, Dot } from '../components/conditions.tsx'
import { ClaudeHeader } from '../components/brainless/claude/claude-header.tsx'
import { ClaudeMessage } from '../components/brainless/claude/claude-message.tsx'
import { ClaudeThinking } from '../components/brainless/claude/claude-thinking.tsx'
import { ClaudePrompt } from '../components/brainless/claude/claude-prompt.tsx'
import type { HarnessEvent } from '../machines/harness.ts'
import type { SessionEvent } from '../machines/session.ts'

/**
 * The chat surface: a Claude Code session, rendered with brainless.
 *
 * Every control is still filtered through `snapshot.can()` — the world changed,
 * the rule did not. Readiness for starting the agent comes from
 * canStartAgent(), never from can(), whose unguarded refusal fallback makes it
 * permanently true.
 *
 * The three condition placements below are live variants so they can be
 * compared against real machine state rather than described. One of them wins
 * and the other two get deleted.
 */

type Placement = 'header' | 'statusline' | 'rail'

const HARNESS_CONTROLS: { event: HarnessEvent; label: string }[] = [
  { event: { type: 'READ_CREDENTIAL' }, label: 'load credential' },
  { event: { type: 'CHECK_SANDBOX' }, label: 'check sandbox' },
  { event: { type: 'START' }, label: 'start agent' },
  { event: { type: 'RESTART' }, label: 'restart agent' },
  { event: { type: 'STOP' }, label: 'stop agent' },
  { event: { type: 'DISCOVER_SURFACES', descriptors: seedSurfaces }, label: 'find surfaces' },
]

function Action({ label, onClick }: { label: string; onClick: () => void }) {
  return (
    <button
      onClick={onClick}
      className="whitespace-nowrap transition-colors duration-100"
      style={{ color: 'var(--fg-dim)' }}
      onMouseEnter={(e) => (e.currentTarget.style.color = 'var(--accent)')}
      onMouseLeave={(e) => (e.currentTarget.style.color = 'var(--fg-dim)')}
    >
      /{label}
    </button>
  )
}

export function DesignedPage() {
  const { snapshot, send } = useHarness(defaultSeedControls)
  const [draft, setDraft] = useState('')
  const [placement, setPlacement] = useState<Placement>('statusline')
  const scrollRef = useRef<HTMLDivElement>(null)

  const ctx = snapshot.context
  const session = ctx.session
  useChildRevision([...ctx.surfaces, ...(session ? [session] : [])])
  const s = session?.getSnapshot()

  const agentState = toPath((snapshot.value as Record<string, unknown>).agent)
  const turn = s ? toPath((s.value as Record<string, unknown>).turn) : null
  const persistence = s ? toPath((s.value as Record<string, unknown>).persistence) : null
  const working = turn === 'sending' || turn === 'streaming'
  const ready = canStartAgent({ credential: ctx.credentialState, sandbox: ctx.sandboxState })

  const items = readings(ctx, agentState)
  const sessionCan = (e: SessionEvent) => Boolean(s?.can(e))

  useEffect(() => {
    scrollRef.current?.scrollTo({ top: scrollRef.current.scrollHeight, behavior: 'smooth' })
  }, [s?.context.messages.length, s?.context.partial, turn])

  const actions = (
    <div className="flex flex-wrap items-center gap-x-4 gap-y-1">
      {HARNESS_CONTROLS.filter((c) => snapshot.can(c.event)).map((c) => (
        <Action key={c.label} label={c.label} onClick={() => send(c.event)} />
      ))}
    </div>
  )

  const transcript = (
    <div ref={scrollRef} className="min-h-0 flex-1 overflow-y-auto px-6 py-4">
      <div className="space-y-3" style={{ maxWidth: 'var(--measure)' }}>
        {/*
          Every prop is passed explicitly. The component's defaults carry
          another project's user, org, and release notes, and PRODUCT.md is
          clear that nothing fabricated ships.
        */}
        <ClaudeHeader
          cwd="~/Projects/zabaca/varnick"
          model="Opus 5 · confined by sandbox-runtime"
          user="you"
          org=""
          version="v0.0.0"
          tips={['Ask for a Surface and it appears in the sidebar']}
          whatsNew={[]}
        />

        {placement === 'header' && (
          <div className="pt-1 pb-1">
            <ConditionRun items={items} />
          </div>
        )}

        {!session && (
          <div style={{ color: 'var(--fg-dim)' }}>
            {ready
              ? 'Sandbox and credential are ready. Start the agent to begin.'
              : 'The agent will not start until the sandbox is confined and a credential is loaded.'}
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
              <button
                onClick={() => session?.send({ type: 'RETRY_TURN' })}
                style={{ color: 'var(--accent)' }}
              >
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
      </div>
    </div>
  )

  const composer = (
    <div className="px-6 pb-4" style={{ maxWidth: 'var(--measure)' }}>
      {placement === 'statusline' && (
        <div
          className="mb-2 flex flex-wrap items-center gap-x-5 gap-y-1 py-1.5 text-[12px]"
          style={{ borderTop: '1px solid var(--rule)', borderBottom: '1px solid var(--rule)' }}
        >
          <ConditionRun items={items} />
          <span className="ml-auto" style={{ color: 'var(--fg-faint)' }}>
            {persistence === 'saveFailed'
              ? `not saved — ${s?.context.saveError}`
              : persistence === 'saving'
                ? 'saving'
                : 'saved'}
          </span>
        </div>
      )}

      <ClaudePrompt
        value={draft}
        placeholder={working ? 'working — esc to interrupt' : 'What should the agent build?'}
        effort="xhigh"
        mode="auto"
        onChange={(e) => {
          setDraft(e.target.value)
          session?.send({ type: 'EDIT_DRAFT', text: e.target.value })
        }}
        onKeyDown={(e) => {
          if (e.key === 'Enter' && sessionCan({ type: 'SEND' })) {
            session?.send({ type: 'SEND' })
            setDraft('')
          }
          if (e.key === 'Escape' && sessionCan({ type: 'INTERRUPT' })) {
            session?.send({ type: 'INTERRUPT' })
          }
        }}
      />

      <div className="mt-2 flex flex-wrap items-center gap-x-4 gap-y-1 text-[12px]">
        {actions}
        {sessionCan({ type: 'INTERRUPT' }) && (
          <button onClick={() => session?.send({ type: 'INTERRUPT' })} style={{ color: 'var(--warn)' }}>
            interrupt
          </button>
        )}
        {sessionCan({ type: 'RETRY_SAVE' }) && (
          <button onClick={() => session?.send({ type: 'RETRY_SAVE' })} style={{ color: 'var(--accent)' }}>
            retry save
          </button>
        )}
      </div>
    </div>
  )

  return (
    <div className="flex h-full flex-col" style={{ background: 'var(--ground)' }}>
      <VariantSwitch placement={placement} onChange={setPlacement} />

      <div className="flex min-h-0 flex-1">
        {placement === 'rail' && (
          <aside
            className="flex w-[240px] shrink-0 flex-col gap-4 overflow-y-auto px-4 py-4 text-[12px]"
            style={{ borderRight: '1px solid var(--rule)' }}
          >
            <ConditionStack items={items} />
            {ctx.surfaces.length > 0 && <SurfaceList surfaces={ctx.surfaces} />}
          </aside>
        )}

        <div className="flex min-w-0 flex-1 flex-col">
          {transcript}
          {composer}
        </div>

        {placement !== 'rail' && ctx.surfaces.length > 0 && (
          <aside
            className="w-[220px] shrink-0 overflow-y-auto px-4 py-4 text-[12px]"
            style={{ borderLeft: '1px solid var(--rule)' }}
          >
            <SurfaceList surfaces={ctx.surfaces} />
          </aside>
        )}
      </div>
    </div>
  )
}

function SurfaceList({ surfaces }: { surfaces: ReturnType<typeof useHarness>['snapshot']['context']['surfaces'] }) {
  return (
    <div>
      <div className="mb-2" style={{ color: 'var(--fg-faint)' }}>
        surfaces
      </div>
      <div className="flex flex-col gap-2">
        {surfaces.map((ref) => {
          const snap = ref.getSnapshot()
          const state = toPath(snap.value)
          return (
            <div key={ref.id}>
              <div className="flex items-baseline gap-1.5">
                <Dot tone={state === 'loaded' ? 'ok' : state === 'failed' ? 'bad' : 'pending'} />
                <span>{snap.context.descriptor.name}</span>
              </div>
              {snap.context.error && (
                <div className="pl-4 text-[11.5px] leading-snug" style={{ color: 'var(--fg-faint)' }}>
                  {snap.context.error}{' '}
                  {snap.can({ type: 'RETRY' }) && (
                    <button onClick={() => ref.send({ type: 'RETRY' })} style={{ color: 'var(--accent)' }}>
                      retry
                    </button>
                  )}
                </div>
              )}
            </div>
          )
        })}
      </div>
    </div>
  )
}

/** Temporary. Delete with the two losing placements once one is chosen. */
function VariantSwitch({
  placement,
  onChange,
}: {
  placement: Placement
  onChange: (p: Placement) => void
}) {
  return (
    <div
      className="flex items-center gap-4 px-6 py-1.5 text-[11.5px]"
      style={{ borderBottom: '1px solid var(--rule)', color: 'var(--fg-faint)' }}
    >
      <span>conditions:</span>
      {(['header', 'statusline', 'rail'] as Placement[]).map((p) => (
        <button
          key={p}
          onClick={() => onChange(p)}
          style={{
            color: placement === p ? 'var(--accent)' : 'var(--fg-faint)',
            textDecoration: placement === p ? 'underline' : 'none',
            textUnderlineOffset: '3px',
          }}
        >
          {p}
        </button>
      ))}
      <nav className="ml-auto flex gap-3">
        <a href="#/bare">bare</a>
        <a href="#/states">states</a>
      </nav>
    </div>
  )
}
