import { fromPromise } from 'xstate'
import { callHarness } from '@varnick/harness/bridge'
import { readCredential as readCredentialFromHost } from '@varnick/harness/credentials'
import type {
  Effort,
  Message,
  ModelId,
  SandboxPolicy,
  SubscriptionUsage,
  SurfaceDescriptor,
} from '../domain.ts'
import type { SessionInput } from '../machines/session.ts'

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
 * How a live actor reaches the Harness.
 *
 * One seam, `callHarness`, and nothing below it. This module is bundled into the
 * webview, so it imports no Node: the kernel, the keychain and the filesystem
 * are all behind the bridge, in the host. A call with no host reaches the
 * actor's own failure state carrying the reason — see @varnick/harness/bridge
 * for where that answer comes from and why a missing host is a value rather
 * than an exception.
 */

const notImplemented = (name: string, what: string) => (): never => {
  throw new Error(
    `${name} has no live implementation yet — ${what}. Run without ?actors=live to use seeded data.`,
  )
}

export const LIVE_NOT_IMPLEMENTED = [
  'readSubscriptionUsage',
  'runTurn',
  'compactSession',
  'loadSurface',
] as const

export function liveActors() {
  return {
    /*
      Establishes the real srt policy scoped to the clone, or fails.

      The Harness runtime does the work; this side only asks. There is no third
      branch here, by design: nothing in this actor can return ok without srt
      having said so, and a renderer with no host behind it reaches
      `sandbox.unavailable` carrying that reason rather than pretending.
    */
    checkSandbox: fromPromise<{ ok: true }, { policy: SandboxPolicy }>(() =>
      callHarness({ kind: 'check-sandbox' }),
    ),

    // Real. The Tauri host reads the credential and answers with which store
    // replied; the value never crosses the IPC boundary, so Core has no field
    // that could hold it. No host — a browser tab at the dev server — is a
    // failed read with a reason, not an unhandled rejection.
    readCredential: fromPromise<{ source: 'keychain' | 'env' }, Record<string, never>>(() =>
      readCredentialFromHost(),
    ),

    /*
      Real. The host asks the Harness runtime how to run the agent under the
      Sandbox it established, then spawns that with the credential in the
      child's environment — see src-tauri/src/agent.rs and ADR-0008.

      The refusal path is the important one: a runtime with no Sandbox
      established refuses to answer the wrapping, and the host returns that
      rather than spawning. So `agent.starting` reaches `agent.crashed` carrying
      the reason, and there is no state in which a process starts unconfined.
    */
    spawnAgent: fromPromise<{ pid: number }, { policy: SandboxPolicy }>(() =>
      callHarness({ kind: 'spawn-agent' }),
    ),

    /*
      The source question is answered — the plan's own 5-hour and weekly
      windows, through the Agent SDK's `get_usage` control request, parsed by
      packages/harness/src/subscription.ts. What is missing is a way to ask on
      the session that now exists: the control request rides the Agent SDK
      session held open inside the Sandbox, and nothing yet carries a request to
      it. Ticket 09 owns that wire; opening a second session here would put a
      Claude Code process on the host outside the Sandbox, which ADR-0003's last
      consequence forbids.
    */
    readSubscriptionUsage: fromPromise<SubscriptionUsage, Record<string, never>>(
      notImplemented(
        'readSubscriptionUsage',
        'nothing carries a control request to the confined session yet',
      ),
    ),

    runTurn: fromPromise<
      { text: string; tokensUsed: number },
      { sessionId: string; prompt: string; model: ModelId; effort: Effort }
    >(notImplemented('runTurn', 'the Claude Agent SDK is not wired in')),

    // The host-side mirror, alongside the Agent SDK's own persistence. One
    // JSON Lines file per Session under the app-data directory, which a
    // developer can read and back up with varnick not running. The store itself
    // lives in the Harness runtime, which is the only process with a filesystem.
    persistSession: fromPromise<
      { ok: true },
      { sessionId: string; messages: readonly Message[] }
    >(({ input }) =>
      callHarness({
        kind: 'persist-session',
        sessionId: input.sessionId,
        messages: input.messages,
      }),
    ),

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

/**
 * A conversation, as a relaunch gets it back.
 *
 * `input` is the same `SessionInput` the states page uses to park a Session
 * mid-flight — the entry point already existed, and this fills it from disk
 * instead of from a literal.
 */
export interface RestoredSession {
  readonly input: SessionInput
  /**
   * Whether the mirror kept something out of this transcript.
   *
   * The surface owes the developer this. The mirror is redacted on the write
   * path, so a restored message can read `[redacted]` where a secret value was,
   * and a developer looking at their own words has to be able to tell that they
   * are reading the record rather than what they typed.
   */
  readonly redacted: boolean
}

/**
 * Read the Session back from the host-side mirror.
 *
 * **The mirror, not the Agent SDK's own store.** The two answer different
 * questions and both keep their job: the SDK's copy is what the *agent* resumes
 * from — its context, its continuity — and the mirror is what varnick
 * *displays*, because it is the one that survives a build the agent just broke.
 * That is the case resume exists for. See
 * docs/adr/0009-resume-reads-the-mirror.md.
 *
 * Not an xstate actor, because it is not invoked by a machine: the Harness
 * spawns the Session from an input it holds in context, so the transcript has
 * to be in hand before the machine is created. Start-up owns this, the same way
 * it owns reading the credential — see pages/DesignedPage.tsx.
 *
 * Rejects with a {@link HarnessUnavailable} carrying the reason, like every
 * other call across the bridge. A failed read must never be flattened into an
 * empty transcript: that is what a first run looks like, and a Session that
 * started empty over a mirror that is not empty would replace it on the next
 * save — the loss the mirror exists to prevent.
 */
export async function restoreSession(sessionId: string): Promise<RestoredSession> {
  const { messages, redacted } = await callHarness({ kind: 'read-session', sessionId })
  return { input: { sessionId, messages: [...messages] }, redacted }
}

/**
 * Wait for the agent process to end, and answer with why.
 *
 * Not an actor, because the machine has none for it: an exit is something the
 * world did, so it arrives as an event (`AGENT_EXIT`) rather than as a promise a
 * state is waiting on. Whoever owns the machine calls this on each entry to
 * `agent.running` and sends the event when it settles — see hooks.ts.
 *
 * It waits rather than polls. The host holds the exit as state and answers
 * immediately if the process has already gone, which matters more than it
 * sounds: a process that dies on startup is the common failure, and the machine
 * reaches `running` before anyone can ask.
 *
 * A reason is always a real one — how the process ended, observed by the host
 * that spawned it. Nothing the agent printed is in it.
 */
export async function liveAgentExit(): Promise<string> {
  const { reason } = await callHarness({ kind: 'await-agent-exit' })
  return reason
}

/**
 * Stop the agent's whole process tree.
 *
 * `STOP` is a state the machine reaches on its own; without this the process
 * behind it would keep running, which would make `agent.down` a claim about the
 * UI rather than about the machine's world.
 */
export async function liveStopAgent(): Promise<void> {
  await callHarness({ kind: 'stop-agent' })
}
