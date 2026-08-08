import { seededActors, defaultSeedControls, type SeedControls } from './seeded.ts'
import { liveActors, liveAgentExit, liveStopAgent, LIVE_NOT_IMPLEMENTED } from './live.ts'

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

/** Every actor the system declares, and what supplies it in each mode. */
export const ACTOR_NAMES = [
  'checkSandbox',
  'readCredential',
  'spawnAgent',
  'readSubscriptionUsage',
  'runTurn',
  'persistSession',
  'compactSession',
  'loadSurface',
] as const
export type ActorName = (typeof ACTOR_NAMES)[number]

/**
 * Actors with no real implementation yet.
 *
 * Kept explicit rather than inferred: this list is the honest answer to "what
 * does this build actually do", and it shrinks as the harness is written.
 */
export const UNIMPLEMENTED: readonly ActorName[] = LIVE_NOT_IMPLEMENTED

export function actorsFor(mode: ActorMode, controls: SeedControls = defaultSeedControls) {
  return mode === 'live' ? liveActors() : seededActors(controls)
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
 * `?actors=live` in the URL overrides, so the failure of an unwired live actor
 * can be seen without a rebuild. Default is seeded, because almost nothing is
 * wired — see LIVE_NOT_IMPLEMENTED for exactly how much.
 */
export function resolveActorMode(): ActorMode {
  if (typeof window === 'undefined') return 'seeded'
  const requested = new URLSearchParams(window.location.search).get('actors')
  return requested === 'live' ? 'live' : 'seeded'
}

export { seededActors, defaultSeedControls, type SeedControls } from './seeded.ts'
