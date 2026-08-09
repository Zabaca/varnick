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
import { mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { createActor, fromPromise, waitFor } from 'xstate'
import { harnessMachine, HARNESS_STATE_PATHS } from '../src/machines/harness.ts'
import { sessionMachine, SESSION_STATE_PATHS, type SessionEvent } from '../src/machines/session.ts'
import {
  surfaceMachine,
  SURFACE_STATE_PATHS,
  SURFACE_UNCARDED_STATE_PATHS,
} from '../src/machines/surface.ts'
import {
  regionOf,
  canStartAgent,
  compactedTranscript,
  invokedCommand,
  isCommandDraft,
  formatContext,
} from '../src/domain.ts'
import { compactionFailureMessage, parseControlRequest } from '@varnick/harness/turn'
import { credentialMintGuidance } from '@varnick/harness/credentials'
import { describeSecretsForAgent, openSecretsStore } from '@varnick/harness/secrets'
import { answerHarnessLine, type HarnessCapabilities } from '@varnick/harness/runtime'
import { hostSecretResolution } from '@varnick/harness/secret-resolution'
import { createSessionStore } from '@varnick/harness/session'
import { liveActors } from '../src/actors/live.ts'
import { discoverFrom, importSurface } from '../src/surfaces.ts'
import { seedPolicy, seedSurfaces, brokenSurfaceError } from '../src/data/seed.ts'
import { SCENARIOS, uncoveredPaths, unknownPaths } from '../src/data/scenarios.ts'
import { frozenHarness } from '../src/actors/frozen.ts'
import { ACTOR_NAMES, UNIMPLEMENTED, seededDetail } from '../src/actors/index.ts'
import type {
  CredentialReading,
  Effort,
  Message,
  ModelId,
  SandboxPolicy,
} from '../src/domain.ts'

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
        readCredential: resolves<CredentialReading, Record<string, never>>({ source: 'keychain', kind: 'api-key' }),
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
  /*
    A credential has a kind, and `credential.present` carries it.

    No new state — ADR-0011 adds a fact to a state rather than a state. The
    reason it is a machine fact at all: the kind decides whether there is a plan
    for plan usage to be about, and a region that reads it off a component would
    be reading it somewhere the states page cannot park.
  */
  for (const kind of ['api-key', 'subscription'] as const) {
    const actor = createActor(
      harnessMachine.provide({
        actors: {
          readCredential: resolves<CredentialReading, Record<string, never>>({
            source: 'keychain',
            kind,
          }),
        },
      }),
      { input: { policy: seedPolicy } },
    ).start()

    check(`a ${kind} credential starts with no kind known`, actor.getSnapshot().context.credentialKind === null)

    actor.send({ type: 'READ_CREDENTIAL' })
    await waitFor(actor, (s) => regionOf(s.value, 'credential') === 'present')
    check(
      `a ${kind} reading carries its kind into context`,
      actor.getSnapshot().context.credentialKind === kind,
    )
    actor.stop()
  }
}

{
  // A read that failed leaves no kind behind. Otherwise a credential that was
  // read once and then removed would leave the previous kind standing, and the
  // decisions the kind drives would be made about a credential that is gone.
  const actor = createActor(
    harnessMachine.provide({
      actors: {
        readCredential: resolves<CredentialReading, Record<string, never>>({
          source: 'env',
          kind: 'subscription',
        }),
      },
    }),
    { input: { policy: seedPolicy } },
  ).start()

  actor.send({ type: 'READ_CREDENTIAL' })
  await waitFor(actor, (s) => regionOf(s.value, 'credential') === 'present')
  check('a subscription read from the environment is still a subscription', actor.getSnapshot().context.credentialKind === 'subscription')
  actor.stop()

  const failing = createActor(
    harnessMachine.provide({
      actors: { readCredential: rejects<CredentialReading, Record<string, never>>('nothing is stored') },
    }),
    { input: { policy: seedPolicy, credentialKind: 'subscription' } },
  ).start()
  failing.send({ type: 'READ_CREDENTIAL' })
  await waitFor(failing, (s) => regionOf(s.value, 'credential') === 'absent')
  check('a failed read leaves no kind standing', failing.getSnapshot().context.credentialKind === null)
  failing.stop()
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
        readCredential: resolves<CredentialReading, Record<string, never>>({
          source: 'keychain',
          kind: 'api-key',
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
        readCredential: resolves<CredentialReading, Record<string, never>>({ source: 'keychain', kind: 'api-key' }),
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
        readCredential: resolves<CredentialReading, Record<string, never>>({ source: 'keychain', kind: 'api-key' }),
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
        readCredential: resolves<CredentialReading, Record<string, never>>({
          source: 'keychain',
          kind: 'api-key',
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

{
  /*
    The runtime's self-report: kept while there is a process, gone with it.

    The second half is the one worth a test. A report describes a running Claude
    Code process, so one left standing after the agent died would be the panel
    confidently describing something that is not there — which is the exact
    failure the report exists to catch, one level up.

    Also asserted here: the report is accepted before `agent.running`. It is read
    off the Session's message stream and replayed at the start of a Turn, so it
    can arrive at a moment this region has no opinion about, and a transition
    scoped to one state would drop the only report a Session sends.
  */
  const report = {
    claudeCodeVersion: '2.1.0',
    model: 'claude-opus-5',
    permissionMode: 'bypassPermissions',
    outputStyle: 'default',
    cwd: '/tmp/clone',
    apiKeySource: 'ANTHROPIC_API_KEY',
    tools: ['Read', 'Bash'],
    skills: [],
    slashCommands: [],
    agents: [],
    mcpServers: [],
    plugins: [],
  }

  const actor = createActor(
    harnessMachine.provide({
      actors: {
        readCredential: resolves<CredentialReading, Record<string, never>>({
          source: 'keychain',
          kind: 'api-key',
        }),
        checkSandbox: resolves<{ ok: true }, { policy: SandboxPolicy }>({ ok: true }),
        spawnAgent: resolves<{ pid: number }, { policy: SandboxPolicy }>({ pid: 99 }),
      },
    }),
    { input: { policy: seedPolicy } },
  ).start()

  check('nothing is reported before an agent runs', actor.getSnapshot().context.runtime === null)
  actor.send({ type: 'RUNTIME_REPORTED', report })
  check(
    'a report is accepted with the agent down',
    actor.getSnapshot().context.runtime?.model === 'claude-opus-5',
  )

  actor.send({ type: 'READ_CREDENTIAL' })
  await waitFor(actor, (s) => regionOf(s.value, 'credential') === 'present')
  actor.send({ type: 'CHECK_SANDBOX' })
  await waitFor(actor, (s) => regionOf(s.value, 'sandbox') === 'available')
  actor.send({ type: 'START' })
  await waitFor(actor, (s) => regionOf(s.value, 'agent') === 'running')

  actor.send({ type: 'RUNTIME_REPORTED', report: { ...report, model: 'claude-sonnet-5' } })
  check(
    'a later report replaces the earlier one',
    actor.getSnapshot().context.runtime?.model === 'claude-sonnet-5',
  )

  actor.send({ type: 'AGENT_EXIT', detail: 'The agent process exited with code 71.' })
  check(
    'a crashed agent takes its report with it',
    actor.getSnapshot().context.runtime === null,
  )

  actor.send({ type: 'RESTART' })
  await waitFor(actor, (s) => regionOf(s.value, 'agent') === 'running')
  actor.send({ type: 'RUNTIME_REPORTED', report })
  actor.send({ type: 'STOP' })
  check(
    'a deliberate stop clears the report too',
    actor.getSnapshot().context.runtime === null,
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
  check('a delta moves the turn to streaming', regionOf(actor.getSnapshot().value, 'turn') === 'answering.streaming')
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
  // `can({ type: 'EDIT_DRAFT' })` used to stand here and could not fail — the
  // event is handled unconditionally at the root, so it is true in every state
  // of every Session. `SEND` is the one that is gated: `turn.idle` plus a draft.
  // That is what "still sendable" was trying to say.
  actor.send({ type: 'EDIT_DRAFT', text: 'still typing' })
  check('the transcript is still sendable while a save is failing', actor.getSnapshot().can({ type: 'SEND' }))
  actor.send({ type: 'EDIT_DRAFT', text: '' })

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
  check('a save can fail while a turn streams', regionOf(actor.getSnapshot().value, 'turn') === 'answering.streaming')
  check('a failed save does not cancel the turn in flight', actor.getSnapshot().context.partial === 'arriving')
  check('a failed save is not a failed turn', actor.getSnapshot().context.turnError === null)
  check('a failed save leaves the turn interruptible', actor.getSnapshot().can({ type: 'INTERRUPT' }))

  const before = actor.getSnapshot().context.messages
  actor.send({ type: 'RETRY_SAVE' })
  await waitFor(actor, (s) => regionOf(s.value, 'persistence') === 'saved')
  check('retrying the save leaves the turn streaming', regionOf(actor.getSnapshot().value, 'turn') === 'answering.streaming')
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
        readCredential: resolves<CredentialReading, Record<string, never>>({ source: 'keychain', kind: 'api-key' }),
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
  // Same substitution as above, and here it buys a second assertion: an empty
  // draft is refused, so "can be talked to" is a fact about the guard rather
  // than about an event the root always accepts.
  check('a resumed Session refuses a send with nothing typed', !session!.getSnapshot().can({ type: 'SEND' }))

  // The reason a restore has to be read before a Session runs on that id: the
  // next save has to *extend* the mirror. A Session that started empty over a
  // transcript that is not empty would rewrite the file instead.
  session!.send({ type: 'EDIT_DRAFT', text: 'carry on' })
  check('a resumed Session can be talked to immediately', session!.getSnapshot().can({ type: 'SEND' }))
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
  check('a turn is running', regionOf(actor.getSnapshot().value, 'turn') === 'answering.sending')

  actor.send({ type: 'EDIT_DRAFT', text: '/c' })
  check(
    'the menu opens during a live turn',
    regionOf(actor.getSnapshot().value, 'composer') === 'menu',
  )
  check(
    'and the turn is untouched by it',
    regionOf(actor.getSnapshot().value, 'turn') === 'answering.sending',
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
  check('a turn is running', regionOf(actor.getSnapshot().value, 'turn') === 'answering.sending')

  actor.send({ type: 'SET_EFFORT', effort: 'max' })
  check('changing effort mid-turn is accepted', actor.getSnapshot().context.effort === 'max')
  check(
    'and does not disturb the turn',
    regionOf(actor.getSnapshot().value, 'turn') === 'answering.sending',
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
// Surfaces — discovery, and what the loader does with what it finds
//
// Both halves of ticket 14's execution path, at the only seam that has no
// browser in it. `discoverFrom` and `importSurface` take the module record as an
// argument precisely so this script can hand them one: in the app that record
// comes from Vite's filesystem scan, and here it is a literal, which is what
// makes "a module that does not compile" testable without shipping one.
// ---------------------------------------------------------------------------

{
  // Nothing found is not a failure. A fresh clone with no Surfaces is a running
  // varnick with a chat in it, which is the whole point of ADR-0004.
  check('an empty Userspace discovers no Surfaces', discoverFrom({}).descriptors.length === 0)

  const ok = async () => ({ default: () => null })
  const found = discoverFrom({
    '../../../userspace/surfaces/runs/index.tsx': ok,
    '../../../userspace/surfaces/recent-notes/index.tsx': ok,
  })

  check('every Surface directory is a Surface', found.descriptors.length === 2)
  check(
    'the directory name is the id — nothing is registered anywhere',
    found.descriptors.map((d) => d.id).join(',') === 'recent-notes,runs',
  )
  check(
    'the name is derived from the directory too',
    found.descriptors.map((d) => d.name).join(',') === 'Recent notes,Runs',
  )
  check(
    'a descriptor names a file a developer can open',
    found.descriptors[1]!.modulePath === 'packages/userspace/surfaces/runs/index.tsx',
  )

  // The glob is a pattern over one directory, but the record it produces is
  // ordinary data, and a Surface is a directory with an entry file in it.
  // Anything else under there is a file the agent wrote for its own reasons.
  const noise = discoverFrom({
    '../../../userspace/surfaces/README.md': ok,
    '../../../userspace/surfaces/runs/helpers.ts': ok,
    '../../../userspace/surfaces/runs/index.tsx': ok,
  })
  check('only the entry file makes a Surface', noise.descriptors.length === 1)
  check('and it is the one in a directory', noise.descriptors[0]!.id === 'runs')

  /*
    The criterion ADR-0002 turns on: adding a Surface is creating a file.

    Not "creating a file and appending to a list in Core" — the agent cannot
    write Core, so a registry would make the product's main loop impossible on
    day one. Checked as a difference rather than as a count, because a count
    would still pass if discovery had quietly renamed everything.
  */
  const before = discoverFrom({ '../../../userspace/surfaces/runs/index.tsx': ok })
  const after = discoverFrom({
    '../../../userspace/surfaces/runs/index.tsx': ok,
    '../../../userspace/surfaces/notes/index.tsx': ok,
  })
  check(
    'creating a file is the whole of adding a Surface',
    after.descriptors.length === before.descriptors.length + 1,
  )
  check(
    'and it leaves the Surface that was already there alone',
    JSON.stringify(after.descriptors.find((d) => d.id === 'runs')) ===
      JSON.stringify(before.descriptors[0]),
  )
}

{
  // The loader. Every failure below is a failed Surface carrying a sentence,
  // never a thrown value nobody caught — the machine puts the message on screen
  // and this is what it will read.
  const path = 'packages/userspace/surfaces/runs/index.tsx'
  const view = () => null

  /*
    A load that failed when it should not have has to read as a failed
    assertion, not as a rejected promise: an unhandled rejection stops the
    script with a stack trace, which is the same signal a broken build gives.
  */
  const loads = (run: Promise<unknown>) => run.catch(() => null)
  const reason = async (run: Promise<unknown>) =>
    run.then(() => '', (error: unknown) => (error instanceof Error ? error.message : String(error)))

  const good = discoverFrom({ '../../../userspace/surfaces/runs/index.tsx': async () => ({ default: view }) })
  check(
    'a Surface module resolves to what it default-exports',
    (await loads(importSurface(path, good.importers))) === view,
  )

  // The case ADR-0004 exists for: the module did not compile, so the dynamic
  // import rejected. Contained here, in a try/catch, rather than at bundle time.
  const broken = discoverFrom({
    '../../../userspace/surfaces/runs/index.tsx': async () => {
      throw new SyntaxError('Unexpected token (3:7)')
    },
  })
  const brokenSaid = await reason(importSurface(path, broken.importers))
  check('a module that does not compile names the module', brokenSaid.includes(path))
  check('and says why it did not load', brokenSaid.includes('Unexpected token (3:7)'))

  // Loaded and useless is still a failed Surface. Rendering `undefined` would
  // put a blank panel on screen with nothing to explain it.
  const empty = discoverFrom({
    '../../../userspace/surfaces/runs/index.tsx': async () => ({ notDefault: view }),
  })
  const emptySaid = await reason(importSurface(path, empty.importers))
  check('a module with no default export is a failed Surface', emptySaid.includes(path))
  check('and is told apart from one that would not compile', emptySaid.includes('default export'))

  // A descriptor for a file that has since been deleted, or a path nothing
  // matched. The message has to say where the file goes, because "not found" is
  // useless advice when the answer is to create it.
  const goneSaid = await reason(importSurface('packages/userspace/surfaces/gone/index.tsx', good.importers))
  check('a Surface with no module says so', goneSaid.includes('packages/userspace/surfaces/gone/index.tsx'))
  check('and says where the file goes', goneSaid.includes('packages/userspace/surfaces'))

  /*
    Retry without restarting varnick.

    The loader keeps no record of a failure, so `RETRY` re-runs the import and a
    module that has since been fixed loads. A loader that cached the rejection
    would leave the only recovery a relaunch — and the conversation that caused
    the breakage is the one that fixes it, so a relaunch is the one thing that
    must not be required.
  */
  let attempts = 0
  const fixable = discoverFrom({
    '../../../userspace/surfaces/runs/index.tsx': async () => {
      attempts++
      if (attempts === 1) throw new SyntaxError('Unexpected token (3:7)')
      return { default: view }
    },
  })
  check('the first load fails', (await reason(importSurface(path, fixable.importers))) !== '')
  check(
    'and the second one loads the module that was fixed',
    (await loads(importSurface(path, fixable.importers))) === view,
  )
  check('the loader really imported twice', attempts === 2)
}

// ---------------------------------------------------------------------------
// Secret resolution — the host substituting a value at the moment it runs
// Userspace code (ADR-0006)
//
// The one block in this script that fakes almost nothing. A module written the
// way the agent writes one, on disk, naming a secret nobody told it the value
// of; the real Secrets Store; the real host-side resolution; the real loader;
// and a real HTTP service on loopback that answers 200 to exactly one bearer
// token. What is faked is the keychain, because a test that wrote to the
// developer's keychain would be a worse bug than the one it was checking.
//
// The seam is `importSurface`'s third argument: the loader is where a Userspace
// module *runs*, so the loader is where a name becomes a value and, one line
// later, stops being one. See packages/harness/src/secret-resolution.ts for why
// the binding is non-enumerable, and why there is no equivalent in the renderer.
// ---------------------------------------------------------------------------

{
  /** Shaped like the thing it stands in for, so a leak is obvious in a grep. */
  const BILLING_TOKEN = 'tok_live_ONLY_THE_HOST_EVER_SEES_THIS'

  /** The sentence a failed load carries, never a rejection nobody caught. */
  const reason = async (run: Promise<unknown>) =>
    run.then(() => '', (error: unknown) => (error instanceof Error ? error.message : String(error)))

  const items = new Map<string, string>()
  const secrets = await openSecretsStore({
    keychain: {
      read: async (account) => items.get(account) ?? null,
      write: async (account, value) => {
        items.set(account, value)
      },
      remove: async (account) => {
        items.delete(account)
      },
    },
  })
  await secrets.store('BILLING_TOKEN', BILLING_TOKEN)
  const resolution = hostSecretResolution({ store: secrets })

  // The service the integration talks to. Every Authorization header it is sent
  // is kept, so what the module actually put on the wire is checkable rather
  // than inferred from a status code.
  const presented: string[] = []
  const service = Bun.serve({
    port: 0,
    fetch(request) {
      const authorization = request.headers.get('authorization') ?? ''
      presented.push(authorization)
      return authorization === `Bearer ${BILLING_TOKEN}`
        ? Response.json({ charged: true })
        : Response.json({ error: 'that token is not one of ours' }, { status: 401 })
    },
  })

  const clone = mkdtempSync(join(tmpdir(), 'varnick-userspace-'))

  /**
   * A Surface, written the way the agent writes one.
   *
   * The URL is in the source because the agent knows it. The token is not,
   * because the agent does not — it names it and gets on with the integration,
   * which is the whole of what ADR-0006 asks of it.
   *
   * Deliberately free of JSX: this script is React-free by design, and what is
   * being proven here is the loader, the resolution and a real request, not
   * rendering. A default-exported function is what the loader checks for.
   */
  const surfaceSource = (body: string) => `
const authorization = \`Bearer \${process.env.BILLING_TOKEN}\`
${body}
`

  /** Write one and hand back the pair the loader needs: a clone-relative path and an importer. */
  const writeSurface = (id: string, body: string) => {
    const dir = join(clone, 'surfaces', id)
    mkdirSync(dir, { recursive: true })
    const file = join(dir, 'index.tsx')
    writeFileSync(file, surfaceSource(body))
    const found = discoverFrom({
      [`../../../userspace/surfaces/${id}/index.tsx`]: () => import(file),
    })
    return { file, path: `packages/userspace/surfaces/${id}/index.tsx`, importers: found.importers }
  }

  const charge = writeSurface(
    'billing',
    `const response = await fetch('${service.url}charges', { headers: { authorization } })
const body = await response.json()
export default function Billing() {
  return { status: response.status, charged: body.charged === true }
}`,
  )

  check(
    'the module the agent wrote holds the name',
    readFileSync(charge.file, 'utf-8').includes('process.env.BILLING_TOKEN'),
  )
  check(
    'and cannot be read for the value, because the value was never in it',
    !readFileSync(charge.file, 'utf-8').includes(BILLING_TOKEN),
  )
  check('nothing resolves the name before the host runs the module', process.env.BILLING_TOKEN === undefined)

  const billing = (await importSurface(charge.path, charge.importers, resolution)) as () => {
    status: number
    charged: boolean
  }
  const charged = billing()

  check('the integration the agent wrote reached the service', presented.length === 1)
  check(
    'carrying the value the agent was never given',
    presented[0] === `Bearer ${BILLING_TOKEN}`,
  )
  check('and the service accepted it', charged.status === 200 && charged.charged)
  check(
    'the name stops resolving the moment the module has finished running',
    process.env.BILLING_TOKEN === undefined,
  )

  /*
    The same module, loaded without a resolution.

    Here so the four checks above are load-bearing rather than a module that
    would have worked either way: without the host substituting at the moment of
    execution, the agent's code sends the name unresolved and the service says
    no. A second directory rather than a second load, because a module is
    evaluated once per path and the point is a second evaluation.
  */
  const unresolved = writeSurface(
    'billing-unresolved',
    `const response = await fetch('${service.url}charges', { headers: { authorization } })
const body = await response.json()
export default function Billing() {
  return { status: response.status, charged: body.charged === true }
}`,
  )
  const bare = (await importSurface(unresolved.path, unresolved.importers)) as () => {
    status: number
    charged: boolean
  }
  const refused = bare()
  check('the same module with no resolution is refused by the service', refused.status === 401)
  check('because it sent the name, unresolved', presented[1] === 'Bearer undefined')

  /*
    The failure path, which is where a resolved value gets out if anything does.

    A client that rejects a request quotes what it rejected. That sentence is
    what the loader turns into "<module> did not load — <reason>", which the
    failed Surface puts on screen and the transcript then carries into the
    mirror. So the loader redacts through the resolution on the way out.
  */
  const angry = writeSurface(
    'billing-angry',
    `throw new Error(\`the billing service rejected \${authorization}\`)`,
  )
  const said = await reason(importSurface(angry.path, angry.importers, resolution))
  check('a failure raised while the value was in hand does not quote it', !said.includes(BILLING_TOKEN))
  check('it says [redacted] where the value was', said.includes('[redacted]'))
  check('and still names the module the developer has to open', said.includes(angry.path))

  // The same sentence, through a real Session mirror over a real filesystem,
  // read back the way `grep -r` would read it. Ticket 10 proved this for a value
  // the developer typed; this is the same proof for a value the host resolved.
  const mirror = mkdtempSync(join(tmpdir(), 'varnick-resolution-mirror-'))
  const sessions = createSessionStore({ root: mirror, secretValues: () => secrets.secretValues() })
  await sessions.persist({
    sessionId: 'resolved-surface-failure',
    messages: [{ id: 'm1', role: 'agent', text: `The billing Surface failed: ${said}` }],
  })
  const onDisk = readdirSync(mirror)
    .map((name) => readFileSync(join(mirror, name), 'utf-8'))
    .join('\n')
  check('the mirror wrote something', onDisk.length > 0)
  check('and no byte of it is the value the host resolved', !onDisk.includes(BILLING_TOKEN))

  service.stop(true)
  rmSync(clone, { recursive: true, force: true })
  rmSync(mirror, { recursive: true, force: true })
}

// ---------------------------------------------------------------------------
// The naming end — the agent being told which secrets exist (ADR-0006)
//
// The block above proves the holding half: a name in a module the agent wrote
// becomes a value at the moment the host runs it. It proves nothing about how
// the agent knew to write `BILLING_TOKEN`, because in that block a person typed
// it into the script. This is the other half.
//
// The route is real end to end, with one thing faked and one thing stood in
// for. Faked: the keychain, because a script that wrote to the developer's
// keychain would be a worse bug than the one it is checking. Stood in for: the
// Rust host, which is four lines of `serde_json` — `control_line_for` in
// src-tauri/src/agent.rs — and cannot be called from here. Everything else is
// the shipping code: the runtime's answer function, the control-request parse
// that runs inside the Sandbox, the text the agent is handed, the loader, the
// resolution, and a real HTTP service on loopback.
//
// What closes the loop is that the Surface below is written from *the brief*
// rather than from a constant. The name in the code is the name the agent was
// told, read back out of the sentence it was told it in.
// ---------------------------------------------------------------------------

{
  /** Shaped like the thing it stands in for, so a leak is obvious in a grep. */
  const BILLING_TOKEN = 'tok_live_THE_AGENT_IS_TOLD_THE_NAME_NOT_THIS'
  const SHIPPING_TOKEN = 'tok_live_ADDED_WHILE_VARNICK_WAS_ALREADY_RUNNING'

  const items = new Map<string, string>()
  const secrets = await openSecretsStore({
    keychain: {
      read: async (account) => items.get(account) ?? null,
      write: async (account, value) => {
        items.set(account, value)
      },
      remove: async (account) => {
        items.delete(account)
      },
    },
  })
  await secrets.store('BILLING_TOKEN', BILLING_TOKEN)
  const resolution = hostSecretResolution({ store: secrets })

  /**
   * Every byte that crossed a wire in this block.
   *
   * Collected so the claim "no value reaches the agent" can be taken once, over
   * everything, at the end — rather than as a series of assertions about the
   * places someone thought to look.
   */
  const wire: string[] = []

  /*
    The Harness runtime's capabilities, with the keychain faked and nothing
    else. `readSecretNames` is `hostCapabilities`'s own implementation: reload,
    then `names()`. The rest refuse — nothing in this block calls them, and a
    stub that quietly answered would be a stub that hid a wrong route.
  */
  const unreached = () => {
    throw new Error('this block does not call that capability')
  }
  const capabilities: HarnessCapabilities = {
    establishSandbox: unreached,
    wrapAgentCommand: unreached,
    persist: unreached,
    readSession: unreached,
    readSecretNames: async () => {
      await secrets.reload()
      return secrets.names()
    },
  }

  /**
   * One trip down the whole route, ending in the text the agent reads.
   *
   * Runtime answer -> the line the Rust host writes -> the parse that runs
   * inside the Sandbox -> the brief. Every step but the middle one is the
   * shipping function.
   */
  const briefTheAgent = async (): Promise<string> => {
    const reply = await answerHarnessLine(
      JSON.stringify({ id: 1, request: { kind: 'read-secret-names' } }),
      capabilities,
    )
    wire.push(reply)
    const answered = (JSON.parse(reply) as { ok?: { names?: unknown } }).ok?.names
    check('the runtime answers a name read with a list', Array.isArray(answered))

    // What `control_line_for` writes in src-tauri/src/agent.rs: the kind and
    // the names, and no field a value could ride in.
    const line = `${JSON.stringify({ kind: 'describe-secrets', names: answered })}\n`
    wire.push(line)

    const request = parseControlRequest(line)
    check('the confined process reads it as a control request', request?.kind === 'describe-secrets')
    const names = request?.kind === 'describe-secrets' ? request.names : []
    const brief = describeSecretsForAgent(names)
    wire.push(brief)
    return brief
  }

  /** The names the agent can see in what it was handed. */
  const namesIn = (brief: string) =>
    brief
      .split('\n')
      .filter((sentence) => sentence.startsWith('  ') && sentence.trim().length > 0)
      .map((sentence) => sentence.trim())

  // The service the integration talks to. Two tokens are good; anything else,
  // including an unresolved name, is refused.
  const accepted = new Map([
    [`Bearer ${BILLING_TOKEN}`, 'billing'],
    [`Bearer ${SHIPPING_TOKEN}`, 'shipping'],
  ])
  const presented: string[] = []
  const service = Bun.serve({
    port: 0,
    fetch(request) {
      const authorization = request.headers.get('authorization') ?? ''
      presented.push(authorization)
      const charged = accepted.get(authorization)
      return charged === undefined
        ? Response.json({ error: 'that token is not one of ours' }, { status: 401 })
        : Response.json({ charged })
    },
  })

  const clone = mkdtempSync(join(tmpdir(), 'varnick-naming-'))

  /**
   * A Surface, written the way an agent that has read the brief writes one.
   *
   * `name` is not a constant here — it is lifted out of the sentence the agent
   * was handed, which is the whole point. If the brief named the wrong secret,
   * or named none, this module would be written against the wrong name and the
   * service would refuse it.
   */
  const writeSurface = (id: string, name: string) => {
    const dir = join(clone, 'surfaces', id)
    mkdirSync(dir, { recursive: true })
    const file = join(dir, 'index.tsx')
    writeFileSync(
      file,
      `const authorization = \`Bearer \${process.env.${name}}\`
const response = await fetch('${service.url}charges', { headers: { authorization } })
const body = await response.json()
export default function Billing() {
  return { status: response.status, charged: body.charged }
}`,
    )
    const found = discoverFrom({
      [`../../../userspace/surfaces/${id}/index.tsx`]: () => import(file),
    })
    return { file, path: `packages/userspace/surfaces/${id}/index.tsx`, importers: found.importers }
  }

  const first = await briefTheAgent()
  check('the agent is told the name of the secret that is stored', namesIn(first).includes('BILLING_TOKEN'))
  check(
    'and told it cannot read the value, so it stops asking for one',
    /cannot read a secret value/.test(first),
  )
  check(
    'and told where a secret resolves, because a Surface in the window reads undefined',
    first.includes('host-side') && first.includes('window'),
  )

  const billing = writeSurface('billing-named', namesIn(first)[0] as string)
  check(
    'the module written from the brief names the secret',
    readFileSync(billing.file, 'utf-8').includes('process.env.BILLING_TOKEN'),
  )
  check(
    'and holds no value, because the brief carried none to copy',
    !readFileSync(billing.file, 'utf-8').includes(BILLING_TOKEN),
  )

  const charged = (await importSurface(billing.path, billing.importers, resolution)) as () => {
    status: number
    charged: string
  }
  const receipt = charged()
  check('the integration reached the service', presented.length === 1)
  check('carrying the value the agent was never given', presented[0] === `Bearer ${BILLING_TOKEN}`)
  check('and the service accepted it', receipt.status === 200 && receipt.charged === 'billing')

  /*
    A secret added while varnick is already running.

    This is the criterion the environment route could not have met, and the
    reason the names ride the control channel instead. `bun run secret add` is a
    *different process* writing the same keychain, which from in here is a write
    behind the open store's back — so the store below is never reopened and the
    brief is asked for again exactly as the host asks for it before every Turn.
  */
  items.set('SHIPPING_TOKEN', SHIPPING_TOKEN)
  items.set('varnick.index', JSON.stringify(['BILLING_TOKEN', 'SHIPPING_TOKEN']))

  const second = await briefTheAgent()
  check(
    'a secret added while varnick is running is named without a relaunch',
    namesIn(second).includes('SHIPPING_TOKEN'),
  )
  check('and the one that was already there still is', namesIn(second).includes('BILLING_TOKEN'))

  const shipping = writeSurface('shipping-named', 'SHIPPING_TOKEN')
  const shipped = (await importSurface(shipping.path, shipping.importers, resolution)) as () => {
    status: number
    charged: string
  }
  const label = shipped()
  check(
    'and code the agent writes against it resolves, on the same running host',
    label.status === 200 && label.charged === 'shipping',
  )

  /*
    The assertion the ticket turns on, taken over everything at once.

    Every reply, every control line and every brief that crossed in this block,
    against both values. Names are what travels; values stay in the host process
    that read the keychain.
  */
  const crossed = wire.join('\n')
  check('no byte of what crossed to the agent is a secret value', !crossed.includes(BILLING_TOKEN))
  check('including the one added mid-session', !crossed.includes(SHIPPING_TOKEN))
  check('and what crossed did carry the names', crossed.includes('BILLING_TOKEN') && crossed.includes('SHIPPING_TOKEN'))

  service.stop(true)
  rmSync(clone, { recursive: true, force: true })
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
  // Not `!can({ type: 'RETRY' })`, which stood here: XState answers false from
  // `can()` for *any* stopped actor, so that held for a machine with a RETRY
  // handler on every state. Where it stopped is the fact — `unloaded` rather
  // than `failed`, which is the state a stray UNLOAD during a load would reach.
  check('an unloaded Surface stopped in unloaded', actor.getSnapshot().value === 'unloaded')
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
    const actor = createActor(frozenHarness(scenario.surfaceOutcome), {
      input: scenario.input,
    }).start()

    /*
      A Surface arrives by event, and its load settles on a later tick.

      Waited for by name rather than by a blanket flush: a card claiming
      `surface.loaded` says so in `covers`, so that is what is waited on, and
      `surface.loading` is reached synchronously and waits for nothing. The wait
      is bounded and its result discarded — a Surface that never arrives is
      caught by the assertion below, which reads better than a script that hangs.
    */
    if (scenario.surfaces) {
      actor.send({ type: 'DISCOVER_SURFACES', descriptors: [...scenario.surfaces] })
      for (const path of scenario.covers) {
        if (!path.startsWith('surface.')) continue
        const want = path.slice('surface.'.length)
        await reaches(
          waitFor(
            actor,
            (s) => s.context.surfaces.some((ref) => String(ref.getSnapshot().value) === want),
            soon,
          ),
        )
      }
    }

    const snap = actor.getSnapshot()
    const session = snap.context.session

    /*
      Flattened rather than String()'d. A region whose state is compound reads as
      an object, and `String({answering:'sending'})` is "[object Object]", so a
      nested path silently failed to match instead of failing loudly.

      Written here rather than imported from hooks.ts: that module reaches the
      Surface loader, which calls `import.meta.glob`, which only exists under
      Vite. Importing it would break this script, which is the whole reason
      surfaces.ts takes its record as an argument.
    */
    const pathOf = (value: unknown): string => {
      if (typeof value === 'string') return value
      const [key] = Object.keys(value as Record<string, unknown>)
      if (key === undefined) return ''
      return `${key}.${pathOf((value as Record<string, unknown>)[key])}`
    }

    // `pathOf` rather than String(): a region whose state is compound reads as
    // an object, and `String({answering:'sending'})` is "[object Object]" — so
    // every nested path silently failed to match rather than failing loudly.
    const reached = new Set<string>()
    for (const [region, value] of Object.entries(snap.value as Record<string, unknown>)) {
      reached.add(`${region}.${pathOf(value)}`)
    }
    if (session) {
      for (const [region, value] of Object.entries(
        session.getSnapshot().value as Record<string, unknown>,
      )) {
        reached.add(`${region}.${pathOf(value)}`)
      }
    }
    // Surfaces are children rather than regions, so they are read off the
    // parent's context instead of out of its state value.
    for (const ref of snap.context.surfaces) {
      reached.add(`surface.${String(ref.getSnapshot().value)}`)
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
    JSON.stringify(actor.getSnapshot().context.session?.getSnapshot().value.turn) ===
      '{"answering":"sending"}',
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

    ADR-0004 says this is "enforced by lint, not by discipline", and as of
    ticket 14 there is one: `no-restricted-imports` in eslint.config.js, run by
    `bun run lint`. This check stays, and it is the stronger of the two for a
    reason that has nothing to do with linting. It lives under
    `packages/core/**`, which the sandbox policy denies the agent write access
    to (ADR-0002); `eslint.config.js` sits at the clone root, where no such deny
    applies. An agent that could switch the rule off cannot switch this off.
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
    One Turn, one actor — the assertion that was missing.

    `sending` and `streaming` each used to invoke `runTurn`. An invoke is bound
    to the state it sits on, so the first streamed token stopped the first actor
    and started a second: the developer's Turn was aborted at its first token,
    the host was told to interrupt it, and the same prompt was posted again —
    billed twice, answered once.

    Nothing caught it. The state census compared the two states' accepted events
    and passed *because* the blocks were byte-identical, which is the shape a bad
    merge leaves behind. Counting invocations is what tells "these two states
    agree" apart from "this is one state written twice".
  */
  const prompts: string[] = []
  const aborts: string[] = []
  const counted = fromPromise<TurnOutput, TurnInput>(async ({ input, signal }) => {
    prompts.push(input.prompt)
    signal.addEventListener('abort', () => aborts.push(input.prompt))
    await new Promise((resolve) => setTimeout(resolve, 5))
    return { text: 'done', tokensUsed: 12 }
  })

  const actor = createActor(sessionMachine.provide({ actors: { runTurn: counted } }), {
    input: { sessionId: 'once' },
  }).start()

  actor.send({ type: 'EDIT_DRAFT', text: 'the real question' })
  actor.send({ type: 'SEND' })
  actor.send({ type: 'STREAM_DELTA', text: 'partial' })
  await waitFor(actor, (s) => regionOf(s.value, 'turn') === 'idle')
  actor.stop()

  check('a streamed turn runs its actor exactly once', prompts.length === 1)
  check('and the prompt it ran with is the one that was asked', prompts[0] === 'the real question')
  check('and nothing aborted the turn on the way', aborts.length === 0)
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

  check(
    'a turn walks sending → streaming → idle',
    seeded.path.join('→') === 'idle→answering.sending→answering.streaming→idle',
  )
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
  /*
    This asserted `at.size === 6` and could not fail: `at` is filled by six
    literal `at.set` calls with distinct keys, so its size is six whatever the
    machine does. The fact worth holding is that the six measured here are
    *exactly* the turn states the machine declares — so adding a turn state
    without measuring what it accepts fails this line rather than passing it.
  */
  const declaredTurnStates = SESSION_STATE_PATHS.filter((path) => path.startsWith('turn.'))
    .map((path) => path.split('.').at(-1)!)
    .sort()
    .join(' ')
  check(
    'every turn state the machine declares was reached to be measured',
    [...at.keys()].sort().join(' ') === declaredTurnStates,
  )
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
  check('the turn is streaming', regionOf(actor.getSnapshot().value, 'turn') === 'answering.streaming')

  actor.send({ type: 'EDIT_DRAFT', text: 'the next instruction' })
  check('the composer accepts a draft mid-stream', actor.getSnapshot().context.draft === 'the next instruction')
  check('and the turn is untouched', regionOf(actor.getSnapshot().value, 'turn') === 'answering.streaming')
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
  check('the compaction actor is no longer listed as unimplemented', !UNIMPLEMENTED.includes('compactSession'))
  // The Surface loader is real in both modes and has no seeded half — there is
  // no service behind an import to stand in for. Listing it would tell a reader
  // the panel beside the chat is showing something invented.
  check('the Surface loader is not listed as unimplemented', !UNIMPLEMENTED.includes('loadSurface'))
  // `UNIMPLEMENTED.every(...)` stood here, and an `every` over an empty list is
  // true by definition — the list emptied and the assertion went on passing
  // without reading anything. Both halves below can fail: the subset property
  // for whenever a name goes back on, and the count, which is the fact the
  // seeded marker actually renders.
  check('every unimplemented name is a real actor', UNIMPLEMENTED.every((name) => (ACTOR_NAMES as readonly string[]).includes(name)))
  check('no actor is listed as unimplemented, so the seeded marker claims nothing', UNIMPLEMENTED.length === 0)

  /*
    And what the marker then says, which stopped being true when the list
    emptied. It named an empty list — "These actors have no live implementation
    yet:" over nothing — and told the developer to append `?actors=live`, which
    has been the default since every actor was wired, and which names no actor it
    could fail on. Both branches are asserted here because only one of them can
    be reached by running the app today.
  */
  const nothingMissing = seededDetail([])
  check('with everything wired, the marker names no actor', nothingMissing.names.length === 0)
  check('and says seeded was a choice rather than a gap', nothingMissing.lead.includes('asked to be'))
  check('and points at the flag that is actually set', nothingMissing.exit.includes('?actors=seeded'))

  const oneMissing = seededDetail(['runTurn'])
  check('with something missing, the marker names it', oneMissing.names.join() === 'runTurn')
  check('and points at the flag that would fail on it', oneMissing.exit.includes('?actors=live'))
}

/*
  A "Plan usage" section stood here — six blocks driving the `subscription`
  region: that the read is gated on the Credential Kind, that a re-read under an
  API key is refused, that a good read is kept and a failed one invents nothing.

  Every one of them passed, and none of them was measuring the product. They
  drove a machine whose actor could never return a figure in any configuration
  varnick ships: under the only subscription it can hold, a `claude setup-token`
  credential, the session answers `rate_limits_available: false` and does not
  identify itself as a subscription at all. The gate these blocks proved correct
  was correct, and was never the thing standing between the developer and a
  number.

  The region, the actor and the strip are gone; see ticket 31 and ADR-0011.
  Nothing replaced these assertions because there is nothing left to assert.
*/

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
// The credential, stored from inside the window
//
// `credential.absent` is the state a stranger's fresh clone opens in, and until
// now the only way out of it was a terminal. These are the machine facts of the
// way out that is not: which states accept a paste, what a store does on its
// way through, and — the one that matters most — that the value it carries
// exists nowhere afterwards.
// ---------------------------------------------------------------------------

type StoreInput = { kind: 'api-key' | 'subscription'; value: string }

/** A value shaped like a real token, so "it is nowhere" is worth asserting. */
const PASTED = ['sk-', 'ant-api03-NEVER-LET-THIS-OUT'].join('')

{
  // Only `absent` takes one. A paste is how a developer gets *out* of having no
  // credential; offering it over one that is present would be a way to replace
  // a working credential by accident, and offering it mid-read would race the
  // read it is about to invalidate.
  const storing = { type: 'STORE_CREDENTIAL' as const, kind: 'api-key' as const, value: 'a-key' }

  const fresh = createActor(harnessMachine, { input: { policy: seedPolicy } }).start()
  check('a fresh clone accepts a pasted credential', fresh.getSnapshot().can(storing))
  check(
    'and refuses an empty one, so the control is off rather than the store failing',
    !fresh.getSnapshot().can({ ...storing, value: '   ' }),
  )
  fresh.stop()

  for (const enterCredential of ['reading', 'present', 'rejected'] as const) {
    const actor = createActor(harnessMachine, {
      input: { policy: seedPolicy, enterCredential, credentialKind: 'api-key' },
    }).start()
    check(
      `credential.${enterCredential} refuses a paste`,
      !actor.getSnapshot().can(storing),
    )
    // The kind and the paste appear and disappear together. A choice offered
    // where nothing can be stored is a control with nothing to control.
    check(
      `credential.${enterCredential} offers no kind to choose`,
      !actor.getSnapshot().can({ type: 'CHOOSE_CREDENTIAL_KIND', kind: 'api-key' }),
    )
    actor.stop()
  }
}

{
  /*
    Which kind is being written is machine state, not a component's.

    The view is a pure function of `(snapshot, send)` — ADR-0001 — so a radio
    selection in a `useState` would be a piece of the setup screen the states
    page could not park in, and the card would show a choice that could not be
    made. It defaults to a subscription for the same reason `resolve` prefers
    one: a developer already paying for a plan should not be shown a
    bill-per-request key as the obvious option.
  */
  const actor = createActor(harnessMachine, { input: { policy: seedPolicy } }).start()
  check('a fresh clone is set to write a subscription', actor.getSnapshot().context.storingKind === 'subscription')
  check(
    'and the choice is a control the machine offers',
    actor.getSnapshot().can({ type: 'CHOOSE_CREDENTIAL_KIND', kind: 'api-key' }),
  )

  actor.send({ type: 'CHOOSE_CREDENTIAL_KIND', kind: 'api-key' })
  check('choosing the other kind changes what a store would write', actor.getSnapshot().context.storingKind === 'api-key')
  check(
    'and changes nothing else — it is not a credential',
    regionOf(actor.getSnapshot().value, 'credential') === 'absent' &&
      actor.getSnapshot().context.credentialKind === null,
  )
  actor.stop()
}

{
  /*
    A store that worked re-reads, and lands where any other launch lands.

    The re-read is the point rather than a flourish: one code path establishes
    the credential whether it was stored a minute ago or a year ago, so a write
    that somehow produced an unreadable item is caught now instead of at the
    next launch. It is also what keeps ADR-0011 true — the developer chose which
    item to write, and the host still decides what it is holding by resolving.
  */
  // Both kinds, because the checklist this realizes is about a fresh clone with
  // an empty keychain reaching a working agent — and there are two ways to have
  // one. The write differs only in which item it addresses.
  for (const kind of ['subscription', 'api-key'] as const) {
    let written: StoreInput | null = null
    const actor = createActor(
      harnessMachine.provide({
        actors: {
          storeCredential: fromPromise<void, StoreInput>(async ({ input }) => {
            written = { ...input }
          }),
          readCredential: resolves<CredentialReading, Record<string, never>>({
            source: 'keychain',
            kind,
          }),
        },
      }),
      { input: { policy: seedPolicy } },
    ).start()

    actor.send({ type: 'CHOOSE_CREDENTIAL_KIND', kind })
    actor.send({ type: 'STORE_CREDENTIAL', kind, value: PASTED })
    check(`a pasted ${kind} enters storing`, regionOf(actor.getSnapshot().value, 'credential') === 'storing')
    check(
      `and storing says it is writing the ${kind} item, which is not a secret`,
      actor.getSnapshot().context.storingKind === kind,
    )

    await waitFor(actor, (s) => regionOf(s.value, 'credential') === 'present')
    check(`a stored ${kind} is read back rather than assumed`, written !== null)
    check(`the host is handed the kind the developer chose (${kind})`, written!.kind === kind)
    check(`and the value, once (${kind})`, written!.value === PASTED)
    check(
      `the kind that lands in context is the one the read resolved (${kind})`,
      actor.getSnapshot().context.credentialKind === kind,
    )

    /*
      The assertion this whole path exists for, and it is an assertion rather
      than an inspection: after a store, the value is in no field of the machine.
      That covers the transcript and the Session mirror at once — the mirror is
      handed `context.messages`, and everything the surface renders comes from
      here.
    */
    check(
      `nothing in the machine holds what was pasted (${kind})`,
      !JSON.stringify(actor.getSnapshot().context, (_k, v) =>
        typeof v === 'object' && v !== null && 'send' in (v as object) ? undefined : v,
      ).includes(PASTED),
    )
    actor.stop()
  }
}

{
  // A store that failed comes back to `absent` carrying the reason, exactly as
  // a failed read does — so the surface has one place to look and one sentence
  // to render, whichever of the two went wrong.
  const actor = createActor(
    harnessMachine.provide({
      actors: {
        storeCredential: rejects<void, StoreInput>('The keychain refused to store it.'),
        readCredential: rejects<CredentialReading, Record<string, never>>('nothing is stored'),
      },
    }),
    { input: { policy: seedPolicy } },
  ).start()

  actor.send({ type: 'STORE_CREDENTIAL', kind: 'api-key', value: PASTED })
  await waitFor(actor, (s) => regionOf(s.value, 'credential') === 'absent')
  check(
    'a failed store says why',
    actor.getSnapshot().context.credentialError === 'The keychain refused to store it.',
  )
  check(
    'a failed store leaves no kind standing',
    actor.getSnapshot().context.credentialKind === null,
  )
  check(
    'and nothing that failed kept the value',
    !JSON.stringify(actor.getSnapshot().context, (_k, v) =>
      typeof v === 'object' && v !== null && 'send' in (v as object) ? undefined : v,
    ).includes(PASTED),
  )
  check('a failed store can be tried again', actor.getSnapshot().can({ type: 'STORE_CREDENTIAL', kind: 'api-key', value: 'again' }))
  actor.stop()
}

{
  // The value never reaches the Session mirror, asserted at the mirror rather
  // than argued from where it is not. A store while an agent is running, then a
  // Turn boundary, then everything the store was handed.
  const { spy, actor: persistSession } = saveSpy(true)
  const actor = createActor(
    harnessMachine.provide({
      actors: {
        storeCredential: fromPromise<void, StoreInput>(async () => {}),
        readCredential: resolves<CredentialReading, Record<string, never>>({
          source: 'keychain',
          kind: 'api-key',
        }),
        checkSandbox: resolves<{ ok: true }, { policy: SandboxPolicy }>({ ok: true }),
        spawnAgent: resolves<{ pid: number }, { policy: SandboxPolicy }>({ pid: 3 }),
        session: sessionMachine.provide({
          actors: { runTurn: resolves<TurnOutput, TurnInput>({ text: 'ok', tokensUsed: 1 }), persistSession },
        }),
      },
    }),
    { input: { policy: seedPolicy } },
  ).start()

  actor.send({ type: 'STORE_CREDENTIAL', kind: 'api-key', value: PASTED })
  await waitFor(actor, (s) => regionOf(s.value, 'credential') === 'present')
  actor.send({ type: 'CHECK_SANDBOX' })
  await waitFor(actor, (s) => regionOf(s.value, 'sandbox') === 'available')
  actor.send({ type: 'START' })
  await waitFor(actor, (s) => regionOf(s.value, 'agent') === 'running')

  const session = actor.getSnapshot().context.session!
  session.send({ type: 'EDIT_DRAFT', text: 'first thing after storing a credential' })
  session.send({ type: 'SEND' })
  check(
    'the turn after a store reaches the mirror',
    await reaches(waitFor(session, (s) => regionOf(s.value, 'turn') === 'idle' && spy.calls > 0, soon)),
  )
  check(
    'and what the mirror was handed holds no credential',
    !JSON.stringify(spy.last).includes(PASTED),
  )
  actor.stop()
}

// ---------------------------------------------------------------------------
// The credential, minted from inside the window
//
// The other way out of `credential.absent`, and the shorter one: a developer
// with a subscription signs in and supplies nothing. These are the machine
// facts of it. What the host does — a pty, a parse, a keychain write — is
// tested in src-tauri/src/mint.rs, and no test anywhere runs the real flow,
// because the real flow opens a browser and authenticates a human.
//
// The property this section exists to hold is that *nothing about a token is
// representable here*. The actor takes no input and answers with none, so
// unlike the store there is not even a value passing through to assert the
// absence of.
// ---------------------------------------------------------------------------

/** An authorize URL, as the host would report one. Not a credential. */
const SIGN_IN_AT = 'https://claude.com/cai/oauth/authorize?state=drive'

{
  // Only `absent` starts one, exactly as only `absent` takes a paste. A mint
  // over a credential that is present would replace a working one, and this one
  // takes minutes and opens a browser while it does it.
  const fresh = createActor(harnessMachine, { input: { policy: seedPolicy } }).start()
  check('a fresh clone can be told to get a token', fresh.getSnapshot().can({ type: 'MINT_CREDENTIAL' }))
  check(
    'and a fresh clone has no sign-in URL to show for a mint nobody started',
    fresh.getSnapshot().context.mintUrl === null,
  )
  fresh.stop()

  for (const enterCredential of ['reading', 'present', 'rejected'] as const) {
    const actor = createActor(harnessMachine, {
      input: { policy: seedPolicy, enterCredential, credentialKind: 'subscription' },
    }).start()
    check(
      `credential.${enterCredential} refuses a mint`,
      !actor.getSnapshot().can({ type: 'MINT_CREDENTIAL' }),
    )
    actor.stop()
  }
}

{
  /*
    A mint that worked re-reads, and lands where a paste lands.

    The same rule ADR-0011 puts on a store, and it costs nothing extra here: the
    host wrote a keychain item, and which credential varnick *uses* is still
    decided by resolving on the next read. A machine that declared the
    credential present because a mint said so would be trusting a write it never
    read back.
  */
  let inputs: unknown[] = []
  const actor = createActor(
    harnessMachine.provide({
      actors: {
        mintSubscriptionToken: fromPromise<void, Record<string, never>>(async ({ input }) => {
          inputs.push(input)
        }),
        readCredential: resolves<CredentialReading, Record<string, never>>({
          source: 'keychain',
          kind: 'subscription',
        }),
      },
    }),
    { input: { policy: seedPolicy } },
  ).start()

  actor.send({ type: 'MINT_CREDENTIAL' })
  check('minting is its own state', regionOf(actor.getSnapshot().value, 'credential') === 'minting')

  await waitFor(actor, (s) => regionOf(s.value, 'credential') === 'present')
  check('a minted token is read back rather than assumed', inputs.length === 1)
  check(
    'the kind that lands in context is the one the read resolved',
    actor.getSnapshot().context.credentialKind === 'subscription',
  )
  /*
    The assertion this whole path exists for, and it is about the *shape* rather
    than about a value that happened not to appear. A mint is handed nothing:
    the command is a constant on the host, so there is no field here that could
    name a different one, and no input a token could be smuggled in through.
  */
  check('a mint is handed nothing at all', JSON.stringify(inputs) === '[{}]')
  check(
    'and nothing in the machine holds anything a token could be',
    !JSON.stringify(actor.getSnapshot().context, (_k, v) =>
      typeof v === 'object' && v !== null && 'send' in (v as object) ? undefined : v,
    ).includes('sk-'),
  )
  actor.stop()
}

{
  /*
    The URL, which is the one thing a running mint says.

    It is accepted in `minting` and nowhere else, and it is cleared on the way
    out — so a link from an attempt that has ended can never sit on a screen
    that has moved on, offering an authorization that would finish into a
    process that is gone.
  */
  const actor = createActor(
    harnessMachine.provide({
      actors: {
        mintSubscriptionToken: never<void, Record<string, never>>(),
        readCredential: rejects<CredentialReading, Record<string, never>>('nothing is stored'),
      },
    }),
    { input: { policy: seedPolicy } },
  ).start()

  check(
    'a machine with no mint running refuses a sign-in URL',
    !actor.getSnapshot().can({ type: 'MINT_URL', url: SIGN_IN_AT }),
  )

  actor.send({ type: 'MINT_CREDENTIAL' })
  check('a running mint accepts one', actor.getSnapshot().can({ type: 'MINT_URL', url: SIGN_IN_AT }))
  actor.send({ type: 'MINT_URL', url: SIGN_IN_AT })
  check('and shows it', actor.getSnapshot().context.mintUrl === SIGN_IN_AT)
  check(
    'a sign-in URL is not a credential and does not make one',
    regionOf(actor.getSnapshot().value, 'credential') === 'minting' &&
      actor.getSnapshot().context.credentialKind === null,
  )
  actor.stop()
}

{
  // A mint that failed comes back to `absent` carrying the reason, exactly as a
  // failed store and a failed read do — one place for the surface to look,
  // whichever of the three went wrong. And it takes its URL with it.
  const actor = createActor(
    harnessMachine.provide({
      actors: {
        mintSubscriptionToken: rejects<void, Record<string, never>>(
          'The sign-in finished without producing a token.',
        ),
        readCredential: rejects<CredentialReading, Record<string, never>>('nothing is stored'),
      },
    }),
    { input: { policy: seedPolicy } },
  ).start()

  actor.send({ type: 'MINT_CREDENTIAL' })
  actor.send({ type: 'MINT_URL', url: SIGN_IN_AT })
  await waitFor(actor, (s) => regionOf(s.value, 'credential') === 'absent')
  check(
    'a failed mint says why',
    actor.getSnapshot().context.credentialError === 'The sign-in finished without producing a token.',
  )
  check('a failed mint leaves no kind standing', actor.getSnapshot().context.credentialKind === null)
  check('and no stale sign-in URL', actor.getSnapshot().context.mintUrl === null)
  check('a failed mint can be tried again', actor.getSnapshot().can({ type: 'MINT_CREDENTIAL' }))
  check(
    'and the paste is still there beside it',
    actor.getSnapshot().can({ type: 'STORE_CREDENTIAL', kind: 'subscription', value: 'a-token' }),
  )
  actor.stop()
}

{
  /*
    And the states page can park a card here with a URL already showing.

    The reason this is asserted rather than assumed: clearing the URL on *entry*
    is the obvious way to make a second attempt start clean, and it would wipe a
    card's input before it rendered — a scenario about the fallback that could
    not show the fallback. Clearing on exit does the same job, which is what the
    check above proves, and leaves this one possible.
  */
  const actor = createActor(
    harnessMachine.provide({
      actors: { mintSubscriptionToken: never<void, Record<string, never>>() },
    }),
    { input: { policy: seedPolicy, enterCredential: 'minting', mintUrl: SIGN_IN_AT } },
  ).start()
  check(
    'a card can be parked mid-sign-in with a URL on screen',
    regionOf(actor.getSnapshot().value, 'credential') === 'minting' &&
      actor.getSnapshot().context.mintUrl === SIGN_IN_AT,
  )
  actor.stop()
}

{
  /*
    The live actor, against a host that answers.

    Two calls and no third: start the mint, then read what it says until it says
    it is done. Nothing here can produce a credential — the host mints one and
    stores it — so what this checks is the traffic, and that the only string
    that came back was the URL.
  */
  const realInternals = (globalThis as Record<string, unknown>).__TAURI_INTERNALS__
  const asked: string[] = []
  let queued: unknown[] = []
  ;(globalThis as Record<string, unknown>).__TAURI_INTERNALS__ = {
    invoke: async (_command: string, payload: { request: { kind: string } }) => {
      const kind = payload.request.kind
      asked.push(kind)
      if (kind === 'mint-subscription-token') return { ok: true }
      if (kind === 'next-mint-event') return { event: queued.shift() ?? null }
      throw { failure: 'malformed' }
    },
  }

  const seen: string[] = []
  const mint = liveActors(undefined, { authorizing: (url) => seen.push(url) }).mintSubscriptionToken
  const run = () =>
    new Promise<{ done: boolean; output?: unknown; error?: unknown }>((resolve) => {
      const actor = createActor(mint, { input: {} as Record<string, never> })
      actor.subscribe({
        next: (snapshot) => {
          if (snapshot.status === 'done') resolve({ done: true, output: snapshot.output })
        },
        error: (error) => resolve({ done: false, error }),
      })
      actor.start()
    })

  queued = [{ kind: 'authorize', url: SIGN_IN_AT }, null, { kind: 'stored' }]
  const done = await run()
  check('a live mint settles when the host says the token is stored', done.done)
  check(
    'and asks for nothing but the mint and what it has to say',
    asked.every((kind) => kind === 'mint-subscription-token' || kind === 'next-mint-event'),
  )
  check('the URL reaches the window', seen.join('|') === SIGN_IN_AT)
  check(
    'and a successful mint answers with nothing, so there is nothing it could answer with',
    done.output === undefined,
  )

  asked.length = 0
  queued = [{ kind: 'failed', failure: 'no-token' }]
  const failed = await run()
  check('a live mint that produced no token throws rather than settling', !failed.done)
  check(
    'and reads as the sentence Core authors for that tag',
    failed.error instanceof Error && failed.error.message === credentialMintGuidance('no-token'),
  )

  asked.length = 0
  queued = [{ kind: 'failed', failure: 'an-invented-reason' }]
  const unknownTag = await run()
  check(
    'a failure tag this build does not know is not repeated back',
    unknownTag.error instanceof Error &&
      unknownTag.error.message === credentialMintGuidance('mint-failed'),
  )

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
  // Every state the machines have, not only the ones with cards: a brief that
  // names `surface.unloaded` has to fail here too, and it is exactly the state
  // the states page cannot catch because it deliberately has no card.
  const banned = [
    ...HARNESS_STATE_PATHS,
    ...SESSION_STATE_PATHS,
    ...[...SURFACE_STATE_PATHS, ...SURFACE_UNCARDED_STATE_PATHS].map((p) => `surface.${p}`),
  ]

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
