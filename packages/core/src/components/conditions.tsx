import type { HarnessContext } from '../machines/harness.ts'

/**
 * The three harness conditions, in Claude Code's own visual language.
 *
 * A dot and a plain reading — the same grammar the transcript uses for tool
 * status. Green when the condition holds, amber while it is being established,
 * red when it does not hold and the agent will not run.
 */

export type ConditionTone = 'ok' | 'pending' | 'bad'

export interface Reading {
  label: string
  value: string
  tone: ConditionTone
  detail?: string | undefined
}

const TONE: Record<ConditionTone, string> = {
  ok: 'var(--ok)',
  pending: 'var(--warn)',
  bad: 'var(--bad)',
}

export function readings(ctx: HarnessContext, agentState: string): Reading[] {
  const sandbox: Reading =
    ctx.sandboxState === 'available'
      ? { label: 'sandbox', value: 'confined', tone: 'ok' }
      : ctx.sandboxState === 'checking'
        ? { label: 'sandbox', value: 'checking', tone: 'pending' }
        : ctx.sandboxState === 'unavailable'
          ? {
              label: 'sandbox',
              value: 'unavailable',
              tone: 'bad',
              detail: ctx.sandboxError ?? undefined,
            }
          : { label: 'sandbox', value: 'not checked', tone: 'bad' }

  const credential: Reading =
    ctx.credentialState === 'present'
      ? { label: 'credential', value: 'loaded', tone: 'ok' }
      : ctx.credentialState === 'reading'
        ? { label: 'credential', value: 'reading', tone: 'pending' }
        : ctx.credentialState === 'rejected'
          ? { label: 'credential', value: 'rejected', tone: 'bad' }
          : { label: 'credential', value: 'none', tone: 'bad' }

  const agent: Reading =
    agentState === 'running'
      ? { label: 'agent', value: 'running', tone: 'ok' }
      : agentState === 'starting'
        ? { label: 'agent', value: 'starting', tone: 'pending' }
        : agentState === 'crashed'
          ? { label: 'agent', value: 'exited', tone: 'bad', detail: ctx.agentError ?? undefined }
          : agentState === 'startRefused'
            ? { label: 'agent', value: "won't start", tone: 'bad', detail: refusalText(ctx.refusal) }
            : { label: 'agent', value: 'stopped', tone: 'bad' }

  return [sandbox, credential, agent]
}

function refusalText(refusal: HarnessContext['refusal']): string | undefined {
  if (!refusal) return undefined
  if (refusal.kind === 'no-credential') return 'no credential loaded'
  if (refusal.kind === 'credential-rejected') return 'credential was rejected'
  return 'sandbox is not confined'
}

export function Dot({ tone }: { tone: ConditionTone }) {
  return (
    <span aria-hidden style={{ color: TONE[tone] }}>
      ●
    </span>
  )
}

/** Inline run, for a header or a status line. */
export function ConditionRun({ items }: { items: Reading[] }) {
  return (
    <span className="inline-flex flex-wrap items-center gap-x-4 gap-y-1">
      {items.map((r) => (
        <span key={r.label} className="inline-flex items-center gap-1.5 whitespace-nowrap">
          <Dot tone={r.tone} />
          <span style={{ color: 'var(--fg-dim)' }}>{r.label}</span>
          <span style={{ color: r.tone === 'ok' ? 'var(--fg)' : TONE[r.tone] }}>{r.value}</span>
        </span>
      ))}
    </span>
  )
}

/** Stacked, for a rail. */
export function ConditionStack({ items }: { items: Reading[] }) {
  return (
    <div className="flex flex-col gap-2">
      {items.map((r) => (
        <div key={r.label}>
          <div className="flex items-baseline gap-1.5">
            <Dot tone={r.tone} />
            <span style={{ color: 'var(--fg-dim)' }}>{r.label}</span>
            <span className="ml-auto" style={{ color: r.tone === 'ok' ? 'var(--fg)' : TONE[r.tone] }}>
              {r.value}
            </span>
          </div>
          {r.detail && (
            <div className="pl-4 text-[11.5px] leading-snug" style={{ color: 'var(--fg-faint)' }}>
              {r.detail}
            </div>
          )}
        </div>
      ))}
    </div>
  )
}
