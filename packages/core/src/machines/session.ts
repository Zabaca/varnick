import { setup, assign, fromPromise } from 'xstate'
import type { Message } from '../domain.ts'

/**
 * One durable conversation.
 *
 * Two parallel regions, because they are independent facts: a turn can be
 * streaming while a save is failing, and a failed save must not cancel the
 * turn. Collapsing them into one status enum is the modelling error that would
 * make "the transcript survives a broken build" untrue in exactly the case
 * that matters.
 */

export const SESSION_STATE_PATHS = [
  'turn.idle',
  'turn.sending',
  'turn.streaming',
  'turn.interrupting',
  'turn.failed',
  'persistence.saved',
  'persistence.saving',
  'persistence.saveFailed',
] as const
export type SessionStatePath = (typeof SESSION_STATE_PATHS)[number]

export interface SessionContext {
  readonly sessionId: string
  messages: Message[]
  draft: string
  /** Accumulates during `streaming`; folded into `messages` when the turn ends. */
  partial: string
  turnError: string | null
  saveError: string | null
  readonly enterTurn: string | null
  readonly enterPersistence: string | null
}

export interface SessionInput {
  sessionId: string
  messages?: Message[]
  draft?: string
  partial?: string
  turnError?: string | null
  saveError?: string | null
  enterTurn?: string | null
  enterPersistence?: string | null
}

export type SessionEvent =
  | { type: 'EDIT_DRAFT'; text: string }
  | { type: 'SEND' }
  | { type: 'STREAM_DELTA'; text: string }
  | { type: 'INTERRUPT' }
  | { type: 'RETRY_TURN' }
  | { type: 'DISMISS_TURN_ERROR' }
  | { type: 'SAVE' }
  | { type: 'RETRY_SAVE' }

/**
 * Real-service contracts:
 *   runTurn        input  { sessionId, prompt }
 *                  output { text: string }
 *                  error  thrown Error — shown in `turn.failed`
 *   persistSession input  { sessionId, messages }
 *                  output { ok: true }
 *                  error  thrown Error — shown in `persistence.saveFailed`
 */
export const sessionMachine = setup({
  types: {
    context: {} as SessionContext,
    events: {} as SessionEvent,
    input: {} as SessionInput,
  },
  actors: {
    runTurn: fromPromise<{ text: string }, { sessionId: string; prompt: string }>(
      async () => ({ text: '' }),
    ),
    persistSession: fromPromise<
      { ok: true },
      { sessionId: string; messages: readonly Message[] }
    >(async () => ({ ok: true })),
  },
  guards: {
    hasDraft: ({ context }) => context.draft.trim().length > 0,
  },
  delays: {
    // Named so the states explorer can freeze them. Numeric literals in
    // `after` cannot be overridden by .provide().
    interruptGrace: 400,
  },
}).createMachine({
  id: 'session',
  type: 'parallel',
  context: ({ input }) => ({
    sessionId: input.sessionId,
    messages: input.messages ? [...input.messages] : [],
    draft: input.draft ?? '',
    partial: input.partial ?? '',
    turnError: input.turnError ?? null,
    saveError: input.saveError ?? null,
    enterTurn: input.enterTurn ?? null,
    enterPersistence: input.enterPersistence ?? null,
  }),
  states: {
    turn: {
      initial: 'routing',
      states: {
        routing: {
          always: [
            { target: 'sending', guard: ({ context }) => context.enterTurn === 'sending' },
            { target: 'streaming', guard: ({ context }) => context.enterTurn === 'streaming' },
            {
              target: 'interrupting',
              guard: ({ context }) => context.enterTurn === 'interrupting',
            },
            { target: 'failed', guard: ({ context }) => context.enterTurn === 'failed' },
            { target: 'idle' },
          ],
        },
        idle: {
          on: {
            EDIT_DRAFT: { actions: assign({ draft: ({ event }) => event.text }) },
            // Guarded with no fallback: an empty draft is not a refusal worth
            // explaining, it is a button that should read as inert.
            SEND: { target: 'sending', guard: 'hasDraft' },
          },
        },
        sending: {
          entry: assign({
            messages: ({ context }) => [
              ...context.messages,
              { id: `m${context.messages.length + 1}`, role: 'user' as const, text: context.draft },
            ],
            draft: '',
            partial: '',
            turnError: null,
          }),
          invoke: {
            src: 'runTurn',
            input: ({ context }) => ({
              sessionId: context.sessionId,
              prompt: context.messages[context.messages.length - 1]?.text ?? '',
            }),
            onDone: {
              target: 'idle',
              actions: assign({
                messages: ({ context, event }) => [
                  ...context.messages,
                  {
                    id: `m${context.messages.length + 1}`,
                    role: 'agent' as const,
                    text: event.output.text,
                  },
                ],
                partial: '',
              }),
            },
            onError: {
              target: 'failed',
              actions: assign({
                turnError: ({ event }) =>
                  event.error instanceof Error ? event.error.message : String(event.error),
              }),
            },
          },
          on: {
            STREAM_DELTA: {
              target: 'streaming',
              actions: assign({ partial: ({ event }) => event.text }),
            },
            INTERRUPT: 'interrupting',
          },
        },
        streaming: {
          invoke: {
            src: 'runTurn',
            input: ({ context }) => ({
              sessionId: context.sessionId,
              prompt: context.messages[context.messages.length - 1]?.text ?? '',
            }),
            onDone: {
              target: 'idle',
              actions: assign({
                messages: ({ context, event }) => [
                  ...context.messages,
                  {
                    id: `m${context.messages.length + 1}`,
                    role: 'agent' as const,
                    text: event.output.text,
                  },
                ],
                partial: '',
              }),
            },
            onError: {
              target: 'failed',
              actions: assign({
                turnError: ({ event }) =>
                  event.error instanceof Error ? event.error.message : String(event.error),
              }),
            },
          },
          on: {
            STREAM_DELTA: {
              actions: assign({ partial: ({ context, event }) => context.partial + event.text }),
            },
            INTERRUPT: 'interrupting',
          },
        },
        interrupting: {
          // The partial is kept, not discarded — an interrupted turn still
          // said something, and throwing it away loses work the user watched
          // arrive.
          after: {
            interruptGrace: {
              target: 'idle',
              actions: assign({
                messages: ({ context }) =>
                  context.partial
                    ? [
                        ...context.messages,
                        {
                          id: `m${context.messages.length + 1}`,
                          role: 'agent' as const,
                          text: context.partial,
                        },
                      ]
                    : context.messages,
                partial: '',
              }),
            },
          },
        },
        failed: {
          on: {
            RETRY_TURN: 'sending',
            DISMISS_TURN_ERROR: { target: 'idle', actions: assign({ turnError: null }) },
          },
        },
      },
    },

    persistence: {
      initial: 'routing',
      states: {
        routing: {
          always: [
            { target: 'saving', guard: ({ context }) => context.enterPersistence === 'saving' },
            {
              target: 'saveFailed',
              guard: ({ context }) => context.enterPersistence === 'saveFailed',
            },
            { target: 'saved' },
          ],
        },
        saved: { on: { SAVE: 'saving' } },
        saving: {
          invoke: {
            src: 'persistSession',
            input: ({ context }) => ({
              sessionId: context.sessionId,
              messages: context.messages,
            }),
            onDone: { target: 'saved', actions: assign({ saveError: null }) },
            onError: {
              target: 'saveFailed',
              actions: assign({
                saveError: ({ event }) =>
                  event.error instanceof Error ? event.error.message : String(event.error),
              }),
            },
          },
        },
        saveFailed: { on: { RETRY_SAVE: 'saving', SAVE: 'saving' } },
      },
    },
  },
})
