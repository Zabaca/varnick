import { fromPromise } from 'xstate'
import { readCredential as readCredentialFromHost } from '@varnick/harness/credentials'
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

const notImplemented = (name: string, what: string) => (): never => {
  throw new Error(
    `${name} has no live implementation yet — ${what}. Run without ?actors=live to use seeded data.`,
  )
}

export const LIVE_NOT_IMPLEMENTED = [
  'checkSandbox',
  'spawnAgent',
  'readSubscriptionUsage',
  'runTurn',
  'persistSession',
  'compactSession',
  'loadSurface',
] as const

export function liveActors() {
  return {
    checkSandbox: fromPromise<{ ok: true }, { policy: SandboxPolicy }>(
      notImplemented('checkSandbox', 'nothing establishes a sandbox-runtime policy'),
    ),

    // Real. The Tauri host reads the credential and answers with which store
    // replied; the value never crosses the IPC boundary, so Core has no field
    // that could hold it. No host — a browser tab at the dev server — is a
    // failed read with a reason, not an unhandled rejection.
    readCredential: fromPromise<{ source: 'keychain' | 'env' }, Record<string, never>>(() =>
      readCredentialFromHost(),
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

    persistSession: fromPromise<
      { ok: true },
      { sessionId: string; messages: readonly Message[] }
    >(notImplemented('persistSession', 'no host-side session store exists')),

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
