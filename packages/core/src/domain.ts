// Domain types and pure helpers. No framework, no XState, no React.

/** Where the agent's credential came from. */
export type CredentialSource = 'keychain' | 'env'

export interface Credential {
  readonly source: CredentialSource
  /** Never the value itself — Core only ever needs to know one exists. */
  readonly present: true
}

/** Why the Harness refused to start the agent. Shown, not swallowed. */
export type StartRefusal =
  | { kind: 'no-credential' }
  | { kind: 'credential-rejected'; detail: string }
  | { kind: 'sandbox-unavailable'; detail: string }

export interface SandboxPolicy {
  /** Paths the agent may not write. Core, build config, package scripts. */
  readonly denyWrite: readonly string[]
  /** Hosts the agent may reach. Every entry is an exfiltration path. */
  readonly allowedHosts: readonly string[]
  /**
   * Paths the agent may not read: the home directory, the machine-wide
   * keychains, and four binaries. Read only — the binaries still execute.
   */
  readonly denyRead: readonly string[]
}

/** A Surface as discovered on disk, before anything tries to load it. */
export interface SurfaceDescriptor {
  readonly id: string
  readonly name: string
  readonly modulePath: string
}

export type MessageRole = 'user' | 'agent'

export interface Message {
  readonly id: string
  readonly role: MessageRole
  readonly text: string
}

/**
 * The conversation varnick continues when it launches.
 *
 * One name, fixed, because varnick runs one Session. The mirror can hold
 * several files — the `#/states` cards write under their own ids, and an id
 * that has since changed leaves its transcript behind — but none of them is a
 * candidate: resume asks the store for the Session it is about to run and never
 * searches. Picking "the most recently written" would be inventing a way to
 * choose between conversations, and there is no term for a set of Sessions in
 * CONTEXT.md because the product has no such thing. When it grows one, the
 * selection is that feature's decision to make, not a rule left behind by this
 * one.
 *
 * The literal lives here rather than in the machine's default so that the id
 * the app resumes and the id the app runs cannot drift into two strings.
 */
export const LIVE_SESSION_ID = 'session-1'

/**
 * Read one region out of a parallel machine's state value.
 *
 * A parallel state value is a record of region name to value, and the value may
 * itself be a nested record. Returns a dotted path either way.
 */
export function regionOf(value: unknown, region: string): string {
  const raw = (value as Record<string, unknown> | undefined)?.[region]
  if (typeof raw === 'string') return raw
  if (raw && typeof raw === 'object') {
    const key = Object.keys(raw)[0]
    if (key === undefined) return ''
    const tail = (raw as Record<string, unknown>)[key]
    return typeof tail === 'string' ? `${key}.${tail}` : key
  }
  return ''
}

/** The predicate the START guard uses. Exported so the UI can read the same
 *  rule rather than binding to `can()`, which a fallback transition makes
 *  permanently true. */
export function canStartAgent(input: {
  credential: string
  sandbox: string
}): boolean {
  return input.credential === 'present' && input.sandbox === 'available'
}

export function refusalFor(input: {
  credential: string
  sandbox: string
}): StartRefusal {
  if (input.credential === 'rejected')
    return { kind: 'credential-rejected', detail: 'The stored credential was rejected.' }
  if (input.credential !== 'present') return { kind: 'no-credential' }
  return { kind: 'sandbox-unavailable', detail: 'sandbox-runtime could not be established.' }
}

/**
 * A draft is addressing the command menu while some command name still starts
 * with what has been typed.
 *
 * The first version closed the menu at the first space, which was right when
 * every command was one word and wrong the moment `/model sonnet-5` existed —
 * you could never filter past `/model `. Asking whether anything still matches
 * handles both: `/model son` keeps the menu, `/model sonnet-5 ` closes it
 * because the trailing space matches no name, and `/clear everything` closes it
 * for the same reason.
 */
export function isCommandDraft(draft: string, names: readonly string[]): boolean {
  if (!draft.startsWith('/')) return false
  const typed = draft.toLowerCase()
  return names.some((n) => n.toLowerCase().startsWith(typed))
}

/**
 * The command a draft invokes, if any.
 *
 * Sending is how a command runs: `/clear` typed and sent runs the command
 * rather than posting the word. Anything that does not name a known command is
 * an ordinary message, including a half-typed `/cl`.
 *
 * Names may contain spaces — `/effort xhigh` is one command, not a command and
 * an argument — so the longest matching name wins. Matching the first word
 * would resolve `/effort xhigh` to a bare `/effort` that means something else.
 */
export function invokedCommand(draft: string, names: readonly string[]): string | null {
  const text = draft.trim()
  let best: string | null = null
  for (const name of names) {
    if (text !== name && !text.startsWith(`${name} `)) continue
    if (best === null || name.length > best.length) best = name
  }
  return best
}

/** Effort levels the Agent SDK accepts, cheapest first. */
export const EFFORTS = ['low', 'medium', 'high', 'xhigh', 'max'] as const
export type Effort = (typeof EFFORTS)[number]

/**
 * Models this session can run on.
 *
 * Real ids, because a picker offering something the API would reject is the
 * same class of lie as a status line reporting on a timer.
 */
export const MODELS = [
  { id: 'claude-opus-5', label: 'opus-5' },
  { id: 'claude-sonnet-5', label: 'sonnet-5' },
  { id: 'claude-haiku-4-5', label: 'haiku-4.5' },
] as const
export type ModelId = (typeof MODELS)[number]['id']

/** Context window per model, in tokens. */
export const CONTEXT_WINDOW: Record<ModelId, number> = {
  'claude-opus-5': 1_000_000,
  'claude-sonnet-5': 1_000_000,
  'claude-haiku-4-5': 200_000,
}

/** `12.4k/1M (1%)` — the shape Claude Code uses. */
export function formatContext(used: number, total: number): string {
  const short = (n: number) =>
    n >= 1_000_000
      ? `${+(n / 1_000_000).toFixed(n % 1_000_000 === 0 ? 0 : 1)}M`
      : n >= 1_000
        ? `${+(n / 1_000).toFixed(n % 1_000 === 0 ? 0 : 1)}k`
        : String(n)
  const pct = total > 0 ? Math.round((used / total) * 100) : 0
  return `${short(used)}/${short(total)} (${pct}%)`
}

/**
 * Subscription usage across the plan's rolling windows.
 *
 * `source` is part of the shape so a reading always carries where it came from.
 * The seeded-data marker is what tells a viewer the build is not measuring
 * anything; this field is what lets a single value say so even if it outlives
 * the marker.
 */
export interface SubscriptionUsage {
  fiveHourPct: number
  weeklyPct: number
  source: 'live' | 'seeded'
}

/** The query a command draft is filtering by — everything typed so far. */
export function commandQuery(draft: string): string {
  return draft.startsWith('/') ? draft : ''
}

/** Deterministic id source. `Math.random()` and a live clock make the states
 *  page impossible to compare between runs. */
export function makeIdFactory(prefix: string, start = 1) {
  let n = start
  return () => `${prefix}-${n++}`
}
