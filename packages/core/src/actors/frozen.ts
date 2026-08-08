import { fromPromise } from 'xstate'
import { harnessMachine } from '../machines/harness.ts'
import { sessionMachine } from '../machines/session.ts'
import { surfaceMachine } from '../machines/surface.ts'
import type {
  Effort,
  Message,
  ModelId,
  SandboxPolicy,
  SubscriptionUsage,
} from '../domain.ts'

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

export function frozenHarness() {
  return harnessMachine.provide({
    actors: {
      checkSandbox: never<{ ok: true }, { policy: SandboxPolicy }>(),
      readCredential: never<{ source: 'keychain' | 'env' }, Record<string, never>>(),
      spawnAgent: never<{ pid: number }, { policy: SandboxPolicy }>(),
      readSubscriptionUsage: never<SubscriptionUsage, Record<string, never>>(),
      surface: surfaceMachine.provide({
        actors: { loadSurface: never<{ ok: true }, { modulePath: string }>() },
      }),
      session: sessionMachine.provide({
        actors: {
          runTurn: never<
            { text: string; tokensUsed: number },
            { sessionId: string; prompt: string; model: ModelId; effort: Effort }
          >(),
          persistSession: never<
            { ok: true },
            { sessionId: string; messages: readonly Message[] }
          >(),
          compactSession: never<
            { messages: Message[]; tokensUsed: number },
            { sessionId: string; messages: readonly Message[]; model: ModelId }
          >(),
        },
        delays: { interruptGrace: HELD },
      }),
    },
    delays: { refusalTimeout: HELD },
  })
}
