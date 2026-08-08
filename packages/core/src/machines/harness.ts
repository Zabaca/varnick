import { setup, assign, fromPromise, type ActorRefFrom } from 'xstate'
import { canStartAgent, refusalFor, regionOf } from '../domain.ts'
import type {
  SandboxPolicy,
  StartRefusal,
  SubscriptionUsage,
  SurfaceDescriptor,
} from '../domain.ts'
import { surfaceMachine } from './surface.ts'
import { sessionMachine } from './session.ts'

/**
 * The Harness: parent machine, owning the facts that decide whether an agent
 * may run at all, plus one child per Surface and one Session.
 *
 * Three parallel regions because they are genuinely independent: a credential
 * can be rejected while the sandbox is fine, the sandbox can be unavailable
 * while a credential is present, and the agent process can crash without
 * changing either. One status enum here would make every combination a new
 * enum member and every transition a lie.
 */

export const HARNESS_STATE_PATHS = [
  'credential.absent',
  'credential.present',
  'credential.rejected',
  'sandbox.unchecked',
  'sandbox.checking',
  'sandbox.available',
  'sandbox.unavailable',
  'agent.down',
  'agent.startRefused',
  'agent.starting',
  'agent.running',
  'agent.crashed',
] as const
export type HarnessStatePath = (typeof HARNESS_STATE_PATHS)[number]

export type CredentialState = 'absent' | 'reading' | 'present' | 'rejected'
export type SandboxState = 'unchecked' | 'checking' | 'available' | 'unavailable'

export interface HarnessContext {
  policy: SandboxPolicy
  /**
   * Each region publishes its own state here on entry.
   *
   * A guard in XState v5 receives only `{ context, event }` — it cannot read
   * a sibling region's value. Rather than reaching sideways, each region states
   * its fact in context and the start guard reads that. The UI reads the same
   * two fields, so the affordance and the rule cannot drift.
   */
  credentialState: CredentialState
  sandboxState: SandboxState
  refusal: StartRefusal | null
  sandboxError: string | null
  agentError: string | null
  surfaces: ActorRefFrom<typeof surfaceMachine>[]
  session: ActorRefFrom<typeof sessionMachine> | null
  /**
   * Plan usage across the rolling windows. Null until something reads it, and
   * carrying its own provenance so the view can refuse to present an unwired
   * number as a measurement.
   */
  subscription: SubscriptionUsage | null
  readonly enterCredential: string | null
  readonly enterSandbox: string | null
  readonly enterAgent: string | null
}

export interface HarnessInput {
  policy: SandboxPolicy
  enterCredential?: string | null
  enterSandbox?: string | null
  enterAgent?: string | null
  refusal?: StartRefusal | null
  agentError?: string | null
  sandboxError?: string | null
}

export type HarnessEvent =
  | { type: 'CHECK_SANDBOX' }
  | { type: 'READ_CREDENTIAL' }
  | { type: 'CREDENTIAL_REJECTED'; detail: string }
  | { type: 'START' }
  | { type: 'STOP' }
  | { type: 'RESTART' }
  | { type: 'AGENT_EXIT'; detail: string }
  | { type: 'DISCOVER_SURFACES'; descriptors: SurfaceDescriptor[] }
  | { type: 'UNLOAD_SURFACE'; id: string }
  | { type: 'READ_SUBSCRIPTION' }

/**
 * Real-service contracts:
 *   checkSandbox   input  { policy }
 *                  output { ok: true }
 *                  error  thrown Error — srt could not be established. The run
 *                         must fail here rather than proceeding unconfined.
 *   readCredential input  {}
 *                  output { source: 'keychain' | 'env' }
 *                  error  thrown Error — no credential available
 *   spawnAgent     input  { policy }
 *                  output { pid: number }
 *                  error  thrown Error — process failed to start
 */
/**
 * The START transition, declared once and used by both `down` and
 * `startRefused` so the two cannot drift.
 *
 * The second entry is an unguarded fallback, so a refusal explains itself
 * instead of swallowing the click. The consequence: `can({type:'START'})` is
 * permanently true, and nothing may bind a `disabled` attribute to it —
 * readiness comes from `canStartAgent()`.
 */
const startTransition = [
  { target: 'starting', guard: 'canStart' },
  { target: 'startRefused', actions: 'recordRefusal' },
] as const

export const harnessMachine = setup({
  types: {
    context: {} as HarnessContext,
    events: {} as HarnessEvent,
    input: {} as HarnessInput,
  },
  actors: {
    surface: surfaceMachine,
    session: sessionMachine,
    checkSandbox: fromPromise<{ ok: true }, { policy: SandboxPolicy }>(async () => ({
      ok: true,
    })),
    readCredential: fromPromise<{ source: 'keychain' | 'env' }, Record<string, never>>(
      async () => ({ source: 'keychain' as const }),
    ),
    spawnAgent: fromPromise<{ pid: number }, { policy: SandboxPolicy }>(async () => ({
      pid: 0,
    })),
    /*
      Real-service contract for readSubscriptionUsage:
        input  {}
        output SubscriptionUsage — percentages plus where they came from
        error  thrown Error; the view shows nothing rather than a stale number

      No implementation reads real plan usage yet. Until one does, the seeded
      actor returns source: 'unwired' and the view labels it, because a
      percentage presented as a measurement is the failure this project keeps
      having to undo.
    */
    readSubscriptionUsage: fromPromise<SubscriptionUsage, Record<string, never>>(
      async () => ({ fiveHourPct: 0, weeklyPct: 0, source: 'unwired' as const }),
    ),
  },
  guards: {
    canStart: ({ context }) =>
      canStartAgent({ credential: context.credentialState, sandbox: context.sandboxState }),
  },
  actions: {
    recordRefusal: assign({
      refusal: ({ context }) =>
        refusalFor({ credential: context.credentialState, sandbox: context.sandboxState }),
    }),
  },
  delays: {
    refusalTimeout: 6000,
  },
}).createMachine({
  id: 'harness',
  type: 'parallel',
  context: ({ input }) => ({
    policy: input.policy,
    credentialState: (input.enterCredential as CredentialState | undefined) ?? 'absent',
    sandboxState: (input.enterSandbox as SandboxState | undefined) ?? 'unchecked',
    refusal: input.refusal ?? null,
    sandboxError: input.sandboxError ?? null,
    agentError: input.agentError ?? null,
    surfaces: [],
    session: null,
    subscription: null,
    enterCredential: input.enterCredential ?? null,
    enterSandbox: input.enterSandbox ?? null,
    enterAgent: input.enterAgent ?? null,
  }),
  on: {
    // Surfaces are discovered, never registered — adding one must not require
    // editing Core, which the agent cannot write anyway (ADR-0002).
    DISCOVER_SURFACES: {
      // Idempotent by construction. Discovery re-runs whenever the Surfaces
      // directory changes, so appending unconditionally would spawn a second
      // actor for a Surface that is already loaded — and both would answer to
      // the same id. Caught by driving the bare page: React reported duplicate
      // keys, which was the symptom of two live actors per Surface.
      actions: assign({
        surfaces: ({ context, event, spawn }) => {
          const known = new Set(context.surfaces.map((ref) => ref.getSnapshot().context.descriptor.id))
          const added = event.descriptors
            .filter((descriptor) => !known.has(descriptor.id))
            .map((descriptor) =>
              spawn('surface', {
                id: `surface-${descriptor.id}`,
                syncSnapshot: true,
                input: { descriptor },
              }),
            )
          return added.length === 0 ? context.surfaces : [...context.surfaces, ...added]
        },
      }),
    },
    UNLOAD_SURFACE: {
      actions: assign({
        surfaces: ({ context, event }) =>
          context.surfaces.filter((ref) => ref.getSnapshot().context.descriptor.id !== event.id),
      }),
    },
  },
  states: {
    credential: {
      initial: 'routing',
      states: {
        routing: {
          always: [
            { target: 'present', guard: ({ context }) => context.enterCredential === 'present' },
            { target: 'rejected', guard: ({ context }) => context.enterCredential === 'rejected' },
            { target: 'absent' },
          ],
        },
        absent: {
          entry: assign({ credentialState: 'absent' as const }),
          on: { READ_CREDENTIAL: 'reading' },
        },
        reading: {
          entry: assign({ credentialState: 'reading' as const }),
          invoke: {
            src: 'readCredential',
            input: () => ({}) as Record<string, never>,
            onDone: 'present',
            onError: 'absent',
          },
        },
        present: {
          entry: assign({ credentialState: 'present' as const }),
          on: {
            CREDENTIAL_REJECTED: 'rejected',
            READ_CREDENTIAL: 'reading',
          },
        },
        rejected: {
          entry: assign({ credentialState: 'rejected' as const }),
          on: { READ_CREDENTIAL: 'reading' },
        },
      },
    },

    sandbox: {
      initial: 'routing',
      states: {
        routing: {
          always: [
            { target: 'available', guard: ({ context }) => context.enterSandbox === 'available' },
            {
              target: 'unavailable',
              guard: ({ context }) => context.enterSandbox === 'unavailable',
            },
            { target: 'checking', guard: ({ context }) => context.enterSandbox === 'checking' },
            { target: 'unchecked' },
          ],
        },
        unchecked: {
          entry: assign({ sandboxState: 'unchecked' as const }),
          on: { CHECK_SANDBOX: 'checking' },
        },
        checking: {
          entry: assign({ sandboxState: 'checking' as const }),
          invoke: {
            src: 'checkSandbox',
            input: ({ context }) => ({ policy: context.policy }),
            onDone: { target: 'available', actions: assign({ sandboxError: null }) },
            onError: {
              target: 'unavailable',
              actions: assign({
                sandboxError: ({ event }) =>
                  event.error instanceof Error ? event.error.message : String(event.error),
              }),
            },
          },
        },
        available: {
          entry: assign({ sandboxState: 'available' as const }),
          on: { CHECK_SANDBOX: 'checking' },
        },
        // No fallback to running unconfined: the only way out is an explicit
        // re-check.
        unavailable: {
          entry: assign({ sandboxState: 'unavailable' as const }),
          on: { CHECK_SANDBOX: 'checking' },
        },
      },
    },

    subscription: {
      initial: 'unread',
      states: {
        // READ_SUBSCRIPTION is handled inside the region, never at the machine
        // root. A root-level transition with a target is external: it exits and
        // re-enters every parallel region, which tore down the Session actor —
        // and with it the whole conversation — on first load.
        unread: { on: { READ_SUBSCRIPTION: 'reading' } },
        reading: {
          invoke: {
            src: 'readSubscriptionUsage',
            input: () => ({}) as Record<string, never>,
            onDone: {
              target: 'read',
              actions: assign({ subscription: ({ event }) => event.output }),
            },
            // A failed read leaves whatever was last known, which may be
            // nothing. It never invents a figure.
            onError: 'unread',
          },
        },
        read: { on: { READ_SUBSCRIPTION: 'reading' } },
      },
    },

    agent: {
      initial: 'routing',
      states: {
        routing: {
          always: [
            { target: 'running', guard: ({ context }) => context.enterAgent === 'running' },
            { target: 'starting', guard: ({ context }) => context.enterAgent === 'starting' },
            { target: 'crashed', guard: ({ context }) => context.enterAgent === 'crashed' },
            {
              target: 'startRefused',
              guard: ({ context }) => context.enterAgent === 'startRefused',
            },
            { target: 'down' },
          ],
        },
        down: { on: { START: startTransition } },
        startRefused: {
          after: { refusalTimeout: 'down' },
          exit: assign({ refusal: null }),
          // START must behave here exactly as it does in `down`. An earlier
          // version sent it to `down` as a way to dismiss the refusal, which
          // swallowed a START that had since become valid: the user fixed the
          // cause, clicked again, and nothing happened. Caught by driving the
          // bare page, not by the headless script — which never pressed START
          // twice.
          on: { START: startTransition },
        },
        starting: {
          invoke: {
            src: 'spawnAgent',
            input: ({ context }) => ({ policy: context.policy }),
            onDone: 'running',
            onError: {
              target: 'crashed',
              actions: assign({
                agentError: ({ event }) =>
                  event.error instanceof Error ? event.error.message : String(event.error),
              }),
            },
          },
        },
        running: {
          // The Session is spawned once and outlives every agent restart. That
          // is what makes "the transcript survives" true rather than aspirational.
          entry: assign({
            session: ({ context, spawn }) =>
              context.session ??
              spawn('session', {
                id: 'session',
                syncSnapshot: true,
                input: { sessionId: 'session-1' },
              }),
            agentError: null,
          }),
          on: {
            STOP: 'down',
            AGENT_EXIT: {
              target: 'crashed',
              actions: assign({ agentError: ({ event }) => event.detail }),
            },
          },
        },
        crashed: {
          on: { RESTART: 'starting', STOP: 'down' },
        },
      },
    },
  },
})
