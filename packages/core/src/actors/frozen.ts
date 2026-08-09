import { fromPromise } from 'xstate'
import { harnessMachine } from '../machines/harness.ts'
import { sessionMachine } from '../machines/session.ts'
import { surfaceMachine } from '../machines/surface.ts'
import { worktreeDiffMachine } from '../machines/worktree-diff.ts'
import type { PastedImage } from '@varnick/harness/turn'
import type {
  CredentialKind,
  CredentialReading,
  Effort,
  Message,
  ModelId,
  PendingWorktree,
  SandboxPolicy,
} from '../domain.ts'
import { brokenSurfaceErrorFor, seedWorktreeDiff, seedWorktreeDiffError } from '../data/seed.ts'

/**
 * The Harness, frozen.
 *
 * Same machine, same states, same guards, same transitions — `provide()` rather
 * than a second copy, because a demo copy drifts and then the explorer is
 * testing something that does not ship.
 *
 * Frozen means two things: every actor returns a promise that never settles, so
 * a card parked in `sending` stays in `sending` while it is read; and every
 * named delay is pushed past any session, so `startRefused` does not quietly
 * expire and `interrupting` does not resolve itself. Both are why the machines
 * name their delays instead of writing numeric literals in `after`.
 *
 * Events still work. A card is live — clicking a control moves it, which is the
 * point, and the card offers a reset when it has drifted from what it claims.
 */

// Generic over input as well as output, or the provided logic silently stops
// matching the contract the machine declared.
const never = <TOut, TIn>() => fromPromise<TOut, TIn>(() => new Promise<TOut>(() => {}))

/** Longer than anyone will read one card. Not Infinity — setTimeout clamps it. */
const HELD = 24 * 60 * 60 * 1000

/**
 * What the frozen loader does with the Surface a card discovers.
 *
 * The one actor a card may need to *settle*, and the exception is the point
 * rather than a hole in it: `loading` is a card frozen the way every other card
 * is frozen, and `loaded` and `failed` are states a Surface can only be in
 * because a load finished. Each settles once, immediately, and then holds — the
 * property "a card does not advance while it is read" is intact, which is what
 * freezing is for.
 *
 * The alternative was routing a card straight into `loaded` through the
 * machine's entry point. That entry point exists for regions with nothing to
 * wait on; a loader has something to wait on, and a card that reached `loaded`
 * without a load would be showing a state nothing produced.
 */
export type SurfaceOutcome = 'holds' | 'loads' | 'fails'

/**
 * And what the frozen diff reader does with the Worktree a card opens.
 *
 * The same three, for the same reason: `loading` is a card frozen the way every
 * other card is frozen, and `loaded` and `failed` are states a diff can only be
 * in because a read finished. The alternative — an entry point routing a card
 * straight into `loaded` — would be a card showing a state nothing produced,
 * with a diff in it that no read returned.
 */
export type DiffOutcome = 'holds' | 'loads' | 'fails'

export function frozenHarness(
  surfaceOutcome: SurfaceOutcome = 'holds',
  diffOutcome: DiffOutcome = 'holds',
) {
  return harnessMachine.provide({
    actors: {
      checkSandbox: never<{ ok: true }, { policy: SandboxPolicy }>(),
      readCredential: never<CredentialReading, Record<string, never>>(),
      storeCredential: never<void, { kind: CredentialKind; value: string }>(),
      mintSubscriptionToken: never<void, Record<string, never>>(),
      spawnAgent: never<{ pid: number }, { policy: SandboxPolicy }>(),
      // Frozen like the rest, which is what lets a card sit in `review.listing`
      // — the state every card whose scenario names no other one is in, because
      // the region starts in flight rather than at rest.
      listWorktrees: never<{ worktrees: readonly PendingWorktree[] }, Record<string, never>>(),
      worktreeDiff: worktreeDiffMachine.provide({
        actors: {
          readWorktreeDiff: fromPromise<{ diff: string }, { path: string }>(() => {
            if (diffOutcome === 'holds') return new Promise<{ diff: string }>(() => {})
            if (diffOutcome === 'fails') return Promise.reject(new Error(seedWorktreeDiffError))
            return Promise.resolve({ diff: seedWorktreeDiff })
          }),
        },
      }),
      surface: surfaceMachine.provide({
        actors: {
          loadSurface: fromPromise<{ ok: true }, { modulePath: string }>(({ input }) => {
            if (surfaceOutcome === 'holds') return new Promise<{ ok: true }>(() => {})
            if (surfaceOutcome === 'fails') {
              return Promise.reject(new Error(brokenSurfaceErrorFor(input.modulePath)))
            }
            return Promise.resolve({ ok: true as const })
          }),
        },
      }),
      session: sessionMachine.provide({
        actors: {
          runTurn: never<
            { text: string; tokensUsed: number },
            {
              sessionId: string
              prompt: string
              model: ModelId
              effort: Effort
              images: readonly PastedImage[]
            }
          >(),
          persistSession: never<
            { ok: true },
            { sessionId: string; messages: readonly Message[] }
          >(),
        },
        delays: { interruptGrace: HELD },
      }),
    },
    delays: { refusalTimeout: HELD },
  })
}
