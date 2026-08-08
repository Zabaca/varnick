import { useEffect, useMemo, useReducer, useRef } from 'react'
import { useMachine } from '@xstate/react'
import type { AnyActorRef, InspectionEvent } from 'xstate'
import { harnessMachine } from './machines/harness.ts'
import { surfaceMachine } from './machines/surface.ts'
import { sessionMachine } from './machines/session.ts'
import { seededActors, defaultSeedControls, type SeedControls } from './actors/seeded.ts'
import { seedPolicy } from './data/seed.ts'

/** Flatten a nested state value to a dotted path. */
export function toPath(value: unknown): string {
  if (typeof value === 'string') return value
  if (value && typeof value === 'object') {
    const key = Object.keys(value as object)[0]
    if (key === undefined) return ''
    const tail = toPath((value as Record<string, unknown>)[key])
    return tail ? `${key}.${tail}` : key
  }
  return ''
}

export interface Transition {
  actor: string
  event: string
  from: string
  to: string
}

/**
 * Bind the Harness with seeded actors.
 *
 * The seeds are provided at the top so every child inherits them — the Session
 * and every Surface run the same implementations, which is what makes the
 * transition log an honest record of one system rather than three.
 */
export function useHarness(controls: SeedControls = defaultSeedControls) {
  const seeds = useMemo(() => seededActors(controls), [controls])
  const log = useRef<Transition[]>([])
  const last = useRef<Record<string, string>>({})
  const [, bumpLog] = useReducer((n: number) => n + 1, 0)

  const machine = useMemo(
    () =>
      harnessMachine.provide({
        actors: {
          checkSandbox: seeds.checkSandbox,
          readCredential: seeds.readCredential,
          spawnAgent: seeds.spawnAgent,
          readSubscriptionUsage: seeds.readSubscriptionUsage,
          surface: surfaceMachine.provide({ actors: { loadSurface: seeds.loadSurface } }),
          session: sessionMachine.provide({
            actors: {
              runTurn: seeds.runTurn,
              persistSession: seeds.persistSession,
              compactSession: seeds.compactSession,
            },
          }),
        },
      }),
    [seeds],
  )

  // One inspector sees every actor in the system, including spawned children,
  // so no machine needs logging inside it.
  const inspect = (ev: InspectionEvent) => {
    if (ev.type !== '@xstate.snapshot') return
    const id = (ev.actorRef as { id?: string }).id ?? 'anonymous'
    const snap = ev.snapshot as { value?: unknown }
    if (snap.value === undefined) return // promise actors carry no state value
    const to = toPath(snap.value)
    const from = last.current[id]
    last.current[id] = to
    if (from === undefined || from === to) return // context-only update
    log.current.push({ actor: id, event: ev.event.type, from, to })
    bumpLog()
  }

  const [snapshot, send, actorRef] = useMachine(machine, {
    input: { policy: seedPolicy },
    inspect,
  })

  return { snapshot, send, actorRef, transitions: log.current }
}

/**
 * Children run on their own clocks, so React needs a nudge when any of them
 * moves. Without this a Surface can fail while the parent never re-renders.
 */
export function useChildRevision(refs: AnyActorRef[]) {
  const [revision, bump] = useReducer((n: number) => n + 1, 0)
  const key = refs.map((r) => r.id).join('|')
  useEffect(() => {
    const subs = refs.map((r) => r.subscribe(bump))
    return () => subs.forEach((s) => s.unsubscribe())
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [key])
  return revision
}
