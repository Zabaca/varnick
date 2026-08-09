import { setup, assign, fromPromise } from 'xstate'
import type { PendingWorktree } from '../domain.ts'

/**
 * One actor per opened Worktree diff.
 *
 * The contents behind one row of the review list, read when a developer opens
 * it. A child rather than a fifth region on the Harness, for the same three
 * reasons a Surface is one: it has something to wait on, it can fail, and it
 * must fail without disturbing anything beside it — a developer reviewing a
 * branch is doing it while an agent works, and a git that will not answer must
 * not touch the conversation.
 *
 * ## Summaries there, hunks here
 *
 * The `review` region carries names, counts and one Fence flag, deliberately.
 * This is where the cost is paid, once, for the one worktree somebody chose to
 * read — see packages/harness/src/worktrees.ts.
 *
 * ## What it holds is what git printed
 *
 * `diff` is the text, not a parsed shape. Core parses it for the view (../diff.ts)
 * so that nothing between git and the screen can drop a hunk while still
 * answering the call, and so the parse is a pure function `drive.ts` can assert
 * without a machine at all.
 */

/** The states with a card at `#/states`. One scenario each, checked by drive.ts. */
export const WORKTREE_DIFF_STATE_PATHS = ['loading', 'loaded', 'failed'] as const
export type WorktreeDiffStatePath = (typeof WORKTREE_DIFF_STATE_PATHS)[number]

export interface WorktreeDiffContext {
  /**
   * Which Worktree this is the diff of, as the listing described it.
   *
   * The whole entry rather than the path alone, because the view says which
   * branch and how far ahead above the hunks — and taking that from the entry
   * git produced keeps it the same fact the row above it showed.
   */
  readonly worktree: PendingWorktree
  /**
   * The unified diff, once one has been read.
   *
   * `null` until it has, and `null` again when a read fails — the same rule the
   * Harness follows with a listing it can no longer vouch for. An empty string
   * is a different thing entirely and is kept: a branch ahead by a commit that
   * changed nothing tracked is a real answer.
   */
  diff: string | null
  /** Set only in `failed`. A read that failed must be able to say why. */
  error: string | null
  attempts: number
}

/**
 * A diff is started with the Worktree it is of, and nothing else.
 *
 * No entry point, for the reason `surface.ts` records: an entry point is for a
 * region with nothing to wait on, and a card arriving in `loaded` without a read
 * would be showing a state nothing produced. The frozen actor settles once and
 * then holds — see actors/frozen.ts.
 */
export interface WorktreeDiffInput {
  worktree: PendingWorktree
}

export type WorktreeDiffEvent = { type: 'RETRY' }

/**
 * Real-service contract for `readWorktreeDiff`:
 *   input  { path } — which of the Worktrees git listed, and nothing else.
 *          There is no field for a ref, a range or a command: the host resolves
 *          the ref from git's own listing, and a second way to say it would be
 *          a second way to be wrong.
 *   output { diff } — the text git printed. Produced host-side by running git
 *          and never by the agent: this is the mechanism that shows what the
 *          agent changed, and a diff the agent composed is a diff the agent can
 *          shade — a sharper problem than a shaded list, because a shaded list
 *          hides a branch and a shaded hunk hides a widening inside one
 *          somebody is about to merge.
 *   error  thrown Error — git would not answer, or the path is not a Worktree
 *          with unmerged commits. Both reach `failed` carrying the reason.
 */
export const worktreeDiffMachine = setup({
  types: {
    context: {} as WorktreeDiffContext,
    events: {} as WorktreeDiffEvent,
    input: {} as WorktreeDiffInput,
  },
  actors: {
    readWorktreeDiff: fromPromise<{ diff: string }, { path: string }>(async () => ({ diff: '' })),
  },
}).createMachine({
  id: 'worktreeDiff',
  initial: 'loading',
  context: ({ input }) => ({
    worktree: input.worktree,
    diff: null,
    error: null,
    attempts: 0,
  }),
  states: {
    loading: {
      // Counted on the way in, and the reason cleared with it: a retry that
      // lands back on the previous sentence is indistinguishable from a button
      // that did nothing.
      entry: assign({
        attempts: ({ context }) => context.attempts + 1,
        error: null,
        diff: null,
      }),
      invoke: {
        src: 'readWorktreeDiff',
        input: ({ context }) => ({ path: context.worktree.path }),
        onDone: {
          target: 'loaded',
          actions: assign({ diff: ({ event }) => event.output.diff }),
        },
        onError: {
          target: 'failed',
          actions: assign({
            error: ({ event }) =>
              event.error instanceof Error ? event.error.message : String(event.error),
          }),
        },
      },
    },
    loaded: {},
    failed: {
      // RETRY exists only here, and the diff view's retry exists because of
      // this line rather than because a button was left enabled. Closing is the
      // parent's `CLOSE_WORKTREE`, which is why there is no event for it here:
      // the parent owns the ref, and a child that could close itself would
      // leave the parent holding one that had stopped.
      on: { RETRY: 'loading' },
    },
  },
})
