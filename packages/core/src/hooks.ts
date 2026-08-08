import { useCallback, useEffect, useMemo, useReducer, useRef } from 'react'
import { useMachine } from '@xstate/react'
import type { AnyActorRef, InspectionEvent } from 'xstate'
import { harnessMachine, type HarnessEvent } from './machines/harness.ts'
import { surfaceMachine } from './machines/surface.ts'
import { sessionMachine, type SessionInput } from './machines/session.ts'
import {
  actorsFor,
  agentControlFor,
  resolveActorMode,
  defaultSeedControls,
  type ActorMode,
  type SeedControls,
} from './actors/index.ts'
import { regionOf } from './domain.ts'
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
 * Bind the Harness.
 *
 * Implementations are chosen once, at the top, so every child inherits the same
 * set — the Session and every Surface run against one mode, which is what makes
 * the transition log an honest record of one system rather than three. See
 * actors/index.ts for what seeded and live mean.
 *
 * `sessionInput` is what the Session is spawned with. It has to arrive here,
 * before the machine is created, because the Harness holds it in context and
 * spawns from it on entry to `agent.running` — which is also why a relaunch
 * reads the mirror in start-up rather than in an actor. Left out, the machine
 * uses its own default and the conversation starts empty.
 */
export function useHarness(
  controls: SeedControls = defaultSeedControls,
  requestedMode?: ActorMode,
  sessionInput?: SessionInput,
) {
  const mode = requestedMode ?? resolveActorMode()
  const seeds = useMemo(() => actorsFor(mode, controls), [mode, controls])
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
    input: { policy: seedPolicy, sessionInput },
    inspect,
  })

  /*
    The agent process's own exit, turned into the event that names it.

    Watched per entry to `agent.running` rather than once, because a restart is
    a new process with a new way to die — watching only the first would make the
    second crash invisible, and `agent.running` would keep claiming a process
    that had gone. A restart passes through `starting`, so `running` goes false
    and back to true, and the effect runs again for the new process.

    `cancelled` matters for the same reason in reverse: a STOP or an unmount
    leaves a wait outstanding, and delivering its answer later would report an
    exit against a machine that had moved on.
  */
  const agent = useMemo(() => agentControlFor(mode), [mode])
  const running = regionOf(snapshot.value, 'agent') === 'running'
  useEffect(() => {
    if (!running) return
    let cancelled = false
    agent
      .exit()
      .then((detail) => {
        if (!cancelled) send({ type: 'AGENT_EXIT', detail })
      })
      .catch((error: unknown) => {
        // A watch that could not be established is itself a reason the agent
        // cannot be reported on. Saying so beats leaving `running` up forever.
        if (!cancelled) {
          send({
            type: 'AGENT_EXIT',
            detail: error instanceof Error ? error.message : String(error),
          })
        }
      })
    return () => {
      cancelled = true
    }
  }, [agent, running, send])

  /*
    STOP is the one event with a process behind it.

    Sent through here rather than handled by an effect on `agent.down`, because
    `down` is also where a run starts: an effect would kill an agent on first
    load, and in a browser tab it would call a host that is not there. Wrapping
    the send keeps "stopping means stopping the process tree" attached to the
    act rather than to the state.
  */
  const sendToHarness = useCallback(
    (event: HarnessEvent) => {
      if (event.type === 'STOP') void agent.stop().catch(() => {})
      send(event)
    },
    [agent, send],
  )

  return { snapshot, send: sendToHarness, actorRef, mode, transitions: log.current }
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
