import { setup, assign, fromPromise, type ActorRefFrom } from 'xstate'
import { canStartAgent, refusalFor, regionOf } from '../domain.ts'
import type { SandboxPolicy, StartRefusal, SurfaceDescriptor } from '../domain.ts'
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
    enterCredential: input.enterCredential ?? null,
    enterSandbox: input.enterSandbox ?? null,
    enterAgent: input.enterAgent ?? null,
  }),
  on: {
    // Surfaces are discovered, never registered — adding one must not require
    // editing Core, which the agent cannot write anyway (ADR-0002).
    DISCOVER_SURFACES: {
      actions: assign({
        surfaces: ({ context, event, spawn }) => [
          ...context.surfaces,
          ...event.descriptors.map((descriptor) =>
            spawn('surface', {
              id: `surface-${descriptor.id}`,
              syncSnapshot: true,
              input: { descriptor },
            }),
          ),
        ],
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
        down: {
          on: {
            START: [
              {
                target: 'starting',
                guard: ({ context }) =>
                  canStartAgent({
                    credential: context.credentialState,
                    sandbox: context.sandboxState,
                  }),
              },
              // Fallback so a refusal explains itself rather than swallowing
              // the click. Note the consequence: can({type:'START'}) is now
              // always true, so nothing may bind `disabled` to it — compute
              // readiness from canStartAgent instead.
              {
                target: 'startRefused',
                actions: assign({
                  refusal: ({ context }) =>
                    refusalFor({
                      credential: context.credentialState,
                      sandbox: context.sandboxState,
                    }),
                }),
              },
            ],
          },
        },
        startRefused: {
          after: { refusalTimeout: 'down' },
          exit: assign({ refusal: null }),
          on: { START: 'down' },
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
