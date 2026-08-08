import { fromPromise } from 'xstate'
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
 * Most of them do not exist yet. Each of those throws with the same shape of
 * message, so switching to live mode fails loudly and immediately at the actor
 * that is missing, rather than appearing to work — which is what a silent stub
 * does, and what a missing `provide()` entry did once already in this project.
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

/**
 * The Harness half of a read, loaded at the moment it is used.
 *
 * Core is a browser bundle; the Harness is the host-side runtime that may open
 * a Claude Code session and touch the filesystem. Importing it statically would
 * pull `child_process`, `net`, and two dozen other Node builtins into the
 * bundle, where they resolve to stubs — a megabyte of code that cannot run.
 * The `@vite-ignore` keeps the specifier out of the build entirely, so on a
 * host that has no bridge to the Harness this import simply fails, and a
 * failed import is a failed read like any other.
 *
 * The same discipline as ADR-0004, applied to the other boundary: Core never
 * statically imports the half that cannot run beside it.
 */
type HarnessSubscription = typeof import('@varnick/harness/subscription')

const HARNESS_SUBSCRIPTION = '@varnick/harness/subscription'

async function harnessSubscription(): Promise<HarnessSubscription> {
  return (await import(/* @vite-ignore */ HARNESS_SUBSCRIPTION)) as HarnessSubscription
}

export const LIVE_NOT_IMPLEMENTED = [
  'checkSandbox',
  'readCredential',
  'spawnAgent',
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

    readCredential: fromPromise<{ source: 'keychain' | 'env' }, Record<string, never>>(
      notImplemented('readCredential', 'Tauri does not read the keychain yet'),
    ),

    spawnAgent: fromPromise<{ pid: number }, { policy: SandboxPolicy }>(
      notImplemented('spawnAgent', 'no agent process is spawned under srt'),
    ),

    /*
      Real: the plan's own 5-hour and weekly windows, by way of the Agent SDK's
      `get_usage` control request. Nothing here is derived from traffic this
      application has seen — see packages/harness/src/subscription.ts for why
      that distinction is the whole ticket.

      A read that fails, for any reason including no Harness on this host,
      throws. The `subscription` region sends that back to `unread` without
      touching context, which is how "leave whatever was last known" is spelled.
    */
    readSubscriptionUsage: fromPromise<SubscriptionUsage, Record<string, never>>(async () =>
      (await harnessSubscription()).readSubscriptionUsage(),
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
