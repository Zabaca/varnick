import { setup, assign, fromPromise, raise } from 'xstate'
import type { Message } from '../domain.ts'
import { isCommandDraft } from '../domain.ts'
import type { Effort, ModelId } from '../domain.ts'

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
  'turn.answering.sending',
  'turn.answering.streaming',
  'turn.interrupting',
  'turn.failed',
  'turn.compacting',
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
  /** Supplied by the view; the machine derives menu state from it rather than
   *  being told when to open. */
  commandNames: readonly string[]
  /** What the next turn runs on. Settable mid-session; applies to the next turn. */
  model: ModelId
  effort: Effort
  /** Cumulative tokens the conversation currently occupies. */
  tokensUsed: number
  compactError: string | null
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
  commandNames?: readonly string[]
  model?: ModelId
  effort?: Effort
  tokensUsed?: number
  compactError?: string | null
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
  /** Tab, or a click: put the command in the draft. It does not run it. */
  | { type: 'MENU_COMPLETE'; name: string }
  | { type: 'MENU_DISMISS' }
  | { type: 'CLEAR' }
  | { type: 'SET_MODEL'; model: ModelId }
  | { type: 'SET_EFFORT'; effort: Effort }
  | { type: 'SET_COMMANDS'; names: readonly string[] }
  | { type: 'COMPACT' }

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
    runTurn: fromPromise<
      { text: string; tokensUsed: number },
      { sessionId: string; prompt: string; model: ModelId; effort: Effort }
    >(async () => ({ text: '', tokensUsed: 0 })),
    /*
      Real-service contract for compactSession:
        input  { sessionId, messages, model }
        output { messages, tokensUsed } — the summarised history and its new cost
        error  thrown Error, shown in turn.compacting's failure path
    */
    compactSession: fromPromise<
      { messages: Message[]; tokensUsed: number },
      { sessionId: string; messages: readonly Message[]; model: ModelId }
    >(async ({ input }) => ({ messages: [...input.messages], tokensUsed: 0 })),
    persistSession: fromPromise<
      { ok: true },
      { sessionId: string; messages: readonly Message[] }
    >(async () => ({ ok: true })),
  },
  actions: {
    /**
     * A Turn boundary — the moment the transcript stops changing.
     *
     * Raised rather than left to a caller, so the mirror is written by the
     * machine that owns the transcript instead of by whoever remembered to ask.
     * `raise` goes to the machine, so it crosses into `persistence` without
     * either region reaching into the other.
     */
    saveTranscript: raise({ type: 'SAVE' }),
  },
  guards: {
    // Enter always sends, menu or not. Completing a command is Tab's job, and
    // a sent draft that names a command runs it — see invokedCommand.
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
    menuOpen: input.menuOpen ?? false,
    menuIndex: input.menuIndex ?? 0,
    menuDismissed: false,
    commandNames: input.commandNames ?? [],
    model: input.model ?? 'claude-opus-5',
    effort: input.effort ?? 'xhigh',
    tokensUsed: input.tokensUsed ?? 0,
    compactError: input.compactError ?? null,
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
    // Legal at any time. Changing either mid-turn does not disturb the turn in
    // flight; it is what the next one runs on.
    /*
      The agent forgot, so the window does too — in whatever state it is in.

      **At the root, and that is the whole of what makes it work.** `CLEAR` was
      a command, accepted in `idle` and `failed` and refused during an answer,
      which is right for a request: clearing halfway through a reply is not
      something to honour. It is a *report* now — the runtime announcing
      `conversation_reset` — and it arrives while the Turn that typed `/clear`
      is still running. Refused there, the transcript kept a conversation the
      agent had already thrown away, which is the exact disagreement listening
      was supposed to end. Measured in the running app: `running=turn-1
      finished=false` at the moment it was dropped.

      A state cannot decline a fact. What it does with it is another matter, and
      here that is the same thing everywhere: the transcript goes.
    */
    CLEAR: {
      actions: assign({
        messages: [],
        partial: '',
        turnError: null,
        compactError: null,
        draft: '',
        menuIndex: 0,
        tokensUsed: 0,
      }),
    },
    SET_COMMANDS: { actions: assign({ commandNames: ({ event }) => event.names }) },
    SET_MODEL: { actions: assign({ model: ({ event }) => event.model }) },
    SET_EFFORT: { actions: assign({ effort: ({ event }) => event.effort }) },
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
            { target: 'answering', guard: ({ context }) => context.enterTurn === 'sending' },
            { target: 'answering.streaming', guard: ({ context }) => context.enterTurn === 'streaming' },
            {
              target: 'interrupting',
              guard: ({ context }) => context.enterTurn === 'interrupting',
            },
            { target: 'compacting', guard: ({ context }) => context.enterTurn === 'compacting' },
            { target: 'failed', guard: ({ context }) => context.enterTurn === 'failed' },
            { target: 'idle' },
          ],
        },
        idle: {
          on: {

          COMPACT: { target: 'compacting', actions: assign({ compactError: null }) },
            // Guarded with no fallback: an empty draft is not a refusal worth
            // explaining, it is a button that should read as inert.
            SEND: {
              target: 'answering',
              guard: 'hasDraft',
              actions: assign({
                messages: ({ context }) => [
                  ...context.messages,
                  {
                    id: `m${context.messages.length + 1}`,
                    role: 'user' as const,
                    text: context.draft,
                  },
                ],
                draft: '',
              }),
            },
          },
        },
        /*
          One Turn, one actor.

          `sending` and `streaming` used to be siblings and each invoked
          `runTurn`. An invoke is bound to the state it sits on, so the first
          streamed token stopped the first actor and started a second: in live
          mode that aborted the developer's Turn at its first token, told the
          host to interrupt it, and posted the same prompt again — billed twice,
          answered once. The two blocks were byte-identical, which is why the
          census assertion in drive.ts passed; it compared them to each other.

          Wrapping them says the true thing once: a Turn is in flight, and
          whether anything has come back yet is a detail of how it is going.
        */
        answering: {
          initial: 'sending',
          // Deliberately no entry that appends the prompt. `RETRY_TURN` re-enters
          // this state, and by then the draft has been consumed and cleared — an
          // entry action would append an empty user message and retry with an
          // empty prompt, writing the empty message to the mirror on the way.
          // The append belongs to SEND, which is the only event that has a draft.
          entry: assign({ partial: '', turnError: null }),
          invoke: {
            src: 'runTurn',
            input: ({ context }) => ({
              sessionId: context.sessionId,
              prompt: context.messages[context.messages.length - 1]?.text ?? '',
              model: context.model,
              effort: context.effort,
            }),
            onDone: {
              target: 'idle',
              actions: [
                assign({
                  messages: ({ context, event }) => [
                    ...context.messages,
                    {
                      id: `m${context.messages.length + 1}`,
                      role: 'agent' as const,
                      text: event.output.text,
                    },
                  ],
                  partial: '',
                  tokensUsed: ({ event }) => event.output.tokensUsed,
                }),
                'saveTranscript',
              ],
            },
            onError: {
              target: 'failed',
              // A failed Turn is still a boundary: the user's message is in the
              // transcript whether or not an answer ever arrived, and losing it
              // to the failure is the case the mirror exists for.
              actions: [
                assign({
                  turnError: ({ event }) =>
                    event.error instanceof Error ? event.error.message : String(event.error),
                }),
                'saveTranscript',
              ],
            },
          },
          on: { INTERRUPT: 'interrupting' },
          states: {
            /** Posted, and nothing back yet. */
            sending: {
              on: {
                STREAM_DELTA: {
                  target: 'streaming',
                  actions: assign({ partial: ({ event }) => event.text }),
                },
              },
            },
            /** Output arriving. Same actor, same Turn. */
            streaming: {
              on: {
                STREAM_DELTA: {
                  actions: assign({
                    partial: ({ context, event }) => context.partial + event.text,
                  }),
                },
              },
            },
          },
        },
        interrupting: {
          // The partial is kept, not discarded — an interrupted turn still
          // said something, and throwing it away loses work the user watched
          // arrive.
          after: {
            interruptGrace: {
              target: 'idle',
              actions: [
                assign({
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
                'saveTranscript',
              ],
            },
          },
        },
        compacting: {
          invoke: {
            src: 'compactSession',
            input: ({ context }) => ({
              sessionId: context.sessionId,
              /*
                A copy, and the one line that makes "the conversation is
                explicitly unchanged" structural rather than a rule an
                implementation has to remember.

                `readonly Message[]` is a compile-time claim and nothing at run
                time: a compaction that assembled the replacement in the array
                it was handed and then threw would leave a half-rewritten
                conversation behind a state that says nothing happened. Handing
                over a copy means the replacement can only arrive as the
                actor's *result*, so there is no way to change the transcript
                except by finishing.
              */
              messages: [...context.messages],
              model: context.model,
            }),
            onDone: {
              target: 'idle',
              // Compaction rewrites history rather than extending it, which the
              // mirror has to be told about — an append-only file would keep
              // both the summary and everything it replaced.
              actions: [
                assign({
                  messages: ({ event }) => event.output.messages,
                  tokensUsed: ({ event }) => event.output.tokensUsed,
                  compactError: null,
                }),
                'saveTranscript',
              ],
            },
            onError: {
              target: 'idle',
              /*
                No boundary, deliberately. Every other exit from a Turn raises
                SAVE; this one must not. A compaction that failed changed
                nothing, and the transcript it would hand the store is the one
                already on disk — but Compaction is the boundary that takes the
                store's *replace* path, and a failure that reached it would put
                the mirror one atomic rewrite away from a conversation nobody
                rewrote. Nothing happened, so nothing is written.
              */
              actions: assign({
                compactError: ({ event }) =>
                  event.error instanceof Error ? event.error.message : String(event.error),
              }),
            },
          },
        },
        failed: {
          on: {

          COMPACT: { target: 'compacting', actions: assign({ compactError: null }) },
            RETRY_TURN: 'answering',
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
          // A Turn boundary reached while a save is in flight restarts the save
          // with the transcript as it now is. Ignoring it would leave the mirror
          // one Turn behind and `persistence.saved` would be a lie — the state
          // says the transcript is on disk, so it has to mean the current one.
          on: { SAVE: { target: 'saving', reenter: true } },
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
            guard: ({ context }) =>
              isCommandDraft(context.draft, context.commandNames) && !context.menuDismissed,
          },
        },
        menu: {
          entry: assign({ menuOpen: true }),
          always: {
            target: 'typing',
            guard: ({ context }) =>
              !isCommandDraft(context.draft, context.commandNames) || context.menuDismissed,
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
            // Completion writes the command into the draft and leaves it there.
            // The trailing space is what closes the menu, through the same
            // derived rule as typing one by hand.
            MENU_COMPLETE: {
              actions: assign({
                draft: ({ event }) => `${event.name} `,
                menuIndex: 0,
                menuDismissed: false,
              }),
            },
            MENU_DISMISS: { actions: assign({ menuDismissed: true, menuIndex: 0 }) },
          },
        },
      },
    },
  },
})
