import { fromPromise } from 'xstate'
import { readCredential as readCredentialFromHost } from '@varnick/harness/credentials'
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
 * Most of them do not exist yet. Each of those throws with the same shape of
 * message, so switching to live mode fails loudly and immediately at the actor
 * that is missing, rather than appearing to work — which is what a silent stub
 * does, and what a missing `provide()` entry did once already in this project.
 *
 * As the Harness package is written, these are replaced one at a time and
 * removed from LIVE_NOT_IMPLEMENTED. That list is what the seeded-data marker
 * *names* — it is the honest answer to "what does this build actually do".
 *
 * It is not what decides whether the marker shows. That is `mode`, and
 * deliberately: in seeded mode the warning is true whatever the list says, and
 * a list-driven marker would go quiet on the last wiring while the surface was
 * still rendering seeded numbers. The list shrinks; the marker disappears when
 * a run stops being seeded.
 */

/**
 * The Session mirror, made once and kept.
 *
 * Built lazily rather than at module load: `defaultSessionRoot()` needs a host
 * process, and constructing it eagerly would make importing this module fail
 * everywhere instead of failing at the one actor that needs a filesystem.
 *
 * The Secrets Store is opened first and handed to the mirror as `secretValues`,
 * which is what turns "no secret reaches the transcript" from a pattern match
 * into an exact-value match. Both halves are host-side by construction — the
 * mirror needs a filesystem and the store needs `/usr/bin/security` — so they
 * are built together, in the same process, and the store is reached through a
 * dynamic import with a hidden specifier for the same reason the sandbox is.
 *
 * `secretValues` is a function, not a snapshot, and `refreshSecrets` re-reads
 * the keychain before every save. That is what makes "no restart" true from the
 * mirror's side as well as the store's: `bun run secret add` runs in a different
 * process, so a running varnick would otherwise redact against the secrets it
 * knew at launch and write the new one into the transcript verbatim. A refresh
 * that fails is swallowed — the previous snapshot is still every secret the last
 * successful read knew about, and redacting against it beats refusing to save.
 *
 * A keychain that refuses at open makes this reject, and the promise is dropped
 * so a `RETRY_SAVE` genuinely retries rather than replaying a cached failure.
 * That one is deliberate the other way: a mirror that never learned any secret
 * values would write a transcript it cannot promise is clean, and
 * `persistence.saveFailed` says so.
 */
interface Mirror {
  store: SessionStore
  refreshSecrets: () => Promise<void>
}

let mirror: Promise<Mirror> | null = null
function sessionMirror(): Promise<Mirror> {
  mirror ??= (async (): Promise<Mirror> => {
    const specifier = '@varnick/harness/secrets'
    type HarnessSecrets = typeof import('@varnick/harness/secrets')
    const secretsModule = (await import(/* @vite-ignore */ specifier)) as HarnessSecrets
    const secrets = await secretsModule.openSecretsStore({
      keychain: secretsModule.securityKeychain(),
    })
    return {
      store: createSessionStore({
        root: defaultSessionRoot(),
        secretValues: () => secrets.secretValues(),
      }),
      refreshSecrets: () => secrets.reload().catch(() => undefined),
    }
  })().catch((error: unknown) => {
    mirror = null
    throw error
  })
  return mirror
}

const notImplemented = (name: string, what: string) => (): never => {
  throw new Error(
    `${name} has no live implementation yet — ${what}. Run without ?actors=live to use seeded data.`,
  )
}

export const LIVE_NOT_IMPLEMENTED = [
  'spawnAgent',
  'readSubscriptionUsage',
  'runTurn',
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
      The source question is answered — the plan's own 5-hour and weekly
      windows, through the Agent SDK's `get_usage` control request, parsed by
      packages/harness/src/subscription.ts. What is missing is a session to ask
      it on: that request rides a live Agent SDK session, and opening one here
      would put a Claude Code process on the host outside the Sandbox. Ticket 03
      owns the confined session; this is wired to it there.
    */
    readSubscriptionUsage: fromPromise<SubscriptionUsage, Record<string, never>>(
      notImplemented(
        'readSubscriptionUsage',
        'the read needs a Sandboxed agent session to ask, and none is spawned yet',
      ),
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
    >(async ({ input }) => {
      const { store, refreshSecrets } = await sessionMirror()
      await refreshSecrets()
      return store.persist(input)
    }),

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
