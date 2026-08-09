import { setup, assign, fromPromise } from 'xstate'
import type { SurfaceDescriptor } from '../domain.ts'

/**
 * One actor per discovered Surface.
 *
 * A Surface loads through dynamic import (ADR-0004), so a Userspace module that
 * does not compile is a failed Surface — not a dead application. That isolation
 * is this machine's entire reason to exist, and it is asserted in drive.ts.
 */

/** The states with a card at `#/states`. One scenario each, checked by drive.ts. */
export const SURFACE_STATE_PATHS = ['loading', 'loaded', 'failed'] as const
export type SurfaceStatePath = (typeof SURFACE_STATE_PATHS)[number]

/**
 * `unloaded` is a real state and deliberately has no card.
 *
 * It is final, and the parent drops the actor ref the moment it handles
 * `UNLOAD_SURFACE`, so nothing in the product is ever rendered in it — a card
 * would be a picture of something no user can reach. Driving the child to
 * `unloaded` directly leaves a dead panel; that is documented at the button in
 * chat-surface.tsx rather than drawn. The bare page could do it by hand, which
 * is where the note came from; it was removed in ADR-0013 and the hazard is
 * still real for anyone sending the event.
 *
 * It is exported anyway, because the exported lists are what `drive.ts` builds
 * the surface-brief ban list from. A state the machines have and the list does
 * not is a state a brief can name with the build staying green, which is the
 * one thing that check exists to stop. Two lists, two jobs: this one is every
 * state, `SURFACE_STATE_PATHS` is the ones with cards.
 */
export const SURFACE_UNCARDED_STATE_PATHS = ['unloaded'] as const

export interface SurfaceContext {
  readonly descriptor: SurfaceDescriptor
  /** Set only in `failed`. A failed Surface must be able to say why. */
  error: string | null
  attempts: number
}

/**
 * A Surface is started with the module to load, and nothing else.
 *
 * The other machines take an explorer entry point — a state to route straight
 * into, so a card can be parked somewhere without waiting. This one deliberately
 * does not, and it used to anyway: `enter` and `error` were on the input, a
 * `routing` state branched on them, and no instantiation site ever passed
 * either. Both arms were unreachable and `routing` always fell through, so the
 * machine had a state whose only behaviour was to be skipped.
 *
 * It is not an oversight that nothing passed them — `frozen.ts` records the
 * reason. An entry point is for a region with nothing to wait on; a loader has
 * something to wait on, and a card that arrived in `loaded` without a load would
 * be showing a state nothing produced. So the frozen loader settles for real,
 * once, and then holds. Removed rather than wired, because wiring it would have
 * meant building the thing frozen.ts argues against.
 */
export interface SurfaceInput {
  descriptor: SurfaceDescriptor
}

export type SurfaceEvent = { type: 'RETRY' } | { type: 'UNLOAD' }

/**
 * Real-service contract for `loadSurface`:
 *   input  { modulePath: string }
 *   output { ok: true }
 *   error  thrown Error whose message is shown in the failed Surface
 */
export const surfaceMachine = setup({
  types: {
    context: {} as SurfaceContext,
    events: {} as SurfaceEvent,
    input: {} as SurfaceInput,
  },
  actors: {
    loadSurface: fromPromise<{ ok: true }, { modulePath: string }>(async () => ({
      ok: true,
    })),
  },
}).createMachine({
  id: 'surface',
  initial: 'loading',
  context: ({ input }) => ({
    descriptor: input.descriptor,
    error: null,
    attempts: 0,
  }),
  states: {
    loading: {
      entry: assign({ attempts: ({ context }) => context.attempts + 1, error: null }),
      invoke: {
        src: 'loadSurface',
        input: ({ context }) => ({ modulePath: context.descriptor.modulePath }),
        onDone: 'loaded',
        onError: {
          target: 'failed',
          actions: assign({
            error: ({ event }) =>
              event.error instanceof Error ? event.error.message : String(event.error),
          }),
        },
      },
    },
    loaded: {
      on: { UNLOAD: 'unloaded' },
    },
    failed: {
      // RETRY exists only here. A loaded Surface has no retry affordance
      // because the state has no handler, not because the UI hid one.
      on: { RETRY: 'loading', UNLOAD: 'unloaded' },
    },
    unloaded: { type: 'final' },
  },
})
