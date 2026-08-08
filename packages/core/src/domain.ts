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
  /** Binaries denied by making them unreadable — srt has no exec allowlist. */
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
 * A draft is addressing the command menu when it opens with `/` and has not yet
 * reached a space. `/re` is still choosing; `/review src` is an argument to a
 * command already chosen, and the menu is no longer what the keyboard means.
 */
export function isCommandDraft(draft: string): boolean {
  return draft.startsWith('/') && !draft.includes(' ')
}

/** The query a command draft is filtering by — the text after the slash. */
export function commandQuery(draft: string): string {
  return isCommandDraft(draft) ? draft.slice(1) : ''
}

/** Deterministic id source. `Math.random()` and a live clock make the states
 *  page impossible to compare between runs. */
export function makeIdFactory(prefix: string, start = 1) {
  let n = start
  return () => `${prefix}-${n++}`
}
