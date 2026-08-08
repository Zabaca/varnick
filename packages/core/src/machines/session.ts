import { setup, assign, fromPromise } from 'xstate'
import type { Message } from '../domain.ts'
import { isCommandDraft } from '../domain.ts'

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
  'composer.typing',
  'composer.menu',
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
  /**
   * Published by the composer region so the SEND guard can read it. A guard
   * receives only { context, event } and cannot see a sibling region's value,
   * so the region states its fact here instead of reaching sideways.
   */
  menuOpen: boolean
  menuIndex: number
  /** Escape closes the menu without clearing a draft that still starts with `/`. */
  menuDismissed: boolean
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
  menuOpen?: boolean
  menuIndex?: number
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
  /** `count` is the number of commands currently listed; the machine does not
   *  own the command list, so the view supplies it for wrapping. */
  | { type: 'MENU_MOVE'; delta: number; count: number }
  | { type: 'MENU_COMMIT' }
  | { type: 'MENU_DISMISS' }
  | { type: 'CLEAR' }

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
    // A draft addressing the command menu is not a message. Enter picks a
    // command there; it must not send.
    hasDraft: ({ context }) => context.draft.trim().length > 0 && !context.menuOpen,
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
    menuOpen: input.menuOpen ?? false,
    menuIndex: input.menuIndex ?? 0,
    menuDismissed: false,
    enterTurn: input.enterTurn ?? null,
    enterPersistence: input.enterPersistence ?? null,
  }),
  /*
    Typing belongs to the machine, not to a turn state.

    EDIT_DRAFT was scoped to `turn.idle`, which made the composer inert while
    the agent was working — you could not queue the next message, and the
    command menu could not open mid-turn. Caught by an assertion that the menu
    opens during a live turn.
  */
  on: {
    EDIT_DRAFT: {
      actions: assign({
        draft: ({ event }) => event.text,
        menuDismissed: false,
        menuIndex: 0,
      }),
    },
  },
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
          CLEAR: {
            actions: assign({
              messages: [],
              partial: '',
              turnError: null,
              draft: '',
              menuIndex: 0,
            }),
          },
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
          CLEAR: {
            actions: assign({
              messages: [],
              partial: '',
              turnError: null,
              draft: '',
              menuIndex: 0,
            }),
          },
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

    /*
      The composer. Independent of the turn: a menu can be open while a turn
      streams, and closing one has nothing to do with the other.

      Menu state is derived from the draft rather than toggled, so it cannot
      drift from what is actually typed. `menuDismissed` is the one piece of
      memory that needs holding: Escape closes the menu while leaving the text
      alone, and without it the eventless transition would reopen immediately.
    */
    composer: {
      initial: 'typing',
      states: {
        typing: {
          entry: assign({ menuOpen: false }),
          always: {
            target: 'menu',
            guard: ({ context }) => isCommandDraft(context.draft) && !context.menuDismissed,
          },
        },
        menu: {
          entry: assign({ menuOpen: true }),
          always: {
            target: 'typing',
            guard: ({ context }) => !isCommandDraft(context.draft) || context.menuDismissed,
          },
          on: {
            MENU_MOVE: {
              actions: assign({
                menuIndex: ({ context, event }) =>
                  event.count <= 0
                    ? 0
                    : (context.menuIndex + event.delta + event.count) % event.count,
              }),
            },
            // The view performs the command; the machine only closes the menu.
            MENU_COMMIT: { actions: assign({ draft: '', menuIndex: 0 }) },
            MENU_DISMISS: { actions: assign({ menuDismissed: true, menuIndex: 0 }) },
          },
        },
      },
    },
  },
})
