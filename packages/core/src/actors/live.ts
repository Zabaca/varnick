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
  'spawnAgent',
  'runTurn',
  'persistSession',
  'compactSession',
  'loadSurface',
] as const

export function liveActors() {
  return {
    /*
      Establishes the real srt policy scoped to the clone, or fails.

      Imported at call time and hidden from the bundler on purpose: the Harness
      talks to the kernel through node built-ins, and pulling that graph into
      the browser build would ship the sandbox implementation into the webview
      where it can never run. Loaded from the host process this resolves; loaded
      from a plain browser it throws, which is the honest answer — a renderer
      with no host behind it has no sandbox, and `sandbox.unavailable` carrying
      that reason is exactly right. There is no third branch here, by design:
      nothing in this actor can return ok without srt having said so.
    */
    checkSandbox: fromPromise<{ ok: true }, { policy: SandboxPolicy }>(async () => {
      const specifier = '@varnick/harness/sandbox'
      type HarnessSandbox = typeof import('@varnick/harness/sandbox')
      const harness = (await import(/* @vite-ignore */ specifier)) as HarnessSandbox
      await harness.establishSandbox()
      return { ok: true }
    }),

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
