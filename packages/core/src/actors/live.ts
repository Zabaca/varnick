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
  'readCredential',
  'spawnAgent',
  'readSubscriptionUsage',
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
