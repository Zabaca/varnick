import { setup, assign, fromPromise, type ActorRefFrom } from 'xstate'
import { canStartAgent, hasPlanUsage, refusalFor, regionOf, LIVE_SESSION_ID } from '../domain.ts'
import type {
  CredentialKind,
  CredentialReading,
  SandboxPolicy,
  StartRefusal,
  SubscriptionUsage,
  SurfaceDescriptor,
} from '../domain.ts'
import { surfaceMachine } from './surface.ts'
import { sessionMachine, type SessionInput } from './session.ts'

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
  'credential.reading',
  'credential.present',
  'credential.rejected',
  'subscription.unread',
  'subscription.reading',
  'subscription.read',
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
  /**
   * What the credential turned out to be, once one has been read.
   *
   * `null` until a read succeeds, and back to `null` when one fails: a kind
   * left standing over a credential that is gone would be a decision made about
   * something that is no longer there. It is a fact on `credential.present`
   * rather than a state of its own — ADR-0011 adds two facts to a reading, and
   * a state per kind would double the region for a distinction no transition
   * depends on.
   *
   * Nothing here is or could be the value; see packages/harness/src/credentials.ts.
   */
  credentialKind: CredentialKind | null
  sandboxState: SandboxState
  refusal: StartRefusal | null
  sandboxError: string | null
  agentError: string | null
  credentialError: string | null
  surfaces: ActorRefFrom<typeof surfaceMachine>[]
  session: ActorRefFrom<typeof sessionMachine> | null
  /**
   * Plan usage across the rolling windows. Null until something reads it, and
   * carrying its own provenance so the view can refuse to present an unwired
   * number as a measurement.
   */
  subscription: SubscriptionUsage | null
  /**
   * What the Session is spawned with.
   *
   * The states page parks a Session in a named turn state, and the only way in
   * is through the parent that owns the spawn. Held in context rather than read
   * off the event so the entry point works on a machine created cold.
   *
   * A relaunch comes in through the same door with the transcript read off
   * disk, which is why resume needed no new state: a Session restored from the
   * mirror is `turn.idle` with messages, and that is a card the states page
   * already renders. See docs/adr/0009-resume-reads-the-mirror.md.
   */
  readonly sessionInput: SessionInput
  readonly enterCredential: string | null
  readonly enterSandbox: string | null
  readonly enterAgent: string | null
  readonly enterSubscription: string | null
}

export interface HarnessInput {
  policy: SandboxPolicy
  credentialKind?: CredentialKind | null
  enterCredential?: string | null
  enterSandbox?: string | null
  enterAgent?: string | null
  enterSubscription?: string | null
  sessionInput?: SessionInput
  refusal?: StartRefusal | null
  agentError?: string | null
  sandboxError?: string | null
  credentialError?: string | null
  subscription?: SubscriptionUsage | null
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
 *                  output { source: 'keychain' | 'env',
 *                           kind:   'api-key' | 'subscription' }
 *                         Two facts about the reading and no third. The value
 *                         is not representable on this side — ADR-0008, and
 *                         packages/harness/src/credentials.ts.
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
    readCredential: fromPromise<CredentialReading, Record<string, never>>(
      async () => ({ source: 'keychain' as const, kind: 'api-key' as const }),
    ),
    spawnAgent: fromPromise<{ pid: number }, { policy: SandboxPolicy }>(async () => ({
      pid: 0,
    })),
    /*
      Real-service contract for readSubscriptionUsage:
        input  {}
        output SubscriptionUsage — percentages plus where they came from. Live,
               this is the plan's own 5-hour and weekly windows, read through
               the Agent SDK's `get_usage` control request.
        error  thrown Error, including when the session has no plan to have
               windows. `unread` keeps whatever was last known rather than
               clearing it — a failed read must not blank a good reading, and
               must never substitute a default.

      Like every actor here, the default is a stub the machine never relies on;
      the mode chosen in actors/index.ts supplies the real one.
    */
    readSubscriptionUsage: fromPromise<SubscriptionUsage, Record<string, never>>(
      async () => ({ fiveHourPct: 0, weeklyPct: 0, source: 'seeded' as const }),
    ),
  },
  guards: {
    canStart: ({ context }) =>
      canStartAgent({ credential: context.credentialState, sandbox: context.sandboxState }),
    /**
     * There is a plan for plan usage to be about.
     *
     * Reads the same context fact the strip reads, through the same predicate —
     * the region cannot decide the read is pointless while the view still
     * renders a place for its answer. See `hasPlanUsage` in ../domain.ts.
     */
    underSubscription: ({ context }) => hasPlanUsage(context.credentialKind),
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
    credentialKind: input.credentialKind ?? null,
    sandboxState: (input.enterSandbox as SandboxState | undefined) ?? 'unchecked',
    refusal: input.refusal ?? null,
    sandboxError: input.sandboxError ?? null,
    agentError: input.agentError ?? null,
    credentialError: input.credentialError ?? null,
    surfaces: [],
    session: null,
    subscription: input.subscription ?? null,
    sessionInput: input.sessionInput ?? { sessionId: LIVE_SESSION_ID },
    enterCredential: input.enterCredential ?? null,
    enterSandbox: input.enterSandbox ?? null,
    enterAgent: input.enterAgent ?? null,
    enterSubscription: input.enterSubscription ?? null,
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
            { target: 'reading', guard: ({ context }) => context.enterCredential === 'reading' },
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
            onDone: {
              target: 'present',
              actions: assign({
                credentialError: null,
                // The reading's second fact. Taken off the event rather than
                // asked for again, because the kind belongs to the credential
                // that was resolved and a second read could resolve another.
                credentialKind: ({ event }) => event.output.kind,
              }),
            },
            // Keep the reason. Without it a failed read is indistinguishable
            // from never having been attempted, and the view has nothing to say.
            onError: {
              target: 'absent',
              actions: assign({
                credentialError: ({ event }) =>
                  event.error instanceof Error ? event.error.message : String(event.error),
                // And forget the kind. A kind left standing over a credential
                // that could not be read is a fact about something that is not
                // there, and everything downstream of it would be decided on it.
                credentialKind: null,
              }),
            },
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
      initial: 'routing',
      states: {
        routing: {
          always: [
            { target: 'read', guard: ({ context }) => context.enterSubscription === 'read' },
            { target: 'reading', guard: ({ context }) => context.enterSubscription === 'reading' },
            { target: 'unread' },
          ],
        },
        /*
          READ_SUBSCRIPTION is handled inside the region, never at the machine
          root. A root-level transition with a target is external: it exits and
          re-enters every parallel region, which tore down the Session actor —
          and with it the whole conversation — on first load.

          Guarded, and with no fallback: under an API key there is no plan, so
          the read is refused and the region stays here. `unread` is the whole
          of what "there was nothing to read" needs to say — a fourth state
          meaning "not applicable" would name a fact that is already in context
          and is not a state (ADR-0011, and CONTEXT.md on naming).

          Unlike START, this refusal is silent on purpose. A refused start is a
          thing the user asked for and must be told about; a plan-usage read is
          asked for by the page on the user's behalf, and there is nothing to
          report beyond the strip not being there.
        */
        unread: { on: { READ_SUBSCRIPTION: { target: 'reading', guard: 'underSubscription' } } },
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
        // Guarded here too, and not only for symmetry: the credential can be
        // re-read, and one that comes back an API key leaves a `read` region
        // holding figures from a plan that is no longer in play. Refusing the
        // re-read is what stops it being replaced by a failed one — the last
        // measurement stands, and the strip stops being rendered because the
        // strip asks `hasPlanUsage`, not the region.
        read: { on: { READ_SUBSCRIPTION: { target: 'reading', guard: 'underSubscription' } } },
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
                input: context.sessionInput,
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
