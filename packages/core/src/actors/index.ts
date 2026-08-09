import { seededActors, defaultSeedControls, type SeedControls } from './seeded.ts'
import {
  liveActors,
  liveAgentExit,
  liveStopAgent,
  LIVE_NOT_IMPLEMENTED,
  type MintObserver,
  type TurnObserver,
} from './live.ts'

/**
 * Which implementations the machines run against.
 *
 * The machines declare actor contracts and never import an implementation, so
 * the whole system swaps at this one seam. `seeded` is how a feature gets
 * designed before it can be built: declare the contract, seed it, look at the
 * real UI driven by real machines against plausible data.
 *
 * The rule this replaces was being argued case by case — whether a particular
 * number was honest enough to render. It is not a judgement call. Seeded data
 * is fine to show as long as the surface says it is seeded, and the marker only
 * goes away when someone wires the real thing.
 */
export type ActorMode = 'seeded' | 'live'

/**
 * Every actor the system declares, and what supplies it in each mode.
 *
 * `loadSurface` is on this list and in neither `seededActors` nor `liveActors`,
 * which is not an oversight. Every other actor stands in for a service — a
 * keychain, an API, a file store — and a seed is a plausible answer from one.
 * Loading a Surface is not a service call: it is importing a file that either
 * exists and compiles or does not. A seeded loader would answer `loaded` for a
 * module nobody imported, and the panel beside the chat would then be empty
 * with nothing on screen to explain it. So there is one implementation, used in
 * both modes, and it is wired where the machine is assembled — see hooks.ts,
 * which is also the last place in Core that can reach Userspace without
 * dragging `import.meta.glob` into drive.ts.
 */
export const ACTOR_NAMES = [
  'checkSandbox',
  'readCredential',
  'storeCredential',
  'mintSubscriptionToken',
  'spawnAgent',
  'readSubscriptionUsage',
  'runTurn',
  'persistSession',
  'compactSession',
  'loadSurface',
] as const
export type ActorName = (typeof ACTOR_NAMES)[number]

/**
 * Actors with no real implementation. Empty: every name above is wired.
 *
 * Kept explicit rather than inferred, and kept now that it is empty rather than
 * deleted, because empty is a claim someone has to be able to falsify. It is
 * declared once in `LIVE_NOT_IMPLEMENTED` and read in two places: `drive.ts`
 * fails the build if it stops being empty, and the seeded-data marker's tooltip
 * names whatever is in it.
 */
export const UNIMPLEMENTED: readonly ActorName[] = LIVE_NOT_IMPLEMENTED

/**
 * The implementations, for one run.
 *
 * `observer` is what a live Turn says while it is still running — a delta, a
 * rejected credential — neither of which can come back through an actor's
 * promise, because an actor resolves once and both happen before that. A seeded
 * run ignores it: the seeded turn is one `await` and a string, and the bare
 * page's `STREAM_DELTA` button is how streaming is reached without an agent.
 *
 * `mint` is the same arrangement for the one other long-running actor: the URL
 * a sign-in prints, which arrives minutes before the mint settles. A seeded run
 * ignores that too, and deliberately makes up no link — see seeded.ts.
 */
export function actorsFor(
  mode: ActorMode,
  controls: SeedControls = defaultSeedControls,
  observer?: TurnObserver,
  mint?: MintObserver,
) {
  return mode === 'live' ? liveActors(observer, mint) : seededActors(controls)
}

/**
 * The agent process, as something with a lifetime rather than a result.
 *
 * Separate from the actors above because neither of these is one. An actor is
 * invoked by a state and answers it; a process ending is something the world
 * did, which reaches the machine as `AGENT_EXIT` — an event, like
 * `CREDENTIAL_REJECTED`. Modelling it as an actor would have meant a state
 * whose job was to wait for a crash, and `agent.running` is not that.
 *
 * Chosen by the same mode as the actors, so one run is one system.
 */
export interface AgentControl {
  /** Resolves when the agent process ends, with why. */
  exit(): Promise<string>
  /** Stop the process tree behind `agent.down`. */
  stop(): Promise<void>
}

export function agentControlFor(mode: ActorMode): AgentControl {
  return mode === 'live'
    ? { exit: liveAgentExit, stop: liveStopAgent }
    : {
        // A seeded agent never dies on its own. The bare page's AGENT_EXIT
        // button is how that state is reached without a process, and a seed
        // that crashed on a timer would make the states page non-deterministic.
        exit: () => new Promise<string>(() => {}),
        stop: async () => {},
      }
}

/**
 * Mode for this run.
 *
 * **Live by default**, because every actor is now real — `LIVE_NOT_IMPLEMENTED`
 * is empty. It defaulted to seeded for as long as that list had entries, and the
 * comment here justified it by pointing at the list; the list emptied one ticket
 * at a time and nobody owned the moment it hit zero, so the running app went on
 * showing invented numbers with a real host behind it.
 *
 * `?actors=seeded` is the override, and it keeps two jobs worth having: design
 * work against plausible data, and a browser tab, which has no host and would
 * otherwise fail every call. Both are the exception now rather than the rule.
 *
 * Headless stays seeded. `drive.ts` drives the machines with no window, and a
 * live default there would have a test suite establishing kernel sandboxes and
 * spawning agents.
 */
export function resolveActorMode(): ActorMode {
  if (typeof window === 'undefined') return 'seeded'
  const requested = new URLSearchParams(window.location.search).get('actors')
  return requested === 'seeded' ? 'seeded' : 'live'
}

export { seededActors, defaultSeedControls, type SeedControls } from './seeded.ts'
export type { MintObserver, TurnObserver } from './live.ts'
