import { setup, assign, fromPromise } from 'xstate'
import type { SurfaceDescriptor } from '../domain.ts'

/**
 * One actor per discovered Surface.
 *
 * A Surface loads through dynamic import (ADR-0004), so a Userspace module that
 * does not compile is a failed Surface — not a dead application. That isolation
 * is this machine's entire reason to exist, and it is asserted in drive.ts.
 */

export const SURFACE_STATE_PATHS = ['loading', 'loaded', 'failed'] as const
export type SurfaceStatePath = (typeof SURFACE_STATE_PATHS)[number]

export interface SurfaceContext {
  readonly descriptor: SurfaceDescriptor
  /** Set only in `failed`. A failed Surface must be able to say why. */
  error: string | null
  attempts: number
  /** Explorer entry point — see PATTERNS.md §1. */
  readonly enter: SurfaceStatePath | null
}

export interface SurfaceInput {
  descriptor: SurfaceDescriptor
  enter?: SurfaceStatePath | null
  error?: string | null
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
  initial: 'routing',
  context: ({ input }) => ({
    descriptor: input.descriptor,
    error: input.error ?? null,
    attempts: 0,
    enter: input.enter ?? null,
  }),
  states: {
    routing: {
      always: [
        { target: 'loaded', guard: ({ context }) => context.enter === 'loaded' },
        { target: 'failed', guard: ({ context }) => context.enter === 'failed' },
        { target: 'loading' },
      ],
    },
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
