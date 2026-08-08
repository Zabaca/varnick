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
import { sessionMachine, SESSION_STATE_PATHS } from '../src/machines/session.ts'
import { surfaceMachine, SURFACE_STATE_PATHS } from '../src/machines/surface.ts'
import {
  regionOf,
  canStartAgent,
  invokedCommand,
  isCommandDraft,
  formatContext,
} from '../src/domain.ts'
import { seedPolicy, seedSurfaces, brokenSurfaceError } from '../src/data/seed.ts'
import { SCENARIOS, uncoveredPaths, unknownPaths } from '../src/data/scenarios.ts'
import { frozenHarness } from '../src/actors/frozen.ts'
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
