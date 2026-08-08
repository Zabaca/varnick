/**
 * Headless assertions over the machines. No DOM, no React, no components.
 *
 * These assert the things that are easy to get wrong and invisible in a
 * rendered screenshot: events that must be refused, regions that must stay
 * independent, and failures that must stay contained. Nothing renders until
 * this passes.
 *
 * Run: bun run drive
 */
import { readdirSync, readFileSync } from 'node:fs'
import { createActor, fromPromise, waitFor } from 'xstate'
import { harnessMachine, HARNESS_STATE_PATHS } from '../src/machines/harness.ts'
import { sessionMachine, SESSION_STATE_PATHS, type SessionEvent } from '../src/machines/session.ts'
import { surfaceMachine, SURFACE_STATE_PATHS } from '../src/machines/surface.ts'
import {
  regionOf,
  canStartAgent,
  compactedTranscript,
  invokedCommand,
  isCommandDraft,
  formatContext,
} from '../src/domain.ts'
import { compactionFailureMessage } from '@varnick/harness/turn'
import { liveActors } from '../src/actors/live.ts'
import { seedPolicy, seedSurfaces, brokenSurfaceError } from '../src/data/seed.ts'
import { SCENARIOS, uncoveredPaths, unknownPaths } from '../src/data/scenarios.ts'
import { frozenHarness } from '../src/actors/frozen.ts'
import { ACTOR_NAMES, UNIMPLEMENTED } from '../src/actors/index.ts'
import type { Effort, Message, ModelId, SandboxPolicy } from '../src/domain.ts'

let passed = 0
const failures: string[] = []

function check(label: string, condition: boolean) {
  if (condition) {
    passed++
  } else {
    failures.push(label)
  }
}

// Seeded actor implementations. Generic over input as well as output, or the
// provided logic stops matching the machine's declared actor contract.
const resolves = <TOut, TIn = Record<string, unknown>>(value: TOut) =>
  fromPromise<TOut, TIn>(async () => value)

const rejects = <TOut = never, TIn = Record<string, unknown>>(message: string) =>
  fromPromise<TOut, TIn>(async () => {
    throw new Error(message)
  })

const never = <TOut = never, TIn = Record<string, unknown>>() =>
  fromPromise<TOut, TIn>(() => new Promise<TOut>(() => {}))

type TurnInput = { sessionId: string; prompt: string; model: ModelId; effort: Effort }
type TurnOutput = { text: string; tokensUsed: number }
const turnNever = () => never<TurnOutput, TurnInput>()

type CompactInput = { sessionId: string; messages: readonly Message[]; model: ModelId }
type CompactOutput = { messages: Message[]; tokensUsed: number }

// ---------------------------------------------------------------------------
// Harness — the start gate
// ---------------------------------------------------------------------------

{
  // Nothing checked, nothing read: START must be refused, and the refusal must
  // say why rather than being swallowed.
  const actor = createActor(harnessMachine, { input: { policy: seedPolicy } }).start()

  check('starts with agent down', regionOf(actor.getSnapshot().value, 'agent') === 'down')
  check(
    'canStartAgent is false with no credential and no sandbox',
    !canStartAgent({
      credential: regionOf(actor.getSnapshot().value, 'credential'),
      sandbox: regionOf(actor.getSnapshot().value, 'sandbox'),
    }),
  )

  actor.send({ type: 'START' })
  check(
    'START with no credential lands in startRefused',
    regionOf(actor.getSnapshot().value, 'agent') === 'startRefused',
  )
  check(
    'the refusal names the missing credential',
    actor.getSnapshot().context.refusal?.kind === 'no-credential',
  )
  actor.stop()
}

{
  // Credential present, sandbox unavailable: still refused, and for the right
  // reason. An agent must never fall back to running unconfined.
  const actor = createActor(
    harnessMachine.provide({
      actors: {
        readCredential: resolves<{ source: 'keychain' | 'env' }, Record<string, never>>({ source: 'keychain' }),
        checkSandbox: rejects<{ ok: true }, { policy: SandboxPolicy }>('srt: sandbox_apply not permitted'),
      },
    }),
    { input: { policy: seedPolicy } },
  ).start()

  actor.send({ type: 'READ_CREDENTIAL' })
  await waitFor(actor, (s) => regionOf(s.value, 'credential') === 'present')
  actor.send({ type: 'CHECK_SANDBOX' })
  await waitFor(actor, (s) => regionOf(s.value, 'sandbox') === 'unavailable')

  actor.send({ type: 'START' })
  check(
    'START with an unavailable sandbox is refused',
    regionOf(actor.getSnapshot().value, 'agent') === 'startRefused',
  )
  check(
    'the refusal names the sandbox, not the credential',
    actor.getSnapshot().context.refusal?.kind === 'sandbox-unavailable',
  )
  check(
    'a failed sandbox check keeps its error',
    actor.getSnapshot().context.sandboxError === 'srt: sandbox_apply not permitted',
  )
  actor.stop()
}

{
  // Pressing START again after fixing the cause must start the agent.
  //
  // Regression: `startRefused` handled START by returning to `down`, so the
  // second press — the one that should have worked — silently did nothing.
  // Found by driving the bare page, because this script only ever pressed
  // START once.
  const actor = createActor(
    harnessMachine.provide({
      actors: {
        readCredential: resolves<{ source: 'keychain' | 'env' }, Record<string, never>>({
          source: 'keychain',
        }),
        checkSandbox: resolves<{ ok: true }, { policy: SandboxPolicy }>({ ok: true }),
        spawnAgent: resolves<{ pid: number }, { policy: SandboxPolicy }>({ pid: 7 }),
      },
    }),
    { input: { policy: seedPolicy } },
  ).start()

  actor.send({ type: 'START' })
  check(
    'the first START is refused',
    regionOf(actor.getSnapshot().value, 'agent') === 'startRefused',
  )

  actor.send({ type: 'READ_CREDENTIAL' })
  await waitFor(actor, (s) => regionOf(s.value, 'credential') === 'present')
  actor.send({ type: 'CHECK_SANDBOX' })
  await waitFor(actor, (s) => regionOf(s.value, 'sandbox') === 'available')
  check(
    'still showing the refusal after the cause is fixed',
    regionOf(actor.getSnapshot().value, 'agent') === 'startRefused',
  )

  actor.send({ type: 'START' })
  await waitFor(actor, (s) => regionOf(s.value, 'agent') === 'running')
  check(
    'START from startRefused starts the agent once it can',
    regionOf(actor.getSnapshot().value, 'agent') === 'running',
  )
  actor.stop()
}

// ---------------------------------------------------------------------------
// Harness — region independence
// ---------------------------------------------------------------------------

{
  const actor = createActor(
    harnessMachine.provide({
      actors: {
        readCredential: resolves<{ source: 'keychain' | 'env' }, Record<string, never>>({ source: 'keychain' }),
        checkSandbox: resolves<{ ok: true }, { policy: SandboxPolicy }>({ ok: true }),
        spawnAgent: resolves<{ pid: number }, { policy: SandboxPolicy }>({ pid: 4242 }),
      },
    }),
    { input: { policy: seedPolicy } },
  ).start()

  actor.send({ type: 'READ_CREDENTIAL' })
  await waitFor(actor, (s) => regionOf(s.value, 'credential') === 'present')
  actor.send({ type: 'CHECK_SANDBOX' })
  await waitFor(actor, (s) => regionOf(s.value, 'sandbox') === 'available')
  actor.send({ type: 'START' })
  await waitFor(actor, (s) => regionOf(s.value, 'agent') === 'running')

  check('agent runs once both facts hold', regionOf(actor.getSnapshot().value, 'agent') === 'running')

  // The independence that a single status enum would destroy.
  actor.send({ type: 'AGENT_EXIT', detail: 'exit 71' })
  check('a crashed agent leaves the credential alone', regionOf(actor.getSnapshot().value, 'credential') === 'present')
  check('a crashed agent leaves the sandbox alone', regionOf(actor.getSnapshot().value, 'sandbox') === 'available')
  check('the crash keeps its detail', actor.getSnapshot().context.agentError === 'exit 71')

  actor.send({ type: 'CREDENTIAL_REJECTED', detail: '401' })
  check('a rejected credential does not restart the agent', regionOf(actor.getSnapshot().value, 'agent') === 'crashed')

  actor.stop()
}

{
  // The Session outlives an agent restart. This is the whole durability claim.
  const actor = createActor(
    harnessMachine.provide({
      actors: {
        readCredential: resolves<{ source: 'keychain' | 'env' }, Record<string, never>>({ source: 'keychain' }),
        checkSandbox: resolves<{ ok: true }, { policy: SandboxPolicy }>({ ok: true }),
        spawnAgent: resolves<{ pid: number }, { policy: SandboxPolicy }>({ pid: 1 }),
      },
    }),
    { input: { policy: seedPolicy } },
  ).start()

  actor.send({ type: 'READ_CREDENTIAL' })
  await waitFor(actor, (s) => regionOf(s.value, 'credential') === 'present')
  actor.send({ type: 'CHECK_SANDBOX' })
  await waitFor(actor, (s) => regionOf(s.value, 'sandbox') === 'available')
  actor.send({ type: 'START' })
  await waitFor(actor, (s) => regionOf(s.value, 'agent') === 'running')

  const first = actor.getSnapshot().context.session
  check('a Session exists once the agent is running', first !== null)

  actor.send({ type: 'AGENT_EXIT', detail: 'killed' })
  actor.send({ type: 'RESTART' })
  await waitFor(actor, (s) => regionOf(s.value, 'agent') === 'running')

  check('the same Session survives an agent restart', actor.getSnapshot().context.session === first)
  check('a restart clears the previous crash', actor.getSnapshot().context.agentError === null)
  actor.stop()
}

{
  // AGENT_EXIT arrives from a real process now, which makes *where it is
  // refused* load-bearing rather than incidental. Every stop produces one: the
  // host kills the tree, the process dies, and the exit is reported. If any
  // state below accepted it, a deliberate stop would be indistinguishable from
  // a crash — and `down` means "stopped on purpose" (CONTEXT.md).
  const actor = createActor(
    harnessMachine.provide({
      actors: {
        readCredential: resolves<{ source: 'keychain' | 'env' }, Record<string, never>>({
          source: 'keychain',
        }),
        checkSandbox: resolves<{ ok: true }, { policy: SandboxPolicy }>({ ok: true }),
        spawnAgent: resolves<{ pid: number }, { policy: SandboxPolicy }>({ pid: 99 }),
      },
    }),
    { input: { policy: seedPolicy } },
  ).start()

  check('a machine with no agent refuses AGENT_EXIT', !actor.getSnapshot().can({ type: 'AGENT_EXIT', detail: 'x' }))

  actor.send({ type: 'READ_CREDENTIAL' })
  await waitFor(actor, (s) => regionOf(s.value, 'credential') === 'present')
  actor.send({ type: 'CHECK_SANDBOX' })
  await waitFor(actor, (s) => regionOf(s.value, 'sandbox') === 'available')
  actor.send({ type: 'START' })
  await waitFor(actor, (s) => regionOf(s.value, 'agent') === 'running')

  check('a running agent accepts AGENT_EXIT', actor.getSnapshot().can({ type: 'AGENT_EXIT', detail: 'x' }))

  actor.send({ type: 'STOP' })
  check('STOP stops on purpose', regionOf(actor.getSnapshot().value, 'agent') === 'down')
  actor.send({ type: 'AGENT_EXIT', detail: 'The agent process was killed by signal 9.' })
  check(
    'the exit a deliberate stop causes does not read as a crash',
    regionOf(actor.getSnapshot().value, 'agent') === 'down',
  )
  check('a stop leaves no crash reason behind it', actor.getSnapshot().context.agentError === null)

  actor.send({ type: 'START' })
  await waitFor(actor, (s) => regionOf(s.value, 'agent') === 'running')
  actor.send({ type: 'AGENT_EXIT', detail: 'The agent process exited with code 71.' })
  check('a crash keeps the first reason', actor.getSnapshot().context.agentError === 'The agent process exited with code 71.')
  // A dying process can report more than once — the watcher for a replaced
  // generation, a stop racing an exit. The first reason is the one that
  // explains the crash; a later one would overwrite it with something vaguer.
  actor.send({ type: 'AGENT_EXIT', detail: 'The agent process could not be waited on.' })
  check(
    'a second exit does not overwrite the reason for the first',
    actor.getSnapshot().context.agentError === 'The agent process exited with code 71.',
  )
  actor.stop()
}

// ---------------------------------------------------------------------------
// Session — refusals and parallel independence
// ---------------------------------------------------------------------------

{
  const actor = createActor(sessionMachine, { input: { sessionId: 's1' } }).start()

  check('an empty draft cannot be sent', !actor.getSnapshot().can({ type: 'SEND' }))
  actor.send({ type: 'EDIT_DRAFT', text: 'hello' })
  check('a non-empty draft can be sent', actor.getSnapshot().can({ type: 'SEND' }))
  check('idle refuses INTERRUPT', !actor.getSnapshot().can({ type: 'INTERRUPT' }))
  actor.stop()
}

{
  const actor = createActor(
    sessionMachine.provide({ actors: { runTurn: turnNever() } }),
    { input: { sessionId: 's2' } },
  ).start()

  actor.send({ type: 'EDIT_DRAFT', text: 'build me a Surface' })
  actor.send({ type: 'SEND' })
  check('sending clears the draft', actor.getSnapshot().context.draft === '')
  check('the user message is recorded immediately', actor.getSnapshot().context.messages.length === 1)
  check('sending accepts INTERRUPT', actor.getSnapshot().can({ type: 'INTERRUPT' }))

  actor.send({ type: 'STREAM_DELTA', text: 'wor' })
  check('a delta moves the turn to streaming', regionOf(actor.getSnapshot().value, 'turn') === 'streaming')
  actor.send({ type: 'STREAM_DELTA', text: 'king' })
  check('deltas accumulate', actor.getSnapshot().context.partial === 'working')

  // A save failing must not disturb the turn — the reason these are regions.
  const before = regionOf(actor.getSnapshot().value, 'turn')
  actor.send({ type: 'SAVE' })
  check('the turn is unaffected by a save', regionOf(actor.getSnapshot().value, 'turn') === before)
  actor.stop()
}

{
  // An interrupted turn keeps what already arrived.
  const actor = createActor(
    sessionMachine.provide({ actors: { runTurn: turnNever() }, delays: { interruptGrace: 1 } }),
    { input: { sessionId: 's3' } },
  ).start()

  actor.send({ type: 'EDIT_DRAFT', text: 'go' })
  actor.send({ type: 'SEND' })
  actor.send({ type: 'STREAM_DELTA', text: 'partial answer' })
  actor.send({ type: 'INTERRUPT' })
  check('interrupting refuses another INTERRUPT', !actor.getSnapshot().can({ type: 'INTERRUPT' }))

  await waitFor(actor, (s) => regionOf(s.value, 'turn') === 'idle')
  const last = actor.getSnapshot().context.messages.at(-1)
  check('the partial survives the interrupt', last?.text === 'partial answer')
  check('the partial buffer is cleared', actor.getSnapshot().context.partial === '')
  actor.stop()
}

{
  // A failed turn recovers on retry; a failed save recovers independently.
  let turnAttempts = 0
  const actor = createActor(
    sessionMachine.provide({
      actors: {
        runTurn: fromPromise<TurnOutput, TurnInput>(async () => {
          turnAttempts++
          if (turnAttempts === 1) throw new Error('stream closed')
          return { text: 'second time', tokensUsed: 120 }
        }),
      },
    }),
    { input: { sessionId: 's4' } },
  ).start()

  actor.send({ type: 'EDIT_DRAFT', text: 'try' })
  actor.send({ type: 'SEND' })
  await waitFor(actor, (s) => regionOf(s.value, 'turn') === 'failed')
  check('a failed turn keeps its error', actor.getSnapshot().context.turnError === 'stream closed')
  check('a failed turn refuses INTERRUPT', !actor.getSnapshot().can({ type: 'INTERRUPT' }))

  actor.send({ type: 'RETRY_TURN' })
  await waitFor(actor, (s) => regionOf(s.value, 'turn') === 'idle')
  check('a seeded failure recovers on retry', actor.getSnapshot().context.messages.at(-1)?.text === 'second time')
  actor.stop()
}

{
  let saveAttempts = 0
  const actor = createActor(
    sessionMachine.provide({
      actors: {
        runTurn: turnNever(),
        persistSession: fromPromise(async () => {
          saveAttempts++
          if (saveAttempts === 1) throw new Error('disk full')
          return { ok: true as const }
        }),
      },
    }),
    { input: { sessionId: 's5' } },
  ).start()

  actor.send({ type: 'SAVE' })
  await waitFor(actor, (s) => regionOf(s.value, 'persistence') === 'saveFailed')
  check('a failed save keeps its error', actor.getSnapshot().context.saveError === 'disk full')
  check('a failed save leaves the turn idle', regionOf(actor.getSnapshot().value, 'turn') === 'idle')
  check('the transcript is still sendable while a save is failing', actor.getSnapshot().can({ type: 'EDIT_DRAFT', text: 'x' }))

  actor.send({ type: 'RETRY_SAVE' })
  await waitFor(actor, (s) => regionOf(s.value, 'persistence') === 'saved')
  check('retrying the save clears the error', actor.getSnapshot().context.saveError === null)
  actor.stop()
}

// ---------------------------------------------------------------------------
// Session — the host-side mirror
//
// The transcript is written at every Turn boundary, and the two regions stay
// independent while it happens. These are machine facts: what the mirror does
// with the messages is tested in packages/harness/src/session.test.ts.
// ---------------------------------------------------------------------------

type SaveInput = { sessionId: string; messages: readonly Message[] }

/**
 * Did the wait finish?
 *
 * The mirror is written by an event the machine raises, so the regression to
 * guard against is that nobody ever raises it — and a bare `waitFor` for an
 * event that never comes hangs the script instead of failing it. A hang reads
 * as a broken build rather than a broken machine, which is the wrong signal.
 */
const reaches = (wait: Promise<unknown>): Promise<boolean> => wait.then(() => true, () => false)
const soon = { timeout: 2_000 }

/** Records what the mirror was handed. `settle: false` holds `persistence` in
 *  `saving` so a save in flight can be observed rather than inferred. */
function saveSpy(settle: boolean) {
  const spy = { calls: 0, last: [] as readonly Message[] }
  const actor = fromPromise<{ ok: true }, SaveInput>(({ input }) => {
    spy.calls++
    spy.last = input.messages
    return settle ? Promise.resolve({ ok: true as const }) : new Promise<{ ok: true }>(() => {})
  })
  return { spy, actor }
}

const textsOf = (messages: readonly Message[]) => messages.map((m) => m.text).join('|')

{
  // A completed turn writes the transcript without anything outside the machine
  // remembering to ask.
  const { spy, actor: persistSession } = saveSpy(true)
  const actor = createActor(
    sessionMachine.provide({
      actors: { runTurn: resolves<TurnOutput, TurnInput>({ text: 'done', tokensUsed: 42 }), persistSession },
    }),
    { input: { sessionId: 'p1' } },
  ).start()

  check('a session saves nothing before a turn', spy.calls === 0)
  actor.send({ type: 'EDIT_DRAFT', text: 'mirror this' })
  actor.send({ type: 'SEND' })
  check(
    'a completed turn saves without being asked',
    await reaches(waitFor(actor, (s) => regionOf(s.value, 'turn') === 'idle' && spy.calls > 0, soon)),
  )
  check('a completed turn saves exactly once', spy.calls === 1)
  check('the mirror is handed the transcript the turn produced', textsOf(spy.last) === 'mirror this|done')
  await waitFor(actor, (s) => regionOf(s.value, 'persistence') === 'saved')
  check('the save settles back to saved', regionOf(actor.getSnapshot().value, 'persistence') === 'saved')
  actor.stop()
}

{
  // A failed turn is still a boundary. The user's message is in the transcript
  // whether or not an answer arrived, and it is the failure case the mirror
  // exists for.
  const { spy, actor: persistSession } = saveSpy(false)
  const actor = createActor(
    sessionMachine.provide({
      actors: { runTurn: rejects<TurnOutput, TurnInput>('stream closed'), persistSession },
    }),
    { input: { sessionId: 'p2' } },
  ).start()

  actor.send({ type: 'EDIT_DRAFT', text: 'this one fails' })
  actor.send({ type: 'SEND' })
  check(
    'a failed turn still mirrors the transcript',
    await reaches(waitFor(actor, (s) => regionOf(s.value, 'turn') === 'failed' && spy.calls > 0, soon)),
  )
  check('the failed turn keeps the user message in the mirror', textsOf(spy.last) === 'this one fails')
  check('mirroring a failed turn does not clear the turn error', actor.getSnapshot().context.turnError === 'stream closed')
  actor.stop()
}

{
  // An interrupted turn said something, and what it said is mirrored.
  const { spy, actor: persistSession } = saveSpy(false)
  const actor = createActor(
    sessionMachine.provide({
      actors: { runTurn: turnNever(), persistSession },
      delays: { interruptGrace: 1 },
    }),
    { input: { sessionId: 'p3' } },
  ).start()

  actor.send({ type: 'EDIT_DRAFT', text: 'go' })
  actor.send({ type: 'SEND' })
  actor.send({ type: 'STREAM_DELTA', text: 'half an answer' })
  actor.send({ type: 'INTERRUPT' })
  check(
    'an interrupted turn reaches the mirror',
    await reaches(waitFor(actor, (s) => regionOf(s.value, 'turn') === 'idle' && spy.calls > 0, soon)),
  )
  check('an interrupted turn mirrors the partial it kept', textsOf(spy.last) === 'go|half an answer')
  actor.stop()
}

{
  // Compaction rewrites history rather than extending it, so the boundary has
  // to be reported or the mirror keeps the summary and everything it replaced.
  const { spy, actor: persistSession } = saveSpy(false)
  const actor = createActor(
    sessionMachine.provide({
      actors: {
        runTurn: turnNever(),
        compactSession: resolves<CompactOutput, CompactInput>({
          messages: [{ id: 'c1', role: 'agent', text: 'summary so far' }],
          tokensUsed: 10,
        }),
        persistSession,
      },
    }),
    { input: { sessionId: 'p4', messages: [{ id: 'm1', role: 'user', text: 'one' }] } },
  ).start()

  actor.send({ type: 'COMPACT' })
  check(
    'a compaction reaches the mirror',
    await reaches(waitFor(actor, (s) => regionOf(s.value, 'turn') === 'idle' && spy.calls > 0, soon)),
  )
  check('a compaction mirrors the rewritten history', textsOf(spy.last) === 'summary so far')
  actor.stop()
}

{
  // The independence claim in both directions: a save can fail while a turn
  // streams, and the running turn never blocks the save.
  let saveAttempts = 0
  const actor = createActor(
    sessionMachine.provide({
      actors: {
        runTurn: turnNever(),
        persistSession: fromPromise<{ ok: true }, SaveInput>(async () => {
          saveAttempts++
          if (saveAttempts === 1) throw new Error('read-only filesystem')
          return { ok: true as const }
        }),
      },
    }),
    { input: { sessionId: 'p5' } },
  ).start()

  actor.send({ type: 'EDIT_DRAFT', text: 'keep streaming' })
  actor.send({ type: 'SEND' })
  actor.send({ type: 'STREAM_DELTA', text: 'arriving' })
  actor.send({ type: 'SAVE' })
  check('a running turn does not block a save', regionOf(actor.getSnapshot().value, 'persistence') === 'saving')

  await waitFor(actor, (s) => regionOf(s.value, 'persistence') === 'saveFailed')
  check('a save can fail while a turn streams', regionOf(actor.getSnapshot().value, 'turn') === 'streaming')
  check('a failed save does not cancel the turn in flight', actor.getSnapshot().context.partial === 'arriving')
  check('a failed save is not a failed turn', actor.getSnapshot().context.turnError === null)
  check('a failed save leaves the turn interruptible', actor.getSnapshot().can({ type: 'INTERRUPT' }))

  const before = actor.getSnapshot().context.messages
  actor.send({ type: 'RETRY_SAVE' })
  await waitFor(actor, (s) => regionOf(s.value, 'persistence') === 'saved')
  check('retrying the save leaves the turn streaming', regionOf(actor.getSnapshot().value, 'turn') === 'streaming')
  check('retrying the save does not touch the conversation', actor.getSnapshot().context.messages === before)
  check('retrying the save does not touch the partial', actor.getSnapshot().context.partial === 'arriving')
  actor.stop()
}

{
  // A turn boundary reached while a save is still in flight must not be
  // dropped: `saved` would then claim a transcript that is one turn old.
  const { spy, actor: persistSession } = saveSpy(false)
  const actor = createActor(
    sessionMachine.provide({
      actors: { runTurn: resolves<TurnOutput, TurnInput>({ text: 'answer', tokensUsed: 1 }), persistSession },
    }),
    { input: { sessionId: 'p6' } },
  ).start()

  actor.send({ type: 'SAVE' })
  check('a save in flight sits in saving', regionOf(actor.getSnapshot().value, 'persistence') === 'saving')
  check('saving still accepts a save', actor.getSnapshot().can({ type: 'SAVE' }))

  actor.send({ type: 'EDIT_DRAFT', text: 'while the save hangs' })
  actor.send({ type: 'SEND' })
  check(
    'a boundary during an in-flight save is not dropped',
    await reaches(waitFor(actor, (s) => regionOf(s.value, 'turn') === 'idle' && spy.calls > 1, soon)),
  )
  check('the in-flight save is restarted, not duplicated', spy.calls === 2)
  check('the restarted save carries the newer transcript', textsOf(spy.last) === 'while the save hangs|answer')
  actor.stop()
}

// ---------------------------------------------------------------------------
// Session — resumed on launch
//
// The entry point the states page uses to park a conversation mid-flight is the
// same one a relaunch comes in through; the only difference is that the input
// is read off disk instead of written as a literal. What the mirror does with
// the bytes is tested in packages/harness/src/session.test.ts. These are the
// machine facts: which state a restored Session enters, and what its first save
// carries.
// ---------------------------------------------------------------------------

{
  // A transcript as a relaunch gets it back from the mirror: complete messages,
  // one of them redacted, and nothing else. There is no partial and no turn
  // state on disk to restore, because the mirror is written at Turn boundaries.
  const restored: Message[] = [
    { id: 'm1', role: 'user', text: 'call the API with [redacted]' },
    { id: 'm2', role: 'agent', text: 'done — it returned 200' },
  ]

  const { spy, actor: persistSession } = saveSpy(true)
  const actor = createActor(
    harnessMachine.provide({
      actors: {
        readCredential: resolves<{ source: 'keychain' | 'env' }, Record<string, never>>({ source: 'keychain' }),
        checkSandbox: resolves<{ ok: true }, { policy: SandboxPolicy }>({ ok: true }),
        spawnAgent: resolves<{ pid: number }, { policy: SandboxPolicy }>({ pid: 1 }),
        session: sessionMachine.provide({
          actors: { runTurn: resolves<TurnOutput, TurnInput>({ text: 'still here', tokensUsed: 7 }), persistSession },
        }),
      },
    }),
    { input: { policy: seedPolicy, sessionInput: { sessionId: 'session-1', messages: restored } } },
  ).start()

  actor.send({ type: 'READ_CREDENTIAL' })
  await waitFor(actor, (s) => regionOf(s.value, 'credential') === 'present')
  actor.send({ type: 'CHECK_SANDBOX' })
  await waitFor(actor, (s) => regionOf(s.value, 'sandbox') === 'available')
  actor.send({ type: 'START' })
  await waitFor(actor, (s) => regionOf(s.value, 'agent') === 'running')

  const session = actor.getSnapshot().context.session
  check('a launch spawns the Session from the input it was given', session !== null)

  const resumed = session!.getSnapshot()
  check(
    'the restored transcript is the conversation, not a fresh one',
    textsOf(resumed.context.messages) === 'call the API with [redacted]|done — it returned 200',
  )
  check('a resumed Session names the Session that was read', resumed.context.sessionId === 'session-1')

  // The in-flight-at-crash decision, as a machine fact. Not `sending` — nothing
  // is in flight. Not `failed` — nothing observed a failure; the process died.
  // A killed Turn and an interrupted one are the same event from the
  // transcript's side, and an interrupt already resolves to idle.
  check('a resumed Session is idle, never sending', regionOf(resumed.value, 'turn') === 'idle')
  check('a resumed Session invents no failure to explain the crash', resumed.context.turnError === null)
  check('a resumed Session carries no partial, because the mirror holds none', resumed.context.partial === '')
  check('a resumed Session is saved, not dirty', regionOf(resumed.value, 'persistence') === 'saved')
  check('resuming is not a Turn boundary and writes nothing', spy.calls === 0)
  check('a resumed Session can be talked to immediately', session!.getSnapshot().can({ type: 'EDIT_DRAFT', text: 'x' }))

  // The reason a restore has to be read before a Session runs on that id: the
  // next save has to *extend* the mirror. A Session that started empty over a
  // transcript that is not empty would rewrite the file instead.
  session!.send({ type: 'EDIT_DRAFT', text: 'carry on' })
  session!.send({ type: 'SEND' })
  check(
    'the first Turn after a resume reaches the mirror',
    await reaches(waitFor(session!, (s) => regionOf(s.value, 'turn') === 'idle' && spy.calls > 0, soon)),
  )
  check(
    'the save after a resume extends the restored transcript rather than replacing it',
    textsOf(spy.last) === 'call the API with [redacted]|done — it returned 200|carry on|still here',
  )

  actor.stop()
}

{
  // Why the resumed state costs nothing to decide: a Turn that was still
  // streaming has nothing on disk for any state to be about. The mirror is only
  // ever handed `messages`, and the partial is not one until a boundary folds
  // it in.
  const { spy, actor: persistSession } = saveSpy(false)
  const actor = createActor(
    sessionMachine.provide({ actors: { runTurn: turnNever(), persistSession } }),
    { input: { sessionId: 'p7' } },
  ).start()

  actor.send({ type: 'EDIT_DRAFT', text: 'ask' })
  actor.send({ type: 'SEND' })
  actor.send({ type: 'STREAM_DELTA', text: 'half an answer' })
  actor.send({ type: 'SAVE' })
  await waitFor(actor, (s) => regionOf(s.value, 'persistence') === 'saving', soon)

  check('a save mid-stream carries the transcript', textsOf(spy.last) === 'ask')
  check(
    'a save mid-stream cannot carry the partial, so a crash leaves none to restore',
    !textsOf(spy.last).includes('half an answer') && actor.getSnapshot().context.partial === 'half an answer',
  )
  actor.stop()
}

// ---------------------------------------------------------------------------
// Session — the command menu
// ---------------------------------------------------------------------------

{
  const actor = createActor(sessionMachine, { input: { sessionId: 's6', commandNames: ['/clear', '/retry', '/save', '/effort low', '/effort max', '/model opus-5', '/model sonnet-5'] } }).start()
  const composer = () => regionOf(actor.getSnapshot().value, 'composer')

  check('the composer starts typing', composer() === 'typing')

  actor.send({ type: 'EDIT_DRAFT', text: '/' })
  check('a leading slash opens the menu', composer() === 'menu')
  // Enter sends whether or not the menu is showing; Tab is what completes.
  check('the menu does not block sending', actor.getSnapshot().can({ type: 'SEND' }))

  actor.send({ type: 'EDIT_DRAFT', text: '/cle' })
  check('typing the command keeps the menu open', composer() === 'menu')

  // A space means the slash text is an argument, not a query.
  // A space no longer closes the menu by itself — `/model son` must keep it —
  // so the test is whether anything still matches.
  actor.send({ type: 'EDIT_DRAFT', text: '/clear now' })
  check('a draft matching no command closes the menu', composer() === 'typing')

  actor.send({ type: 'EDIT_DRAFT', text: '/model son' })
  check('a partial multi-word command keeps the menu open', composer() === 'menu')

  actor.send({ type: 'EDIT_DRAFT', text: '/model sonnet-5 ' })
  check('the trailing space after a full name closes it', composer() === 'typing')

  // Ordinary text never opens it.
  actor.send({ type: 'EDIT_DRAFT', text: 'build me a thing' })
  check('ordinary text leaves the menu closed', composer() === 'typing')
  actor.stop()
}

{
  const actor = createActor(sessionMachine, { input: { sessionId: 's7', commandNames: ['/clear', '/retry', '/save', '/effort low', '/effort max', '/model opus-5', '/model sonnet-5'] } }).start()
  actor.send({ type: 'EDIT_DRAFT', text: '/c' })

  actor.send({ type: 'MENU_MOVE', delta: 1, count: 3 })
  check('moving down advances the highlight', actor.getSnapshot().context.menuIndex === 1)
  actor.send({ type: 'MENU_MOVE', delta: 1, count: 3 })
  actor.send({ type: 'MENU_MOVE', delta: 1, count: 3 })
  check('the highlight wraps at the end', actor.getSnapshot().context.menuIndex === 0)
  actor.send({ type: 'MENU_MOVE', delta: -1, count: 3 })
  check('and wraps backwards from the start', actor.getSnapshot().context.menuIndex === 2)
  actor.send({ type: 'MENU_MOVE', delta: 1, count: 0 })
  check('an empty list cannot be moved off zero', actor.getSnapshot().context.menuIndex === 0)
  actor.stop()
}

{
  // Escape closes the menu without eating the draft — and it must stay closed,
  // which is the whole reason menuDismissed exists. Without it the eventless
  // transition reopens the menu on the next microstep.
  const actor = createActor(sessionMachine, { input: { sessionId: 's8', commandNames: ['/clear', '/retry', '/save', '/effort low', '/effort max', '/model opus-5', '/model sonnet-5'] } }).start()
  const composer = () => regionOf(actor.getSnapshot().value, 'composer')

  actor.send({ type: 'EDIT_DRAFT', text: '/clear' })
  check('menu is open before dismissing', composer() === 'menu')

  actor.send({ type: 'MENU_DISMISS' })
  check('dismissing closes the menu', composer() === 'typing')
  check('dismissing keeps the draft', actor.getSnapshot().context.draft === '/clear')
  check('the dismissed menu stays closed', composer() === 'typing')

  actor.send({ type: 'EDIT_DRAFT', text: '/clea' })
  check('typing again reopens the menu', composer() === 'menu')
  actor.stop()
}

{
  // Tab completes into the draft. It does not run the command — Enter does,
  // and only because the completed draft then names one.
  const actor = createActor(sessionMachine, { input: { sessionId: 's9', commandNames: ['/clear', '/retry', '/save', '/effort low', '/effort max', '/model opus-5', '/model sonnet-5'] } }).start()
  actor.send({ type: 'EDIT_DRAFT', text: '/cl' })
  actor.send({ type: 'MENU_MOVE', delta: 1, count: 4 })
  actor.send({ type: 'MENU_COMPLETE', name: '/clear' })

  check('completing writes the command into the draft', actor.getSnapshot().context.draft === '/clear ')
  check('completing resets the highlight', actor.getSnapshot().context.menuIndex === 0)
  check(
    'the trailing space closes the menu',
    regionOf(actor.getSnapshot().value, 'composer') === 'typing',
  )
  check('and a completed command is sendable', actor.getSnapshot().can({ type: 'SEND' }))

  check(
    'a completed draft resolves to its command',
    invokedCommand(actor.getSnapshot().context.draft, ['/clear', '/save']) === '/clear',
  )
  check(
    'a half-typed command resolves to nothing',
    invokedCommand('/cl', ['/clear', '/save']) === null,
  )
  check(
    'ordinary text resolves to nothing',
    invokedCommand('clear the desk', ['/clear']) === null,
  )
  check(
    'arguments do not stop a command resolving',
    invokedCommand('/clear everything', ['/clear']) === '/clear',
  )
  actor.stop()
}

{
  // The composer is its own region: a menu open during a live turn must not
  // touch the turn, and must not become a way to send.
  const actor = createActor(
    sessionMachine.provide({ actors: { runTurn: turnNever() } }),
    { input: { sessionId: 's10', commandNames: ['/clear', '/retry', '/save', '/effort low', '/effort max', '/model opus-5', '/model sonnet-5'] } },
  ).start()

  actor.send({ type: 'EDIT_DRAFT', text: 'go' })
  actor.send({ type: 'SEND' })
  check('a turn is running', regionOf(actor.getSnapshot().value, 'turn') === 'sending')

  actor.send({ type: 'EDIT_DRAFT', text: '/c' })
  check(
    'the menu opens during a live turn',
    regionOf(actor.getSnapshot().value, 'composer') === 'menu',
  )
  check(
    'and the turn is untouched by it',
    regionOf(actor.getSnapshot().value, 'turn') === 'sending',
  )
  check('interrupting is still possible', actor.getSnapshot().can({ type: 'INTERRUPT' }))
  actor.stop()
}

{
  // Clearing is only legal once a turn has settled. Wiping the transcript
  // mid-stream would drop the reply that is still arriving.
  const actor = createActor(
    sessionMachine.provide({ actors: { runTurn: turnNever() } }),
    { input: { sessionId: 's11' } },
  ).start()

  check('an empty session has nothing to clear, but accepts the event', actor.getSnapshot().can({ type: 'CLEAR' }))

  actor.send({ type: 'EDIT_DRAFT', text: 'do a thing' })
  actor.send({ type: 'SEND' })
  check('CLEAR is refused mid-turn', !actor.getSnapshot().can({ type: 'CLEAR' }))

  actor.send({ type: 'INTERRUPT' })
  await waitFor(actor, (s) => regionOf(s.value, 'turn') === 'idle')
  check('CLEAR is possible once the turn settles', actor.getSnapshot().can({ type: 'CLEAR' }))

  actor.send({ type: 'CLEAR' })
  check('clearing empties the transcript', actor.getSnapshot().context.messages.length === 0)
  check('clearing empties the draft', actor.getSnapshot().context.draft === '')
  actor.stop()
}

{
  /*
    The transcript and the count are one act.

    The meter is what the *next* turn starts from, so a CLEAR that emptied the
    screen and left the figure would say the conversation costs eight thousand
    tokens while showing none of them. Both are cleared in the same assign,
    which is what makes them impossible to separate — and the same is true of a
    compaction error left over from before, because "the conversation is
    unchanged" is a claim about a conversation that no longer exists.
  */
  const actor = createActor(sessionMachine.provide({ actors: { runTurn: turnNever() } }), {
    input: {
      sessionId: 's11b',
      messages: [{ id: 'm1', role: 'user', text: 'a long conversation' }],
      tokensUsed: 812_000,
      compactError: 'the rate limit was reached',
    },
  }).start()

  actor.send({ type: 'CLEAR' })
  const cleared = actor.getSnapshot().context
  check('clearing resets the transcript and the count together', cleared.messages.length === 0 && cleared.tokensUsed === 0)
  check('and takes the stale compaction error with it', cleared.compactError === null)
  actor.stop()
}

{
  // Model and effort are settings, not modes: legal at any time, applied to the
  // next turn, and never disturbing a turn already in flight.
  const actor = createActor(
    sessionMachine.provide({ actors: { runTurn: turnNever() } }),
    { input: { sessionId: 's12' } },
  ).start()

  check('a session starts on opus-5', actor.getSnapshot().context.model === 'claude-opus-5')
  check('and at xhigh effort', actor.getSnapshot().context.effort === 'xhigh')

  actor.send({ type: 'SET_MODEL', model: 'claude-haiku-4-5' })
  actor.send({ type: 'SET_EFFORT', effort: 'low' })
  check('the model changes', actor.getSnapshot().context.model === 'claude-haiku-4-5')
  check('the effort changes', actor.getSnapshot().context.effort === 'low')

  actor.send({ type: 'EDIT_DRAFT', text: 'do a thing' })
  actor.send({ type: 'SEND' })
  check('a turn is running', regionOf(actor.getSnapshot().value, 'turn') === 'sending')

  actor.send({ type: 'SET_EFFORT', effort: 'max' })
  check('changing effort mid-turn is accepted', actor.getSnapshot().context.effort === 'max')
  check(
    'and does not disturb the turn',
    regionOf(actor.getSnapshot().value, 'turn') === 'sending',
  )
  actor.stop()
}

{
  // The turn runs on what the session says, not on a default baked into the
  // actor. Asserted by reading the input the actor was handed.
  let seen: { model: string; effort: string } | undefined
  const actor = createActor(
    sessionMachine.provide({
      actors: {
        runTurn: fromPromise<TurnOutput, TurnInput>(async ({ input }) => {
          seen = { model: input.model, effort: input.effort }
          return { text: 'ok', tokensUsed: 42 }
        }),
      },
    }),
    { input: { sessionId: 's13', model: 'claude-sonnet-5', effort: 'medium' } },
  ).start()

  actor.send({ type: 'EDIT_DRAFT', text: 'go' })
  actor.send({ type: 'SEND' })
  await waitFor(actor, (s) => regionOf(s.value, 'turn') === 'idle')

  check('the turn receives the session model', seen !== undefined && seen.model === 'claude-sonnet-5')
  check('the turn receives the session effort', seen !== undefined && seen.effort === 'medium')
  actor.stop()
}

{
  // Command names contain spaces, so resolution takes the longest match. First
  // word would resolve "/effort xhigh" to a bare "/effort" meaning something else.
  const names = ['/clear', '/effort', '/effort xhigh', '/model sonnet-5']
  check('the longest matching name wins', invokedCommand('/effort xhigh', names) === '/effort xhigh')
  check('a partial multi-word draft still matches a name prefix', isCommandDraft('/model son', names))
  check('an unmatched draft does not', !isCommandDraft('/clear everything', names))
  check('a shorter name still resolves alone', invokedCommand('/effort', names) === '/effort')
  check('trailing text does not break the match', invokedCommand('/model sonnet-5 ', names) === '/model sonnet-5')
  check('an unknown value does not resolve', invokedCommand('/effort turbo', names) === '/effort')
}

{
  // Compaction replaces the history with a summary and resets what the
  // conversation costs. Like CLEAR it is only legal on a settled turn.
  const actor = createActor(
    sessionMachine.provide({
      actors: {
        runTurn: fromPromise<TurnOutput, TurnInput>(async () => ({
          text: 'reply',
          tokensUsed: 8_000,
        })),
        compactSession: fromPromise<CompactOutput, CompactInput>(async ({ input }) => ({
          messages: [{ id: 'c', role: 'agent' as const, text: `Summary of ${input.messages.length}` }],
          tokensUsed: 300,
        })),
      },
    }),
    { input: { sessionId: 's14' } },
  ).start()

  actor.send({ type: 'EDIT_DRAFT', text: 'first' })
  actor.send({ type: 'SEND' })
  await waitFor(actor, (s) => regionOf(s.value, 'turn') === 'idle')
  check('a completed turn records what it cost', actor.getSnapshot().context.tokensUsed === 8_000)

  check('compacting is possible once settled', actor.getSnapshot().can({ type: 'COMPACT' }))
  actor.send({ type: 'COMPACT' })
  check('compacting is its own state', regionOf(actor.getSnapshot().value, 'turn') === 'compacting')
  check('and refuses SEND while it runs', !actor.getSnapshot().can({ type: 'SEND' }))

  await waitFor(actor, (s) => regionOf(s.value, 'turn') === 'idle')
  check('compaction replaces the history', actor.getSnapshot().context.messages.length === 1)
  check('and resets the cost', actor.getSnapshot().context.tokensUsed === 300)
  actor.stop()
}

{
  // A failed compaction must leave the conversation alone. Losing the history
  // to a failed summarisation is the one outcome worse than a full context.
  const before = [
    { id: 'm1', role: 'user' as const, text: 'one' },
    { id: 'm2', role: 'agent' as const, text: 'two' },
  ]
  const actor = createActor(
    sessionMachine.provide({
      actors: {
        runTurn: turnNever(),
        compactSession: rejects<CompactOutput, CompactInput>('could not summarise'),
      },
    }),
    { input: { sessionId: 's15', messages: before, tokensUsed: 5_000 } },
  ).start()

  actor.send({ type: 'COMPACT' })
  await waitFor(actor, (s) => regionOf(s.value, 'turn') === 'idle')

  check('a failed compaction keeps the messages', actor.getSnapshot().context.messages.length === 2)
  check('a failed compaction keeps the cost', actor.getSnapshot().context.tokensUsed === 5_000)
  check('and says why', actor.getSnapshot().context.compactError === 'could not summarise')
  actor.stop()
}

{
  /*
    "Unchanged" is checked as identity, not as a count.

    A compaction that built the replacement *in place* and then failed would
    pass every assertion above: two messages, the same cost, an error to show.
    The conversation would still be half-rewritten, and the state would say
    nothing happened. So the messages the Session started with are the exact
    objects it ends with, and the transcript reads word for word as it did.
  */
  const before: Message[] = [
    { id: 'm1', role: 'user', text: 'what does the sandbox deny' },
    { id: 'm2', role: 'agent', text: 'the home directory, and both keychains' },
  ]
  const wording = textsOf(before)

  const { spy, actor: persistSession } = saveSpy(true)
  const actor = createActor(
    sessionMachine.provide({
      actors: {
        runTurn: turnNever(),
        /*
          The mistake, written out. This compaction rewrites the transcript it
          was handed and *then* fails — which is exactly what a future
          implementation that saves an allocation would do, and it is not a
          contrived one: `readonly Message[]` stops the compiler complaining and
          stops nothing at run time.

          It passes every count-based assertion above. The machine is what has
          to make it harmless.
        */
        compactSession: fromPromise<CompactOutput, CompactInput>(async ({ input }) => {
          const rewriting = input.messages as Message[]
          rewriting.splice(0, rewriting.length, { id: 'c1', role: 'agent', text: 'half a summary' })
          throw new Error('the API was overloaded')
        }),
        persistSession,
      },
    }),
    { input: { sessionId: 's15b', messages: before, tokensUsed: 5_000 } },
  ).start()

  actor.send({ type: 'COMPACT' })
  await waitFor(actor, (s) => regionOf(s.value, 'turn') === 'idle')

  const after = actor.getSnapshot().context.messages
  check('a compaction cannot rewrite the transcript in place', after.length === 2)
  check('a failed compaction leaves the transcript word for word', textsOf(after) === wording)
  check('and the messages handed in are untouched too', textsOf(before) === wording)
  check('a failed compaction keeps the cost it could not reduce', actor.getSnapshot().context.tokensUsed === 5_000)

  /*
    And no boundary is raised.

    Compaction is the one Turn boundary that takes the store's *replace* path
    rather than its append path — the transcript it saves is not a prefix of
    what is on disk. A failed compaction that raised SAVE anyway would hand the
    store an unchanged transcript and, being a prefix, it would append nothing;
    but the moment anything about it differed, a compaction that changed
    nothing would rewrite the mirror. The state says nothing happened, so
    nothing is written.
  */
  check('a failed compaction writes nothing to the mirror', spy.calls === 0)
  actor.stop()
}

{
  check('context reads as used over window', formatContext(12_400, 1_000_000) === '12.4k/1M (1%)')
  check('and rounds the percentage', formatContext(500_000, 1_000_000) === '500k/1M (50%)')
  check('a small window still reads correctly', formatContext(20_000, 200_000) === '20k/200k (10%)')
  check('an empty session reads zero', formatContext(0, 1_000_000) === '0/1M (0%)')
}

// ---------------------------------------------------------------------------
// Surface — failure isolation
// ---------------------------------------------------------------------------

{
  const actor = createActor(
    surfaceMachine.provide({ actors: { loadSurface: rejects<{ ok: true }, { modulePath: string }>(brokenSurfaceError) } }),
    { input: { descriptor: seedSurfaces[2]! } },
  ).start()

  await waitFor(actor, (s) => s.matches('failed'))
  check('a failed Surface says why', actor.getSnapshot().context.error === brokenSurfaceError)
  check('a failed Surface can retry', actor.getSnapshot().can({ type: 'RETRY' }))
  actor.stop()
}

{
  const actor = createActor(
    surfaceMachine.provide({ actors: { loadSurface: resolves<{ ok: true }, { modulePath: string }>({ ok: true }) } }),
    { input: { descriptor: seedSurfaces[0]! } },
  ).start()

  await waitFor(actor, (s) => s.matches('loaded'))
  // RETRY exists only on `failed` — the state has no handler, so the affordance
  // cannot drift from the rule.
  check('a loaded Surface refuses RETRY', !actor.getSnapshot().can({ type: 'RETRY' }))

  actor.send({ type: 'UNLOAD' })
  check('an unloaded Surface is final', actor.getSnapshot().status === 'done')
  check('a final Surface accepts nothing', !actor.getSnapshot().can({ type: 'RETRY' }))
  actor.stop()
}

{
  // One broken Surface must not take the others down. This is ADR-0004 as an
  // assertion rather than a promise.
  const actor = createActor(
    harnessMachine.provide({
      actors: {
        surface: surfaceMachine.provide({
          actors: {
            loadSurface: fromPromise<{ ok: true }, { modulePath: string }>(async ({ input }) => {
              if (input.modulePath.includes('broken')) throw new Error(brokenSurfaceError)
              return { ok: true as const }
            }),
          },
        }),
      },
    }),
    { input: { policy: seedPolicy } },
  ).start()

  actor.send({ type: 'DISCOVER_SURFACES', descriptors: seedSurfaces })
  await waitFor(actor, (s) =>
    s.context.surfaces.every((ref) => !ref.getSnapshot().matches('loading')),
  )

  const states = actor.getSnapshot().context.surfaces.map((ref) => ({
    id: ref.getSnapshot().context.descriptor.id,
    value: String(ref.getSnapshot().value),
  }))
  check('three Surfaces were discovered', states.length === 3)
  check('the broken Surface failed', states.find((s) => s.id === 'broken')?.value === 'failed')
  check('its siblings loaded anyway', states.filter((s) => s.value === 'loaded').length === 2)
  check(
    'the Harness is unharmed by a failed Surface',
    regionOf(actor.getSnapshot().value, 'agent') === 'down',
  )

  // Discovery re-runs whenever the Surfaces directory changes. A second scan
  // that finds the same three must not spawn three more actors sharing the
  // same ids. Found by driving the bare page, not here.
  actor.send({ type: 'DISCOVER_SURFACES', descriptors: seedSurfaces })
  check('rediscovering the same Surfaces is idempotent', actor.getSnapshot().context.surfaces.length === 3)

  actor.send({ type: 'UNLOAD_SURFACE', id: 'broken' })
  check('unloading removes it from the parent', actor.getSnapshot().context.surfaces.length === 2)

  // ...and an unloaded Surface can be discovered again.
  actor.send({ type: 'DISCOVER_SURFACES', descriptors: seedSurfaces })
  check('an unloaded Surface can be rediscovered', actor.getSnapshot().context.surfaces.length === 3)
  actor.stop()
}

// ---------------------------------------------------------------------------
// The states page — coverage, and that every card is what it claims
// ---------------------------------------------------------------------------

{
  check('every declared state has a scenario', uncoveredPaths().length === 0)
  check('no scenario claims a state no machine declares', unknownPaths().length === 0)

  // The list being complete is worth little on its own: a scenario that names
  // `turn.failed` and lands in `turn.idle` would still count. So each one is
  // created cold, with the same frozen build the page uses, and asked where it
  // actually is.
  for (const scenario of SCENARIOS) {
    const actor = createActor(frozenHarness(), { input: scenario.input }).start()
    const snap = actor.getSnapshot()
    const session = snap.context.session

    const reached = new Set<string>()
    for (const [region, value] of Object.entries(snap.value as Record<string, unknown>)) {
      reached.add(`${region}.${String(value)}`)
    }
    if (session) {
      for (const [region, value] of Object.entries(
        session.getSnapshot().value as Record<string, unknown>,
      )) {
        reached.add(`${region}.${String(value)}`)
      }
    }

    for (const path of scenario.covers) {
      check(`scenario "${scenario.id}" actually reaches ${path}`, reached.has(path))
    }
    actor.stop()
  }

  // Frozen means frozen. A card parked mid-flight must still be there after the
  // event loop has had its chance — an actor that resolves would rewrite the
  // state the card is captioned with.
  const sending = SCENARIOS.find((s) => s.id === 'sending')!
  const actor = createActor(frozenHarness(), { input: sending.input }).start()
  await new Promise((r) => setTimeout(r, 50))
  check(
    'a frozen card does not advance on its own',
    String(actor.getSnapshot().context.session?.getSnapshot().value.turn) === 'sending',
  )
  actor.stop()
}

// ---------------------------------------------------------------------------
// The Core/Userspace boundary — ADR-0004, enforced rather than promised
// ---------------------------------------------------------------------------

{
  /*
    Core must never statically import Userspace.

    A React error boundary catches a render error and does nothing about a build
    error: a static import of a Userspace module that does not compile takes the
    whole bundle down, and the next launch is a blank window with no chat — no
    transcript, and no way to ask for the fix.

    ADR-0004 says this is "enforced by lint, not by discipline". There is no
    linter in this repo yet, and an ADR nothing checks is a promise. This is the
    cheapest thing that makes it true today; a lint rule can replace it later
    without changing what is being asserted.
  */
  const root = new URL('../src/', import.meta.url).pathname
  const files: string[] = []
  const walk = (dir: string) => {
    for (const entry of readdirSync(dir, { withFileTypes: true })) {
      const full = `${dir}${entry.name}`
      if (entry.isDirectory()) walk(`${full}/`)
      else if (/\.tsx?$/.test(entry.name)) files.push(full)
    }
  }
  walk(root)

  check('Core has source files to check', files.length > 0)

  // `import(...)` is how a Surface is meant to load, so only the static form is
  // a violation — matched at the start of a line, which is where it must be.
  const staticImport = /^\s*import\s[^\n]*from\s+['"][^'"]*userspace[^'"]*['"]/m
  const offenders = files.filter((file) => staticImport.test(readFileSync(file, 'utf-8')))
  check(
    `Core statically imports no Userspace module (found: ${offenders.length})`,
    offenders.length === 0,
  )
}

// ---------------------------------------------------------------------------
// Session — the real Turn actor changes nothing about the machine
// ---------------------------------------------------------------------------

/**
 * Every state the turn region passed through, in order.
 *
 * The claim being tested is negative — swapping the implementation changes no
 * state, guard or transition — and a negative claim about a machine is only
 * checkable by running the same script twice and comparing what it did.
 */
async function turnPath(
  runTurn: ReturnType<typeof fromPromise<TurnOutput, TurnInput>>,
  sessionId: string,
): Promise<{ path: string[]; messages: string; tokens: number }> {
  const path: string[] = []
  const actor = createActor(sessionMachine.provide({ actors: { runTurn } }), {
    input: { sessionId },
  })
  actor.subscribe((snapshot) => {
    const turn = regionOf(snapshot.value, 'turn')
    if (path.at(-1) !== turn) path.push(turn)
  })
  actor.start()

  actor.send({ type: 'EDIT_DRAFT', text: 'go' })
  actor.send({ type: 'SEND' })
  actor.send({ type: 'STREAM_DELTA', text: 'wor' })
  actor.send({ type: 'STREAM_DELTA', text: 'king' })
  await waitFor(actor, (s) => regionOf(s.value, 'turn') === 'idle')

  const snapshot = actor.getSnapshot()
  actor.stop()
  return {
    path,
    messages: snapshot.context.messages.map((m) => `${m.role}:${m.text}`).join('|'),
    tokens: snapshot.context.tokensUsed,
  }
}

{
  /*
    The binary criterion the ticket ends on: if wiring the Agent SDK in changed
    a state, a guard or a transition, the model was wrong and the change belongs
    back in the machine stage rather than here.

    Both actors below settle the same way from the machine's side — one after a
    tick, one after a delay, with different text and different token counts —
    and the machine must not be able to tell them apart.
  */
  const echo = fromPromise<TurnOutput, TurnInput>(async ({ input }) => ({
    text: `Acknowledged: ${input.prompt}`,
    tokensUsed: 240,
  }))
  const streamed = fromPromise<TurnOutput, TurnInput>(async () => {
    await new Promise((resolve) => setTimeout(resolve, 5))
    return { text: 'working', tokensUsed: 9_512 }
  })

  const seeded = await turnPath(echo, 'x1')
  const live = await turnPath(streamed, 'x2')

  check('a turn walks sending → streaming → idle', seeded.path.join('→') === 'idle→sending→streaming→idle')
  check('swapping the turn actor changes no state and no transition', seeded.path.join('→') === live.path.join('→'))
  check(
    'the transcript shape is the actor-independent part',
    seeded.messages.startsWith('user:go|agent:') && live.messages.startsWith('user:go|agent:'),
  )
  check('and what the actor answered is the only thing that differs', seeded.messages !== live.messages)
  check('a real token count reaches the meter unchanged', live.tokens === 9_512)
}

{
  /*
    The same claim, checked structurally rather than by running it.

    Comparing two runs catches a machine whose *path* depends on the actor,
    which is the weaker half. The stronger half is that no state, guard or
    transition was added at all — and the way to check that is to write down
    what each turn state accepts and let the build fail when it changes. A guard
    relaxed to let the live actor through, an event added so a delta could
    arrive somewhere new, a state split: each one moves a name in this list.

    If this fails, the honest response is not to update the literal. It is that
    the model changed, and a model change belongs back in the machine stage.
  */
  const everyEvent: SessionEvent[] = [
    { type: 'EDIT_DRAFT', text: 'go' },
    { type: 'SEND' },
    { type: 'STREAM_DELTA', text: 'x' },
    { type: 'INTERRUPT' },
    { type: 'RETRY_TURN' },
    { type: 'DISMISS_TURN_ERROR' },
    { type: 'SAVE' },
    { type: 'RETRY_SAVE' },
    { type: 'MENU_MOVE', delta: 1, count: 1 },
    { type: 'MENU_COMPLETE', name: '/clear' },
    { type: 'MENU_DISMISS' },
    { type: 'CLEAR' },
    { type: 'SET_MODEL', model: 'claude-opus-5' },
    { type: 'SET_EFFORT', effort: 'low' },
    { type: 'SET_COMMANDS', names: [] },
    { type: 'COMPACT' },
  ]

  const accepts = (actor: ReturnType<typeof createActor<typeof sessionMachine>>) =>
    everyEvent
      .filter((event) => actor.getSnapshot().can(event))
      .map((event) => event.type)
      .join(' ')

  const at = new Map<string, string>()

  {
    const actor = createActor(sessionMachine.provide({ actors: { runTurn: turnNever() } }), {
      input: { sessionId: 'x6', draft: 'go' },
    }).start()
    at.set('idle', accepts(actor))
    actor.send({ type: 'SEND' })
    at.set('sending', accepts(actor))
    actor.send({ type: 'STREAM_DELTA', text: 'partial' })
    at.set('streaming', accepts(actor))
    actor.send({ type: 'INTERRUPT' })
    at.set('interrupting', accepts(actor))
    actor.stop()
  }

  {
    const actor = createActor(
      sessionMachine.provide({ actors: { runTurn: rejects<TurnOutput, TurnInput>('no') } }),
      { input: { sessionId: 'x7', draft: 'go' } },
    ).start()
    actor.send({ type: 'SEND' })
    await waitFor(actor, (s) => regionOf(s.value, 'turn') === 'failed')
    // The draft was consumed by sending, and SEND is guarded on having one.
    actor.send({ type: 'EDIT_DRAFT', text: 'go' })
    at.set('failed', accepts(actor))
    actor.stop()
  }

  {
    const actor = createActor(
      sessionMachine.provide({
        actors: { runTurn: turnNever(), compactSession: never<CompactOutput, CompactInput>() },
      }),
      { input: { sessionId: 'x8', messages: [{ id: 'm1', role: 'user', text: 'one' }] } },
    ).start()
    actor.send({ type: 'COMPACT' })
    at.set('compacting', accepts(actor))
    actor.stop()
  }

  check(
    'idle accepts what idle has always accepted',
    at.get('idle') === 'EDIT_DRAFT SEND SAVE CLEAR SET_MODEL SET_EFFORT SET_COMMANDS COMPACT',
  )
  check(
    'sending accepts a delta and an interrupt, and nothing else new',
    at.get('sending') ===
      'EDIT_DRAFT STREAM_DELTA INTERRUPT SAVE SET_MODEL SET_EFFORT SET_COMMANDS',
  )
  check(
    'streaming accepts exactly the same, which is why a delta needed no new state',
    at.get('streaming') === at.get('sending'),
  )
  check(
    'interrupting accepts nothing new, not even another interrupt',
    at.get('interrupting') === 'EDIT_DRAFT SAVE SET_MODEL SET_EFFORT SET_COMMANDS',
  )
  check(
    'turn-failed offers retry and dismiss, and the two settled commands',
    at.get('failed') ===
      'EDIT_DRAFT RETRY_TURN DISMISS_TURN_ERROR SAVE CLEAR SET_MODEL SET_EFFORT SET_COMMANDS COMPACT',
  )
  check(
    'compacting refuses everything a running turn refuses, including another compaction',
    at.get('compacting') === 'EDIT_DRAFT SAVE SET_MODEL SET_EFFORT SET_COMMANDS',
  )
  check(
    'a compaction cannot be interrupted, so nothing may offer to',
    at.get('compacting')?.includes('INTERRUPT') === false,
  )
  check('the composer and the model are legal in every turn state', [...at.values()].every((set) => set.startsWith('EDIT_DRAFT') && set.includes('SET_MODEL')))
  check('every turn state the harness realizes was reached to be measured', at.size === 6)
}

{
  /*
    A model changed mid-turn belongs to the *next* turn. The existing assertion
    covers half of that — the turn in flight is not disturbed — and this is the
    other half, which nothing checked: the next turn actually runs on the new
    value rather than on the one the session started with.
  */
  const seen: string[] = []
  const actor = createActor(
    sessionMachine.provide({
      actors: {
        runTurn: fromPromise<TurnOutput, TurnInput>(async ({ input }) => {
          seen.push(`${input.model}/${input.effort}`)
          return { text: 'ok', tokensUsed: 1 }
        }),
      },
    }),
    { input: { sessionId: 'x3' } },
  ).start()

  actor.send({ type: 'EDIT_DRAFT', text: 'one' })
  actor.send({ type: 'SEND' })
  actor.send({ type: 'SET_MODEL', model: 'claude-haiku-4-5' })
  actor.send({ type: 'SET_EFFORT', effort: 'low' })
  await waitFor(actor, (s) => regionOf(s.value, 'turn') === 'idle')

  actor.send({ type: 'EDIT_DRAFT', text: 'two' })
  actor.send({ type: 'SEND' })
  await waitFor(actor, (s) => regionOf(s.value, 'turn') === 'idle' && seen.length === 2)

  check('the turn in flight keeps what it was started with', seen[0] === 'claude-opus-5/xhigh')
  check('and the change applies to the next turn', seen[1] === 'claude-haiku-4-5/low')
  check('a change mid-turn does not re-run the turn', seen.length === 2)
  actor.stop()
}

{
  /*
    The composer stays live for the whole of a turn, not only while it is
    `sending`. Streaming is where a developer actually watches an answer arrive
    and decides to queue the next instruction, and it is a different state with
    its own `on` block — so it is a different fact and gets its own assertion.
  */
  const actor = createActor(sessionMachine.provide({ actors: { runTurn: turnNever() } }), {
    input: { sessionId: 'x4', commandNames: ['/clear'] },
  }).start()

  actor.send({ type: 'EDIT_DRAFT', text: 'go' })
  actor.send({ type: 'SEND' })
  actor.send({ type: 'STREAM_DELTA', text: 'half an ans' })
  check('the turn is streaming', regionOf(actor.getSnapshot().value, 'turn') === 'streaming')

  actor.send({ type: 'EDIT_DRAFT', text: 'the next instruction' })
  check('the composer accepts a draft mid-stream', actor.getSnapshot().context.draft === 'the next instruction')
  check('and the turn is untouched', regionOf(actor.getSnapshot().value, 'turn') === 'streaming')
  check('and the partial is untouched', actor.getSnapshot().context.partial === 'half an ans')

  actor.send({ type: 'EDIT_DRAFT', text: '/c' })
  check('the menu opens mid-stream too', regionOf(actor.getSnapshot().value, 'composer') === 'menu')
  actor.stop()
}

{
  /*
    Tool calls are transcript, not decoration. They reach the machine as
    `STREAM_DELTA` like any other text, which is what puts them in the partial
    and therefore in the message an interrupt keeps — the audit trail surviving
    a turn the developer stopped is the case that matters.
  */
  const actor = createActor(
    sessionMachine.provide({ actors: { runTurn: turnNever() }, delays: { interruptGrace: 1 } }),
    { input: { sessionId: 'x5' } },
  ).start()

  actor.send({ type: 'EDIT_DRAFT', text: 'read the file' })
  actor.send({ type: 'SEND' })
  actor.send({ type: 'STREAM_DELTA', text: '⚙ Read(src/a.ts)\n' })
  actor.send({ type: 'STREAM_DELTA', text: 'It says hello.' })
  actor.send({ type: 'INTERRUPT' })
  await waitFor(actor, (s) => regionOf(s.value, 'turn') === 'idle')

  const kept = actor.getSnapshot().context.messages.at(-1)?.text ?? ''
  check('an interrupted turn keeps the tool calls it made', kept.includes('Read(src/a.ts)'))
  check('and the words that followed them', kept.includes('It says hello.'))
}

{
  // The honest answer to "what does this build actually do". A wired actor that
  // stayed on the list would keep the seeded marker claiming a real turn is
  // fake; one that left it while still throwing would claim the opposite.
  check('the turn actor is no longer listed as unimplemented', !UNIMPLEMENTED.includes('runTurn'))
  check(
    'the plan-usage actor is no longer listed as unimplemented',
    !UNIMPLEMENTED.includes('readSubscriptionUsage'),
  )
  check('the compaction actor is no longer listed as unimplemented', !UNIMPLEMENTED.includes('compactSession'))
  check('every unimplemented name is a real actor', UNIMPLEMENTED.every((name) => (ACTOR_NAMES as readonly string[]).includes(name)))
}

// ---------------------------------------------------------------------------
// Plan usage — a figure, or the last one there was
// ---------------------------------------------------------------------------

/*
  The product rule that outlives whatever is behind the read: the strip renders
  beside the words "plan usage", so a number there was measured or there is no
  number. The Harness parses and refuses; the machine keeps or replaces. These
  drive the machine half, which nothing was asserting.
*/

type Usage = { fiveHourPct: number; weeklyPct: number; source: 'live' | 'seeded' }

{
  const actor = createActor(
    harnessMachine.provide({
      actors: {
        readSubscriptionUsage: resolves<Usage, Record<string, never>>({
          fiveHourPct: 11,
          weeklyPct: 54,
          source: 'live',
        }),
      },
    }),
    { input: { policy: seedPolicy } },
  ).start()

  check('plan usage starts unread', regionOf(actor.getSnapshot().value, 'subscription') === 'unread')
  check('and with nothing to show', actor.getSnapshot().context.subscription === null)

  actor.send({ type: 'READ_SUBSCRIPTION' })
  await waitFor(actor, (s) => regionOf(s.value, 'subscription') === 'read')
  check(
    'a successful read is what the actor measured',
    actor.getSnapshot().context.subscription?.fiveHourPct === 11,
  )
  check(
    'and says where it came from, so the surface never has to guess',
    actor.getSnapshot().context.subscription?.source === 'live',
  )
  actor.stop()
}

{
  // The criterion in full: a failed read leaves whatever was last known, and
  // what was last known may be nothing.
  const actor = createActor(
    harnessMachine.provide({
      actors: { readSubscriptionUsage: rejects<Usage, Record<string, never>>('no session to ask') },
    }),
    { input: { policy: seedPolicy } },
  ).start()

  actor.send({ type: 'READ_SUBSCRIPTION' })
  await waitFor(actor, (s) => regionOf(s.value, 'subscription') === 'unread')
  check(
    'a failed first read invents nothing at all',
    actor.getSnapshot().context.subscription === null,
  )
  actor.stop()
}

{
  // The other half, and the one a default would break silently: a read that
  // fails after a good one must not blank it or replace it with a plausible
  // zero. The strip keeps showing the last measurement.
  const actor = createActor(
    harnessMachine.provide({
      actors: { readSubscriptionUsage: rejects<Usage, Record<string, never>>('the agent stopped') },
    }),
    {
      input: {
        policy: seedPolicy,
        subscription: { fiveHourPct: 11, weeklyPct: 54, source: 'live' },
        enterSubscription: 'read',
      },
    },
  ).start()

  actor.send({ type: 'READ_SUBSCRIPTION' })
  await waitFor(actor, (s) => regionOf(s.value, 'subscription') === 'unread')
  const kept = actor.getSnapshot().context.subscription
  check('a failed read leaves the last measurement standing', kept?.fiveHourPct === 11)
  check('all of it, not the half that was easy to keep', kept?.weeklyPct === 54)
  check('still labelled as the measurement it was', kept?.source === 'live')
  actor.stop()
}

// ---------------------------------------------------------------------------
// Compaction — building the replacement, and only then swapping
// ---------------------------------------------------------------------------

{
  /*
    The replacement transcript is a value, not an edit.

    `compactedTranscript` is the whole of what a successful Compaction does to
    the conversation, and it is a pure function of what came before and the
    summary the Session produced. Nothing about it can half-happen.
  */
  const before: Message[] = [
    { id: 'm1', role: 'user', text: 'what does the sandbox deny' },
    { id: 'm2', role: 'agent', text: 'the home directory, and both keychains' },
  ]
  const wording = textsOf(before)
  const after = compactedTranscript(before, 'The developer asked about the sandbox policy.')

  check('a compaction replaces the history with one message', after.length === 1)
  check('and that message is the summary the Session produced', after[0]!.text.includes('The developer asked about the sandbox policy.'))
  check('a summary is marked as one, so it does not read as an answer', after[0]!.text.startsWith('⟲'))
  check('and the mark names what it replaced, which the transcript no longer shows', after[0]!.text.includes('2 earlier messages'))
  check('the summary is the agent speaking, because the model wrote it', after[0]!.role === 'agent')
  check('the replacement is a new array', after !== (before as readonly Message[]))
  check('and building it changes nothing about what came before', textsOf(before) === wording)
  check(
    'the next message after a compaction does not collide with the summary',
    after[0]!.id !== `m${after.length + 1}`,
  )
}

{
  /*
    The live actor, against a host that answers — the only place Core's half of
    a Compaction can be driven without a Claude Code process anywhere.

    `tauriHarnessBridge()` reads `__TAURI_INTERNALS__`, which is the same seam
    the real app arrives through, so this exercises the actor exactly as it
    runs. Nothing here starts a session: the actor's whole job is to put a
    `compact-session` on the bridge and read events back.
  */
  const realInternals = (globalThis as Record<string, unknown>).__TAURI_INTERNALS__
  let queued: unknown = null
  const asked: string[] = []
  ;(globalThis as Record<string, unknown>).__TAURI_INTERNALS__ = {
    invoke: async (_command: string, payload: { request: { kind: string } }) => {
      const kind = payload.request.kind
      asked.push(kind)
      if (kind === 'compact-session') return { ok: true }
      if (kind === 'next-turn-event') {
        const event = queued
        queued = null
        return { event }
      }
      throw { failure: 'malformed' }
    },
  }

  const before: Message[] = [
    { id: 'm1', role: 'user', text: 'what does the sandbox deny' },
    { id: 'm2', role: 'agent', text: 'the home directory, and both keychains' },
  ]
  const wording = textsOf(before)

  const compact = liveActors().compactSession
  const run = (input: CompactInput) =>
    new Promise<{ output?: CompactOutput; error?: unknown }>((resolve) => {
      const actor = createActor(compact, { input })
      actor.subscribe({
        next: (snapshot) => {
          if (snapshot.status === 'done') resolve({ output: snapshot.output as CompactOutput })
        },
        error: (error) => resolve({ error }),
      })
      actor.start()
    })

  queued = { kind: 'compacted', turnId: 'turn-1', summary: 'so far: the sandbox', tokensUsed: 4_000 }
  const done = await run({ sessionId: 'live-1', messages: before, model: 'claude-opus-5' })
  check('the live compaction asks the confined session and nothing else', asked.every((kind) => kind === 'compact-session' || kind === 'next-turn-event'))
  check('a live compaction answers with the replacement transcript', done.output?.messages.length === 1)
  check('and with what the context now measures, not an estimate', done.output?.tokensUsed === 4_000)
  check('the live compaction leaves the transcript it was given alone', textsOf(before) === wording)

  queued = { kind: 'failed', turnId: 'turn-2', failure: 'overloaded' }
  const failed = await run({ sessionId: 'live-1', messages: before, model: 'claude-opus-5' })
  check('a live compaction that failed throws rather than answering', failed.output === undefined)
  check(
    'and reads as a clause inside the sentence the surface owns',
    failed.error instanceof Error && failed.error.message === compactionFailureMessage('overloaded'),
  )
  check('a failed live compaction leaves the transcript untouched', textsOf(before) === wording)

  if (realInternals === undefined) delete (globalThis as Record<string, unknown>).__TAURI_INTERNALS__
  else (globalThis as Record<string, unknown>).__TAURI_INTERNALS__ = realInternals
}

// ---------------------------------------------------------------------------
// Surface briefs — a state is named in exactly one place
// ---------------------------------------------------------------------------

{
  /*
    The brief says who arrives and what the surface is for. The machines say
    which states exist. When a brief starts enumerating states it is writing the
    same fact somewhere nothing keeps current: the machines change, the exported
    path list changes with them, the states page goes amber, and the brief stays
    wrong and confident.

    Ranges are welcome — how long a transcript runs, how big a tool output gets.
    Those are content facts a builder needs before any machine exists.

    Pointing at the route is fine. `#/states` is a pointer, not a copy.
  */
  const dir = new URL('../../../.impeccable/surfaces/', import.meta.url).pathname
  const banned = [...HARNESS_STATE_PATHS, ...SESSION_STATE_PATHS, ...SURFACE_STATE_PATHS.map((p) => `surface.${p}`)]

  let briefs: string[] = []
  try {
    briefs = readdirSync(dir).filter((name) => name.endsWith('.md'))
  } catch {
    briefs = []
  }

  check('at least one surface brief exists', briefs.length > 0)

  for (const name of briefs) {
    const text = readFileSync(`${dir}${name}`, 'utf-8')
    const named = banned.filter((path) => text.includes(path))
    check(`${name} names no machine state (found: ${named.join(', ') || 'none'})`, named.length === 0)
    check(
      `${name} has no states section`,
      !/^#+\s.*\bstates?\b/im.test(text.replace(/#\/states/g, 'the states page')),
    )
  }
}

// ---------------------------------------------------------------------------

console.log(`\n${passed} assertions passed`)
if (failures.length > 0) {
  console.error(`${failures.length} FAILED:`)
  for (const f of failures) console.error(`  ✗ ${f}`)
  process.exit(1)
}
console.log('all green — UI may begin\n')
