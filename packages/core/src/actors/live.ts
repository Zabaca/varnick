import { fromPromise } from 'xstate'
import { createSessionStore, defaultSessionRoot, type SessionStore } from '@varnick/harness/session'
import type {
  Effort,
  Message,
  ModelId,
  SandboxPolicy,
  SubscriptionUsage,
  SurfaceDescriptor,
} from '../domain.ts'

/**
 * The real implementations.
 *
 * None of them exist yet. Each one throws with the same shape of message, so
 * switching to live mode fails loudly and immediately at the actor that is
 * missing, rather than appearing to work — which is what a silent stub does,
 * and what a missing `provide()` entry did once already in this project.
 *
 * As the Harness package is written, these are replaced one at a time and
 * removed from LIVE_NOT_IMPLEMENTED. That list is what the seeded-data marker
 * reads, so the UI stops claiming a thing is fake the moment it stops being.
 */

/**
 * The Session mirror, made once and kept.
 *
 * Built lazily rather than at module load: `defaultSessionRoot()` needs a host
 * process, and constructing it eagerly would make importing this module fail
 * everywhere instead of failing at the one actor that needs a filesystem.
 *
 * No `secretValues` yet — there is no Secrets Store to read them from until
 * ticket 10. Until then the mirror redacts by credential shape only, which is
 * the weaker half of the mechanism; wiring the store in here closes it.
 */
let mirror: SessionStore | null = null
function sessionMirror(): SessionStore {
  mirror ??= createSessionStore({ root: defaultSessionRoot() })
  return mirror
}

const notImplemented = (name: string, what: string) => (): never => {
  throw new Error(
    `${name} has no live implementation yet — ${what}. Run without ?actors=live to use seeded data.`,
  )
}

export const LIVE_NOT_IMPLEMENTED = [
  'checkSandbox',
  'readCredential',
  'spawnAgent',
  'readSubscriptionUsage',
  'runTurn',
  'compactSession',
  'loadSurface',
] as const

export function liveActors() {
  return {
    checkSandbox: fromPromise<{ ok: true }, { policy: SandboxPolicy }>(
      notImplemented('checkSandbox', 'nothing establishes a sandbox-runtime policy'),
    ),

    readCredential: fromPromise<{ source: 'keychain' | 'env' }, Record<string, never>>(
      notImplemented('readCredential', 'Tauri does not read the keychain yet'),
    ),

    spawnAgent: fromPromise<{ pid: number }, { policy: SandboxPolicy }>(
      notImplemented('spawnAgent', 'no agent process is spawned under srt'),
    ),

    readSubscriptionUsage: fromPromise<SubscriptionUsage, Record<string, never>>(
      notImplemented('readSubscriptionUsage', 'no source for the 5-hour or weekly windows'),
    ),

    runTurn: fromPromise<
      { text: string; tokensUsed: number },
      { sessionId: string; prompt: string; model: ModelId; effort: Effort }
    >(notImplemented('runTurn', 'the Claude Agent SDK is not wired in')),

    // The host-side mirror, alongside the Agent SDK's own persistence. One
    // JSON Lines file per Session under the app-data directory, which a
    // developer can read and back up with varnick not running.
    persistSession: fromPromise<
      { ok: true },
      { sessionId: string; messages: readonly Message[] }
    >(({ input }) => sessionMirror().persist(input)),

    compactSession: fromPromise<
      { messages: Message[]; tokensUsed: number },
      { sessionId: string; messages: readonly Message[]; model: ModelId }
    >(notImplemented('compactSession', 'no summarisation call is made')),

    loadSurface: fromPromise<{ ok: true }, { modulePath: string }>(
      notImplemented('loadSurface', 'no Userspace module is imported'),
    ),
  }
}

/** Descriptors a live discovery would return. Nothing scans the filesystem yet. */
export const liveSurfaces: SurfaceDescriptor[] = []
