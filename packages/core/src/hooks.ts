import { useCallback, useEffect, useMemo, useReducer, useRef } from 'react'
import { useMachine } from '@xstate/react'
import { fromPromise, type AnyActorRef, type InspectionEvent } from 'xstate'
import { harnessMachine, type HarnessEvent } from './machines/harness.ts'
import { surfaceMachine } from './machines/surface.ts'
import { sessionMachine, type SessionInput } from './machines/session.ts'
import {
  actorsFor,
  agentControlFor,
  resolveActorMode,
  defaultSeedControls,
  type ActorMode,
  type MintObserver,
  type SeedControls,
  type TurnObserver,
} from './actors/index.ts'
import { liveForgetAgentContext } from './actors/live.ts'
import { loadUserspaceSurface } from './actors/surface-loader.ts'
import { regionOf } from './domain.ts'
import { seedPolicy } from './data/seed.ts'

/**
 * The Surface loader, the same in seeded and live mode.
 *
 * Wired here rather than in `actorsFor` because it is not one of the two: there
 * is no service behind an `import()` to stand in for, so there is nothing to
 * seed — see ACTOR_NAMES in actors/index.ts. Here is also as far into Core as
 * `import.meta.glob` may reach: this module is browser-only, and drive.ts,
 * which runs under bun where that construct does not exist, never imports it.
 */
const loadSurface = fromPromise<{ ok: true }, { modulePath: string }>(async ({ input }) => {
  await loadUserspaceSurface(input.modulePath)
  return { ok: true as const }
})

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

  /*
    What a running Turn says, delivered to whichever machine it is about.

    Indirect through a ref because of an ordering problem that is real rather
    than incidental: the actors are built before `useMachine` runs, and the way
    to send an event only exists after it. The observer handed to the actors is
    therefore stable and the thing it calls is replaced once the machine exists.

    This is the same shape `AGENT_EXIT` already has below. An actor resolves
    once, and a delta and a rejected credential both happen while it is still
    running — so neither can travel back as its result, and neither is
    addressed to the machine that invoked it. A delta is the Session's; a
    rejected credential is the Harness's.
  */
  const signals = useRef<TurnObserver & MintObserver>({
    delta: () => {},
    credentialRejected: () => {},
    runtimeReported: () => {},
    commandsReported: () => {},
    authorizing: () => {},
  })
  const observer = useMemo<TurnObserver>(
    () => ({
      delta: (text) => signals.current.delta(text),
      credentialRejected: (detail) => signals.current.credentialRejected(detail),
      runtimeReported: (report) => signals.current.runtimeReported(report),
      commandsReported: (commands) => signals.current.commandsReported(commands),
    }),
    [],
  )
  /*
    The same arrangement for the mint, and it is a second port rather than a
    third method on the first because the two are about different things: a Turn
    is a conversation, and a mint is a credential coming into existence. They
    share the indirection, which is the ordering problem — the actors are built
    before `useMachine` runs, and the way to send an event only exists after it.
  */
  const mint = useMemo<MintObserver>(
    () => ({ authorizing: (url) => signals.current.authorizing(url) }),
    [],
  )

  const seeds = useMemo(
    () => actorsFor(mode, controls, observer, mint),
    [mode, controls, observer, mint],
  )
  const log = useRef<Transition[]>([])
  const last = useRef<Record<string, string>>({})
  const [, bumpLog] = useReducer((n: number) => n + 1, 0)

  const machine = useMemo(
    () =>
      harnessMachine.provide({
        actors: {
          checkSandbox: seeds.checkSandbox,
          readCredential: seeds.readCredential,
          storeCredential: seeds.storeCredential,
          mintSubscriptionToken: seeds.mintSubscriptionToken,
          spawnAgent: seeds.spawnAgent,
          surface: surfaceMachine.provide({ actors: { loadSurface } }),
          session: sessionMachine.provide({
            actors: {
              runTurn: seeds.runTurn,
              persistSession: seeds.persistSession,
              compactSession: seeds.compactSession,
            },
            /*
              The other half of a clear, supplied at the same seam the actors
              are. A seeded run keeps the machine's no-op: there is no agent to
              tell, and a seeded clear that reached for the bridge would be a
              browser tab calling a host it does not have.
            */
            actions: mode === 'live' ? { forgetAgentContext: () => void liveForgetAgentContext() } : {},
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
    Where a running Turn's two signals land.

    A delta goes to the Session, which is a spawned child — read off the
    parent's context rather than held here, so a restart cannot leave this
    pointing at a Session that has been replaced.

    `CREDENTIAL_REJECTED` goes to the Harness, and this is the whole route from
    a Turn's 401 to `credential.rejected`. The Session cannot send it: it is a
    child, and a child does not send to its parent. Nothing about the machines
    changed to make this work — the event already existed, and this is the same
    place `AGENT_EXIT` is raised from, for the same reason. A Turn that failed
    on authentication says something about the credential rather than about the
    conversation, and a developer who retries the Turn instead of fixing the key
    is retrying the wrong thing.
  */
  useEffect(() => {
    signals.current = {
      delta: (text) => {
        actorRef.getSnapshot().context.session?.send({ type: 'STREAM_DELTA', text })
      },
      credentialRejected: (detail) => send({ type: 'CREDENTIAL_REJECTED', detail }),
      // The third thing a Turn says that is not its answer, and the Harness's
      // like the second: what the runtime is describes the agent process, not
      // the conversation it happened to arrive during.
      runtimeReported: (report) => send({ type: 'RUNTIME_REPORTED', report }),
      // The fourth, and the Harness's for the same reason the third is: what
      // the agent will accept is a fact about the agent.
      commandsReported: (commands) => send({ type: 'COMMANDS_REPORTED', commands }),
      // And where the mint's one signal lands. `credential.minting` is the only
      // state that accepts it, so a URL from an attempt that has already ended
      // is dropped by the machine rather than guarded against here.
      authorizing: (url) => send({ type: 'MINT_URL', url }),
    }
  }, [actorRef, send])

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
    // Keyed on the ids, not on `refs`: callers build that array inline, so a
    // dependency on it would resubscribe every render. An exhaustive-deps rule
    // would want `refs` here and be wrong; the repo's lint config carries one
    // rule and it is not that one, so this says it in prose rather than in a
    // disable directive nothing defines.
  }, [key])
  return revision
}
