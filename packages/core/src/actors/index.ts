import { seededActors, defaultSeedControls, type SeedControls } from './seeded.ts'
import { liveActors, LIVE_NOT_IMPLEMENTED } from './live.ts'

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
