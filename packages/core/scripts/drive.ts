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
  worktreeDiffMachine,
  WORKTREE_DIFF_STATE_PATHS,
} from '../src/machines/worktree-diff.ts'
import { parseDiff } from '../src/diff.ts'
import {
  regionOf,
  canStartAgent,
  compactedTranscript,
  invokedCommand,
  isCommandDraft,
  formatContext,
  matchCommands,
  mergeCommands,
  signatureFor,
  completionFor,
} from '../src/domain.ts'
import {
  DEFAULT_DEV_PORT,
  DEV_URL_ENV_VAR,
  chosenDevPort,
  devLaunch,
  devUrlFor,
  hotUpdateVerdict,
  portToBind,
} from '../dev-server.ts'
import { MAX_IMAGE_BYTES, parseControlRequest } from '@varnick/harness/turn'
import { credentialMintGuidance } from '@varnick/harness/credentials'
import { describeSecretsForAgent, openSecretsStore } from '@varnick/harness/secrets'
import { answerHarnessLine, type HarnessCapabilities } from '@varnick/harness/runtime'
import { hostSecretResolution } from '@varnick/harness/secret-resolution'
import { createSessionStore } from '@varnick/harness/session'
import { liveActors } from '../src/actors/live.ts'
import { discoverFrom, importSurface } from '../src/surfaces.ts'
import { seedPolicy, seedSurfaces, brokenSurfaceError } from '../src/data/seed.ts'
import { GROUPS, SCENARIOS, matches, uncoveredPaths, unknownPaths } from '../src/data/scenarios.ts'
import { cardOf, linkToCard, routeOf } from '../src/routing.ts'
import { parseMarkdown, parseInline, isSafeHref } from '../src/markdown.ts'
import type { PastedImage } from '@varnick/harness/turn'
import { frozenHarness } from '../src/actors/frozen.ts'
import { ACTOR_NAMES, UNIMPLEMENTED, seededDetail } from '../src/actors/index.ts'
import type {
  CredentialReading,
  Effort,
  Message,
  ModelId,
  PendingWorktree,
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

type TurnInput = {
  sessionId: string
  prompt: string
  model: ModelId
  effort: Effort
  images: readonly PastedImage[]
}
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
    sessionId: 'aaaaaaaa-0000-0000-0000-000000000000',
    resumed: true,
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
  // It is a *report* now — the agent summarised itself and said so — which is
  // why this arrives with no command and while a Turn is running.
  const { spy, actor: persistSession } = saveSpy(false)
  const actor = createActor(
    sessionMachine.provide({ actors: { runTurn: turnNever(), persistSession } }),
    { input: { sessionId: 'p4', messages: [{ id: 'm1', role: 'user', text: 'one' }] } },
  ).start()

  actor.send({ type: 'COMPACTED', summary: 'summary so far', tokensUsed: 10 })
  check(
    'a compaction reaches the mirror',
    await reaches(waitFor(actor, (s) => spy.calls > 0, soon)),
  )
  check(
    'a compaction mirrors the rewritten history',
    textsOf(spy.last).includes('summary so far'),
  )
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

{
  /*
    Clearing is one thing reported, where it used to be two things asked for.

    varnick owned a `/clear` that emptied this transcript and told the agent to
    forget. That covered its own command and nothing else — the CLI has a
    `/clear` too, and using it emptied the agent while the window kept the
    conversation. Two halves, two ways to ask, one of them able to disagree.

    Now `CLEAR` is a report: the runtime announces `conversation_reset` and the
    transcript follows. Whichever way the clear was asked for, the announcement
    is the same, so there is one path rather than two.
  */
  const actor = createActor(
    sessionMachine.provide({
      actors: {
        persistSession: resolves<{ ok: true }, { sessionId: string; messages: readonly Message[] }>({
          ok: true,
        }),
      },
    }),
    { input: { sessionId: 'clear-1', messages: [{ id: 'm1', role: 'agent', text: 'said something' }] } },
  ).start()

  check('a conversation starts with something in it', actor.getSnapshot().context.messages.length === 1)
  actor.send({ type: 'CLEAR' })
  check('the report empties the transcript', actor.getSnapshot().context.messages.length === 0)
  check('and the draft with it', actor.getSnapshot().context.draft === '')
  check('and the meter', actor.getSnapshot().context.tokensUsed === 0)
  actor.stop()
}

// ---------------------------------------------------------------------------
// The command menu — what a query means
// ---------------------------------------------------------------------------

{
  /*
    Ported from forge with its rules intact. Each one is here because the
    obvious alternative was tried against a live runtime and made the list
    *wider* as more was typed — which is the opposite of what a filter is for.
  */
  const agent = (name: string, description = '', argumentHint = '', aliases?: string[]) => ({
    name,
    description,
    argumentHint,
    source: 'agent' as const,
    ...(aliases ? { aliases } : {}),
  })

  const list = [
    { name: 'compact', description: 'Summarise the conversation', argumentHint: '', source: 'varnick' as const, run: () => {} },
    agent('usage', 'What this session has cost', '', ['cost']),
    agent('clear-cache', 'Drop the local cache'),
    agent('agents', 'Manage subagents', '[name]'),
    agent('mem-search', 'Search memory', '<query>'),
  ]

  check('an empty query is everything', matchCommands(list, '').length === list.length)

  check(
    'an exact name comes first',
    matchCommands(list, 'usage')[0]?.name === 'usage',
  )

  check(
    'an exact alias finds the command it belongs to',
    matchCommands(list, 'cost')[0]?.name === 'usage',
  )

  /*
    The rule that stops a hunt widening. `/usage` carries the alias `cost`, so a
    prefix rule on aliases drags it in beside `compact` and `clear-cache` on a
    lone `c` — the first keystroke returning more than no keystroke did.
  */
  check(
    'an alias never matches by prefix',
    !matchCommands(list, 'c').some((c) => c.name === 'usage'),
  )

  /*
    And the rule that stops a single letter matching everything: one character
    is inside half the names and all of the descriptions.
  */
  check(
    'one character is a prefix hunt and nothing more',
    matchCommands(list, 'm').map((c) => c.name).join(' ') === 'mem-search',
  )
  check(
    'two characters may match inside a name',
    matchCommands(list, 'em').some((c) => c.name === 'mem-search'),
  )
  check(
    'two characters may match a description',
    matchCommands(list, 'subagents').some((c) => c.name === 'agents'),
  )

  /*
    The one lie a discovery surface must not tell. A filter that falls back to
    everything on no match says a command exists when it does not.
  */
  check('a query nothing answers is nothing', matchCommands(list, 'zzzz').length === 0)

  /*
    The menu opens on the same rule it filters by.

    They were two rules: the machine asked whether a name *starts with* the
    draft, the matcher would also match inside one. Every plugin-qualified
    command fell through the gap — nothing starts with `/grill`, so the menu
    closed on the keystroke that should have found
    `mattpocock-skills:grill-with-docs`, and the list the matcher would have
    returned was never rendered.
  */
  const qualified = ['/mattpocock-skills:grill-with-docs', '/caveman:caveman', '/clear']
  check('a name is found from inside it, not only from its start', isCommandDraft('/grill', qualified))
  check(
    'and the matcher agrees, which is the point',
    matchCommands([agent('mattpocock-skills:grill-with-docs')], 'grill').length === 1,
  )
  check('one character is still a prefix hunt', !isCommandDraft('/g', qualified))
  check('a command followed by prose still closes the menu', !isCommandDraft('/clear everything', qualified))

  // Merging, which is about two different collisions.
  const merged = mergeCommands([
    { name: 'compact', description: "varnick's own", argumentHint: '', source: 'varnick' as const, run: () => {} },
    agent('compact', 'the CLI command', '[instructions]'),
    agent('caveman:caveman', '', '[lite|full]'),
    agent('caveman:caveman', 'A long description from the skill'),
  ])

  check('one row per name', merged.length === 2)
  check(
    "varnick's own wins a collision, and keeps what it does",
    merged.find((c) => c.name === 'compact')?.source === 'varnick',
  )
  check(
    'a command that is also a skill keeps the hint from one and the words from the other',
    merged.find((c) => c.name === 'caveman:caveman')?.argumentHint === '[lite|full]' &&
      (merged.find((c) => c.name === 'caveman:caveman')?.description.length ?? 0) > 0,
  )

  // The signature bar exists for the gap accepting a command opens.
  check(
    'a settled command with blank arguments shows what it takes',
    signatureFor(merged, '/caveman:caveman ')?.name === 'caveman:caveman',
  )
  check(
    'a command that takes nothing has no signature to show',
    signatureFor(merged, '/compact ') === null,
  )
  check(
    'an argument already typed answers the question the bar was asking',
    signatureFor(merged, '/caveman:caveman full') === null,
  )

  check(
    'completing a command that takes an argument leaves you mid-sentence',
    completionFor(agent('agents', '', '[name]')) === '/agents ',
  )
  check(
    'completing one that takes nothing finishes the draft',
    completionFor(agent('clear-cache')) === '/clear-cache',
  )
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
  /*
    Clearing is accepted in every state, including mid-turn.

    **This assertion used to say the opposite**, and its reason was right for
    what `CLEAR` was: a command, and wiping the transcript mid-stream would drop
    a reply that was still arriving. It is a report now — the runtime announcing
    that the conversation was reset — and it arrives while the very Turn that
    typed `/clear` is still running. Refused there, the window kept a
    conversation the agent had already thrown away.

    Measured in the running app before this changed: the announcement fired at
    `running=turn-1 finished=false`, and the machine dropped it.

    A state can decide what to do about a fact. It cannot decline one.
  */
  const actor = createActor(
    sessionMachine.provide({ actors: { runTurn: turnNever() } }),
    { input: { sessionId: 's11' } },
  ).start()

  check('an empty session has nothing to clear, but accepts the event', actor.getSnapshot().can({ type: 'CLEAR' }))

  actor.send({ type: 'EDIT_DRAFT', text: 'do a thing' })
  actor.send({ type: 'SEND' })
  check('a report is accepted mid-turn, because it has already happened', actor.getSnapshot().can({ type: 'CLEAR' }))
  actor.send({ type: 'CLEAR' })
  check('and it empties the transcript there too', actor.getSnapshot().context.messages.length === 0)

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
    },
  }).start()

  actor.send({ type: 'CLEAR' })
  const cleared = actor.getSnapshot().context
  check('clearing resets the transcript and the count together', cleared.messages.length === 0 && cleared.tokensUsed === 0)
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
  /*
    A compaction is something the agent does and varnick hears about.

    It used to be something varnick asked for: `COMPACT`, an actor, and a
    `turn.compacting` state to watch it in. That covered the compactions varnick
    asked for and no others — the CLI has its own `/compact`, and an
    auto-compaction has no command at all — so the two most common ones rewrote
    the agent's context while the transcript kept every message it had replaced.

    So the assertions changed shape with the thing they are about. There is no
    failure path left to test, because varnick performs no act that can fail:
    a compaction that did not happen is a transcript that did not change, which
    is what the window is already showing.
  */
  const actor = createActor(
    sessionMachine.provide({
      actors: {
        runTurn: fromPromise<TurnOutput, TurnInput>(async () => ({
          text: 'reply',
          tokensUsed: 8_000,
        })),
      },
    }),
    { input: { sessionId: 's14' } },
  ).start()

  actor.send({ type: 'EDIT_DRAFT', text: 'first' })
  actor.send({ type: 'SEND' })
  await waitFor(actor, (s) => regionOf(s.value, 'turn') === 'idle')
  check('a completed turn records what it cost', actor.getSnapshot().context.tokensUsed === 8_000)

  actor.send({ type: 'COMPACTED', summary: 'what was said, in short', tokensUsed: 300 })
  const after = actor.getSnapshot().context
  check('a compaction replaces the history', after.messages.length === 1)
  check('with the summary the agent produced', after.messages[0]?.text.includes('what was said, in short') === true)
  check('and says how much was replaced', after.messages[0]?.text.includes('earlier messages') === true)
  check('and the meter follows the measurement', after.tokensUsed === 300)
  check('the turn is not disturbed by it', regionOf(actor.getSnapshot().value, 'turn') === 'idle')
  actor.stop()
}

{
  /*
    The case that made this a report rather than a command: it arrives *during*
    an answer. A context fills up while the agent is writing, and the CLI's own
    `/compact` is itself a Turn. A state that refused it would refuse it in
    exactly the circumstance it happens in — which is the mistake `CLEAR` made
    and was measured making, in the running app.
  */
  const actor = createActor(
    sessionMachine.provide({ actors: { runTurn: turnNever() } }),
    { input: { sessionId: 's14b', draft: 'go' } },
  ).start()

  actor.send({ type: 'SEND' })
  check('a compaction is accepted mid-answer', actor.getSnapshot().can({ type: 'COMPACTED', summary: 's', tokensUsed: 1 }))
  actor.send({ type: 'COMPACTED', summary: 'the middle of an answer', tokensUsed: 42 })
  const during = actor.getSnapshot()
  check('and the transcript follows while the turn keeps running', during.context.messages.length === 1)
  check('the turn is still answering', regionOf(during.value, 'turn').startsWith('answering'))
  actor.stop()
}

{
  // A measurement or nothing. A Session that will not say what it now holds
  // leaves the meter where it was — too high, and visibly so — rather than
  // reading zero over a conversation that exists.
  const actor = createActor(
    sessionMachine.provide({ actors: { runTurn: turnNever() } }),
    { input: { sessionId: 's15', messages: [{ id: 'm1', role: 'user', text: 'one' }], tokensUsed: 5_000 } },
  ).start()

  actor.send({ type: 'COMPACTED', summary: 'a summary', tokensUsed: null })
  const after = actor.getSnapshot().context
  check('an unmeasured compaction still replaces the transcript', after.messages.length === 1)
  check('and leaves the meter alone rather than inventing a figure', after.tokensUsed === 5_000)
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
    readCommands: unreached,
    listWorktrees: unreached,
    readWorktreeDiff: unreached,
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
// Harness — which Worktrees hold Core changes nobody has merged
// ---------------------------------------------------------------------------

{
  /*
    The region exists so that nothing the agent finished waits unnoticed, and
    every assertion here is about one of three things: that a listing is asked
    for without anybody deciding to, that nothing-pending and a listing that
    failed stay two different answers, and that neither of them can disturb the
    conversation running beside them.

    What cannot be asserted at this seam is where the data came from — that is
    src-tauri/src/bridge.rs routing the call to the runtime, and
    packages/harness/src/worktrees.ts running git. What *can* be asserted here
    is that Core never says what the answer should be about: see the input
    assertion below.
  */
  const seen = (worktrees: readonly PendingWorktree[]) =>
    resolves<{ worktrees: readonly PendingWorktree[] }, Record<string, never>>({ worktrees })

  const oneEntry: PendingWorktree = {
    path: '/Users/dev/code/varnick/.claude/worktrees/49',
    branch: 'ticket/49',
    commits: 3,
    changed: ['packages/core/src/machines/harness.ts'],
    touchesFence: false,
  }

  {
    // Nobody asked. The region is in flight from the moment the machine exists,
    // because there is no decision to make: the other three regions rest until
    // a credential, a check or a start is asked for, and a listing is neither
    // expensive nor a choice.
    const actor = createActor(
      harnessMachine.provide({ actors: { listWorktrees: never<{ worktrees: readonly PendingWorktree[] }, Record<string, never>>() } }),
      { input: { policy: seedPolicy } },
    ).start()
    check('a fresh Harness is already asking which worktrees are pending', regionOf(actor.getSnapshot().value, 'review') === 'listing')
    check(
      'and a second ask while one is in flight is refused rather than queued',
      !actor.getSnapshot().can({ type: 'LIST_WORKTREES' }),
    )
    actor.stop()
  }

  {
    // The renderer asks what is pending. It does not get to say what the answer
    // should be about — no worktree name, no path, no ref. That is what keeps
    // agent-authored input out of the host-side git call.
    const inputs: unknown[] = []
    const actor = createActor(
      harnessMachine.provide({
        actors: {
          listWorktrees: fromPromise<{ worktrees: readonly PendingWorktree[] }, Record<string, never>>(
            async ({ input }) => {
              inputs.push(input)
              return { worktrees: [] }
            },
          ),
        },
      }),
      { input: { policy: seedPolicy } },
    ).start()
    await waitFor(actor, (s) => regionOf(s.value, 'review') === 'empty', soon)
    check('the listing is asked for with nothing to narrow it', JSON.stringify(inputs) === '[{}]')
    actor.stop()
  }

  {
    const actor = createActor(
      harnessMachine.provide({ actors: { listWorktrees: seen([oneEntry]) } }),
      { input: { policy: seedPolicy } },
    ).start()
    await waitFor(actor, (s) => regionOf(s.value, 'review') === 'listed', soon)
    check('a listing that found something reaches listed', regionOf(actor.getSnapshot().value, 'review') === 'listed')
    check('and the entry is held as git described it', JSON.stringify(actor.getSnapshot().context.worktrees) === JSON.stringify([oneEntry]))
    actor.stop()
  }

  {
    /*
      The ticket's own line: `review.empty` is a real state and is not `listed`
      with a count of zero.

      Nothing pending and a listing that failed are different problems with
      different copy, and a surface branching on `worktrees.length === 0` would
      have to invent the difference back — which is the branch that eventually
      renders "nothing is waiting to be merged" over a git that never answered.
    */
    const actor = createActor(
      harnessMachine.provide({ actors: { listWorktrees: seen([]) } }),
      { input: { policy: seedPolicy } },
    ).start()
    await waitFor(actor, (s) => regionOf(s.value, 'review') === 'empty', soon)
    check('nothing pending reaches empty rather than listed', regionOf(actor.getSnapshot().value, 'review') === 'empty')
    check('and empty holds no entries', actor.getSnapshot().context.worktrees.length === 0)
    actor.stop()
  }

  {
    const actor = createActor(
      harnessMachine.provide({
        actors: {
          listWorktrees: rejects<{ worktrees: readonly PendingWorktree[] }, Record<string, never>>(
            'fatal: not a git repository',
          ),
        },
      }),
      { input: { policy: seedPolicy } },
    ).start()
    await waitFor(actor, (s) => regionOf(s.value, 'review') === 'listFailed', soon)
    check('a git that failed reaches listFailed', regionOf(actor.getSnapshot().value, 'review') === 'listFailed')
    check('carrying what it said', actor.getSnapshot().context.worktreeError === 'fatal: not a git repository')
    actor.stop()
  }

  {
    // A failed re-listing leaves no stale list standing. The same rule the
    // credential kind follows: a fact about something nobody can currently see
    // is a fact the surface would present as current.
    let listings = 0
    const actor = createActor(
      harnessMachine.provide({
        actors: {
          listWorktrees: fromPromise<{ worktrees: readonly PendingWorktree[] }, Record<string, never>>(
            async () => {
              if (listings++ === 0) return { worktrees: [oneEntry] }
              throw new Error('fatal: not a git repository')
            },
          ),
        },
      }),
      { input: { policy: seedPolicy } },
    ).start()
    await waitFor(actor, (s) => regionOf(s.value, 'review') === 'listed', soon)
    actor.send({ type: 'LIST_WORKTREES' })
    await waitFor(actor, (s) => regionOf(s.value, 'review') === 'listFailed', soon)
    check('a failed re-listing keeps no list it can no longer vouch for', actor.getSnapshot().context.worktrees.length === 0)
    actor.stop()
  }

  {
    // Every resting state can be asked again. A listing is a fact about a
    // filesystem that changes while varnick runs — an agent finishes a branch,
    // a developer merges one — so none of the three is terminal.
    for (const enterReview of ['listed', 'empty', 'listFailed'] as const) {
      const actor = createActor(
        harnessMachine.provide({ actors: { listWorktrees: never<{ worktrees: readonly PendingWorktree[] }, Record<string, never>>() } }),
        { input: { policy: seedPolicy, enterReview, worktrees: [oneEntry] } },
      ).start()
      check(`a card parked in review.${enterReview} is in review.${enterReview}`, regionOf(actor.getSnapshot().value, 'review') === enterReview)
      actor.send({ type: 'LIST_WORKTREES' })
      check(`review.${enterReview} can be listed again`, regionOf(actor.getSnapshot().value, 'review') === 'listing')
      actor.stop()
    }
  }

  {
    /*
      The region is independent of the other three, which is the whole reason it
      is a region rather than a field.

      A git that will not answer says nothing about the credential, the sandbox
      or the agent — and an agent that crashed says nothing about what is
      waiting to be merged. A status enum shared with the rest would make each
      of those a lie in one direction or the other.
    */
    const actor = createActor(
      harnessMachine.provide({
        actors: {
          listWorktrees: rejects<{ worktrees: readonly PendingWorktree[] }, Record<string, never>>('fatal: no git'),
          readCredential: resolves<CredentialReading, Record<string, never>>({ source: 'keychain', kind: 'subscription' }),
          checkSandbox: resolves<{ ok: true }, { policy: SandboxPolicy }>({ ok: true }),
        },
      }),
      { input: { policy: seedPolicy } },
    ).start()

    await waitFor(actor, (s) => regionOf(s.value, 'review') === 'listFailed', soon)
    actor.send({ type: 'READ_CREDENTIAL' })
    await waitFor(actor, (s) => regionOf(s.value, 'credential') === 'present', soon)
    actor.send({ type: 'CHECK_SANDBOX' })
    await waitFor(actor, (s) => regionOf(s.value, 'sandbox') === 'available', soon)
    actor.send({ type: 'START' })

    check(
      'a listing that failed refuses nothing else',
      regionOf(actor.getSnapshot().value, 'agent') === 'starting' &&
        regionOf(actor.getSnapshot().value, 'review') === 'listFailed',
    )
    actor.stop()
  }

  {
    /*
      The live actor, against a host that answers.

      One call and no other, and — the part worth taking here rather than at the
      bridge's own seam — a host that volunteered a diff cannot get one into the
      machine's context. The list is summaries; the hunks are fetched for the
      worktree a developer opened.
    */
    const realInternals = (globalThis as Record<string, unknown>).__TAURI_INTERNALS__
    const asked: string[] = []
    ;(globalThis as Record<string, unknown>).__TAURI_INTERNALS__ = {
      invoke: async (_command: string, payload: { request: { kind: string } }) => {
        asked.push(payload.request.kind)
        if (payload.request.kind !== 'list-worktrees') throw { failure: 'malformed' }
        return {
          worktrees: [{ ...oneEntry, diff: '@@ -1 +1 @@ VOLUNTEERED' }],
        }
      },
    }

    const actor = createActor(
      harnessMachine.provide({ actors: { listWorktrees: liveActors().listWorktrees } }),
      { input: { policy: seedPolicy } },
    ).start()
    await waitFor(actor, (s) => regionOf(s.value, 'review') === 'listed', soon)

    check('the live listing asks the host for the list and nothing else', asked.join('|') === 'list-worktrees')
    const held = JSON.stringify(actor.getSnapshot().context.worktrees)
    check('and what it holds is what the entry declares, field for field', held === JSON.stringify([oneEntry]))
    check('nothing the host volunteered rides along', !held.includes('VOLUNTEERED'))
    actor.stop()

    if (realInternals === undefined) delete (globalThis as Record<string, unknown>).__TAURI_INTERNALS__
    else (globalThis as Record<string, unknown>).__TAURI_INTERNALS__ = realInternals
  }
}

// ---------------------------------------------------------------------------
// The diff of one Worktree — what git printed, read as what changed
// ---------------------------------------------------------------------------

{
  /*
    The parser between git and the screen.

    Pure, and here rather than in a component for the reason ADR-0001 gives for
    everything else on this surface: a rule inside a `.tsx` is a rule this script
    cannot reach, and this is the rule that decides whether a Fence hunk is drawn
    as one. It is the same arrangement `markdown.ts` has beside it.

    What is asserted is what a reviewer's eye depends on: that every hunk git
    printed becomes a hunk, that a path is classified by the Harness's one
    definition of Fence rather than by a second list written here, and that
    nothing on the way through can quietly drop a file.
  */
  const diff = [
    'diff --git a/packages/core/src/App.tsx b/packages/core/src/App.tsx',
    'index 1111111..2222222 100644',
    '--- a/packages/core/src/App.tsx',
    '+++ b/packages/core/src/App.tsx',
    '@@ -12,7 +12,7 @@ export function App() {',
    ' const route = routeOf(hash)',
    '-  return <DesignedPage />',
    '+  return <DesignedPage wide />',
    ' }',
    'diff --git a/src-tauri/src/bridge.rs b/src-tauri/src/bridge.rs',
    'index 3333333..4444444 100644',
    '--- a/src-tauri/src/bridge.rs',
    '+++ b/src-tauri/src/bridge.rs',
    '@@ -164,6 +164,7 @@ pub fn route_of(kind: &str) -> Option<Route> {',
    '         | "list-worktrees" => Some(Route::Runtime),',
    '+        "read-anything" => Some(Route::Runtime),',
    '@@ -900,3 +901,4 @@ mod tests {',
    '+    // and a second hunk in the same file',
    '',
  ].join('\n')

  const files = parseDiff(diff)

  check('every file git named is a file', files.length === 2)
  check(
    'and it is named as git names it, repository-relative',
    files.map((file) => file.path).join('|') === 'packages/core/src/App.tsx|src-tauri/src/bridge.rs',
  )
  check('a file with two hunks keeps both', files[1]?.hunks.length === 2)
  check('and one with a single hunk keeps one', files[0]?.hunks.length === 1)

  /*
    The one visual requirement, decided here.

    `isFencePath` is the Harness's, imported rather than restated: three
    mechanisms key off that list — the pending list's flag, the Preview dialog,
    and this — and a fourth glob written here would drift from the other three
    invisibly. Each caller goes on working, and the one that fell behind stops
    marking a file the others still mark.
  */
  check('a path that decides what the agent may do is Fence', files[1]?.fence === true)
  check('and Core that does not is not', files[0]?.fence === false)

  const hunk = files[1]?.hunks[0]
  check(
    'the hunk keeps its @@ header, as git wrote it',
    hunk?.header.startsWith('@@ -164,6 +164,7 @@') === true,
  )
  check(
    'a line says which of the three it is',
    hunk?.lines.map((line) => line.kind).join('|') === 'context|add',
  )
  check(
    'and its text is the line without the marker, so the view draws the marker',
    hunk?.lines[1]?.text === '        "read-anything" => Some(Route::Runtime),',
  )

  {
    // A removal is a line, not an absence. The `-` half of a hunk is most of
    // what a reviewer is reading — what is being taken out.
    const removed = files[0]?.hunks[0]?.lines.filter((line) => line.kind === 'remove') ?? []
    check('a removed line survives as a removed line', removed.length === 1)
    check('carrying what was removed', removed[0]?.text === '  return <DesignedPage />')
  }

  // Nothing at all is no files. `worktreeDiff.loaded` with an empty diff is a
  // branch that changed nothing tracked, which is a real answer — the view says
  // so rather than showing an empty frame.
  check('an empty diff is no files', parseDiff('').length === 0)
  check('and so is whitespace', parseDiff('\n\n').length === 0)

  {
    // A file with no hunks git can print still has to appear. A binary blob
    // added under src-tauri is a Fence change, and it is exactly the change a
    // hunk-only renderer would leave off the screen entirely.
    const binary = parseDiff(
      [
        'diff --git a/src-tauri/icons/icon.png b/src-tauri/icons/icon.png',
        'new file mode 100644',
        'Binary files /dev/null and b/src-tauri/icons/icon.png differ',
        '',
      ].join('\n'),
    )
    check('a binary file is still a file', binary.length === 1)
    check('marked Fence when it is one', binary[0]?.fence === true)
    check(
      'with no hunks and a reason there are none',
      binary[0]?.hunks.length === 0 && binary[0]?.note === 'binary',
    )
  }

  {
    // A deletion has no `+++ b/…` to take a name from, and a file that lost its
    // name would be a file nobody could see was deleted.
    const deleted = parseDiff(
      [
        'diff --git a/packages/harness/src/old.ts b/packages/harness/src/old.ts',
        'deleted file mode 100644',
        '--- a/packages/harness/src/old.ts',
        '+++ /dev/null',
        '@@ -1,2 +0,0 @@',
        '-export const gone = true',
        '',
      ].join('\n'),
    )
    check('a deleted file keeps the name it had', deleted[0]?.path === 'packages/harness/src/old.ts')
    check('and says it was deleted', deleted[0]?.note === 'deleted')
    check('and is Fence, because that is where it was', deleted[0]?.fence === true)
  }

  {
    /*
      A rename out of the Fence is a Fence change, and the path it arrives at is
      not one.

      The case a new-path-only classification gets wrong in the direction that
      matters: moving `sandbox.ts` into `packages/core/` is an edit to what
      decides the boundary, rendered as an ordinary Core change.
    */
    const moved = parseDiff(
      [
        'diff --git a/packages/harness/src/sandbox.ts b/packages/core/src/sandbox.ts',
        'similarity index 98%',
        'rename from packages/harness/src/sandbox.ts',
        'rename to packages/core/src/sandbox.ts',
        '',
      ].join('\n'),
    )
    check(
      'a renamed file is named where it landed',
      moved[0]?.path === 'packages/core/src/sandbox.ts',
    )
    check(
      'and says where it came from',
      moved[0]?.note === 'renamed from packages/harness/src/sandbox.ts',
    )
    check('a move out of the Fence is still a Fence change', moved[0]?.fence === true)
  }

  {
    // The `diff --git` line is the only place a path can be read when git
    // printed no `---`/`+++` pair — a pure mode change does not.
    const mode = parseDiff(
      [
        'diff --git a/src-tauri/build.rs b/src-tauri/build.rs',
        'old mode 100644',
        'new mode 100755',
        '',
      ].join('\n'),
    )
    check(
      'a file git described without a hunk is still named',
      mode[0]?.path === 'src-tauri/build.rs',
    )
    check('and still Fence', mode[0]?.fence === true)
  }

  {
    /*
      A line that begins with `--` inside a hunk is a removed line, not a header.

      The parse bug that hides a hunk: `--- a/x` is a header and `--foo` is a
      removal, and a parser that tests only the first characters outside a hunk's
      bounds eats the second. In a diff of this repository's own agent argv, that
      is a removed flag disappearing from the review.
    */
    const tricky = parseDiff(
      [
        'diff --git a/src-tauri/src/agent.rs b/src-tauri/src/agent.rs',
        '@@ -1,3 +1,3 @@',
        '---dangerously-skip-permissions',
        '+++safe',
        ' end',
        '',
      ].join('\n'),
    )
    check(
      'a removed line that looks like a header is a removed line',
      tricky[0]?.hunks[0]?.lines.map((line) => line.kind).join('|') === 'remove|add|context',
    )
    check(
      'with its text intact',
      tricky[0]?.hunks[0]?.lines[0]?.text === '--dangerously-skip-permissions',
    )
  }

  {
    // `\ No newline at end of file` is git talking about the file rather than a
    // line of it, and rendering it as context would put a line in the diff that
    // is not in the file.
    const noNewline = parseDiff(
      [
        'diff --git a/a.txt b/a.txt',
        '@@ -1 +1 @@',
        '-one',
        '+two',
        '\\ No newline at end of file',
        '',
      ].join('\n'),
    )
    check(
      'git talking about the file is not a line of it',
      noNewline[0]?.hunks[0]?.lines.at(-1)?.kind === 'meta',
    )
  }

  {
    // An empty context line arrives as an empty string rather than a space from
    // anything that trims. It is still a line of the file.
    const blank = parseDiff(
      ['diff --git a/a.txt b/a.txt', '@@ -1,3 +1,3 @@', ' one', '', '+three', ''].join('\n'),
    )
    check('an empty line inside a hunk is context', blank[0]?.hunks[0]?.lines[1]?.kind === 'context')
  }
}

// ---------------------------------------------------------------------------
// The diff view — opening one Worktree, reading it, and failing to
// ---------------------------------------------------------------------------

{
  /*
    A child per opened diff, like a Surface, and for the same reasons: it has
    something to wait on, it can fail, and it must fail without disturbing
    anything beside it.

    What is asserted is the shape of the opening — that only a worktree git
    listed can be opened, that the call carries nothing but which one, and that
    a failure keeps a reason and a way back.
  */
  const fence: PendingWorktree = {
    path: '/Users/dev/code/varnick/.claude/worktrees/48',
    branch: 'ticket/48-launch-preview',
    commits: 4,
    changed: ['src-tauri/src/bridge.rs'],
    touchesFence: true,
  }
  const plain: PendingWorktree = {
    path: '/Users/dev/code/varnick/.claude/worktrees/50',
    branch: 'ticket/50-diff-view',
    commits: 2,
    changed: ['packages/core/src/pages/DesignedPage.tsx'],
    touchesFence: false,
  }

  const HUNKS =
    'diff --git a/src-tauri/src/bridge.rs b/src-tauri/src/bridge.rs\n@@ -1 +1 @@\n-was\n+is\n'

  const listed = (readWorktreeDiff: unknown) =>
    createActor(
      harnessMachine.provide({
        actors: {
          listWorktrees: never<{ worktrees: readonly PendingWorktree[] }, Record<string, never>>(),
          worktreeDiff: worktreeDiffMachine.provide({
            actors: { readWorktreeDiff: readWorktreeDiff as never },
          }),
        },
      }),
      { input: { policy: seedPolicy, enterReview: 'listed', worktrees: [fence, plain] } },
    ).start()

  const diffOf = (actor: ReturnType<typeof listed>) => actor.getSnapshot().context.worktreeDiff

  {
    const actor = listed(never<{ diff: string }, { path: string }>())
    check('nothing is open until something is opened', diffOf(actor) === null)
    actor.send({ type: 'OPEN_WORKTREE', path: fence.path })
    check('opening a listed worktree gives it a diff of its own', diffOf(actor) !== null)
    check(
      'which starts by loading, because there is something to wait for',
      String(diffOf(actor)?.getSnapshot().value) === 'loading',
    )
    check(
      'and it knows which worktree it is of',
      diffOf(actor)?.getSnapshot().context.worktree.path === fence.path,
    )
    actor.stop()
  }

  {
    /*
      A path nobody listed cannot be opened.

      The renderer names which of git's own entries it wants and nothing else, so
      the machine checks the name against the list it was given rather than
      forwarding it. The host checks again against git — see
      packages/harness/src/worktrees.ts — and neither check is the other's
      excuse: this one is what stops the surface offering to open something that
      was never on it.
    */
    const actor = listed(never<{ diff: string }, { path: string }>())
    check(
      'a worktree that is not in the listing is refused',
      !actor.getSnapshot().can({ type: 'OPEN_WORKTREE', path: '/somewhere/else' }),
    )
    actor.send({ type: 'OPEN_WORKTREE', path: '/somewhere/else' })
    check('and sending it anyway opens nothing', diffOf(actor) === null)
    actor.stop()
  }

  {
    // A second worktree cannot be opened over the first. One diff is open at a
    // time, so the control to open another appears when this one is closed —
    // `can()` answering, rather than a button being hidden.
    const actor = listed(never<{ diff: string }, { path: string }>())
    actor.send({ type: 'OPEN_WORKTREE', path: fence.path })
    check(
      'with one open, opening another is refused rather than leaking the first',
      !actor.getSnapshot().can({ type: 'OPEN_WORKTREE', path: plain.path }),
    )
    check('closing is offered while one is open', actor.getSnapshot().can({ type: 'CLOSE_WORKTREE' }))
    actor.send({ type: 'CLOSE_WORKTREE' })
    check('closing puts the diff away', diffOf(actor) === null)
    check('and there is nothing left to close', !actor.getSnapshot().can({ type: 'CLOSE_WORKTREE' }))
    check(
      'so the other one can be opened now',
      actor.getSnapshot().can({ type: 'OPEN_WORKTREE', path: plain.path }),
    )
    actor.stop()
  }

  {
    // The call carries which worktree and nothing else. There is no field for a
    // ref, a range or a command: the host resolves the ref from git's own
    // listing, and a second way to say it would be a second way to be wrong.
    const asked: unknown[] = []
    const actor = listed(
      fromPromise<{ diff: string }, { path: string }>(async ({ input }) => {
        asked.push(input)
        return { diff: HUNKS }
      }),
    )
    actor.send({ type: 'OPEN_WORKTREE', path: fence.path })
    await waitFor(
      actor,
      (s) => String(s.context.worktreeDiff?.getSnapshot().value) === 'loaded',
      soon,
    )
    check(
      'the read names one worktree and nothing else',
      JSON.stringify(asked) === JSON.stringify([{ path: fence.path }]),
    )
    check(
      'and what came back is held as git printed it',
      diffOf(actor)?.getSnapshot().context.diff === HUNKS,
    )
    actor.stop()
  }

  {
    // A branch whose commits changed nothing tracked. `loaded` with an empty
    // diff, never `failed`: git answered, and the answer was nothing.
    const actor = listed(resolves<{ diff: string }, { path: string }>({ diff: '' }))
    actor.send({ type: 'OPEN_WORKTREE', path: plain.path })
    await waitFor(
      actor,
      (s) => String(s.context.worktreeDiff?.getSnapshot().value) === 'loaded',
      soon,
    )
    check('an empty diff is a loaded diff', String(diffOf(actor)?.getSnapshot().value) === 'loaded')
    check('and it is empty rather than absent', diffOf(actor)?.getSnapshot().context.diff === '')
    actor.stop()
  }

  {
    const actor = listed(rejects<{ diff: string }, { path: string }>('fatal: bad object HEAD'))
    actor.send({ type: 'OPEN_WORKTREE', path: fence.path })
    await waitFor(
      actor,
      (s) => String(s.context.worktreeDiff?.getSnapshot().value) === 'failed',
      soon,
    )

    const child = diffOf(actor)!
    check('a read that failed reaches failed', String(child.getSnapshot().value) === 'failed')
    check('carrying what git said', child.getSnapshot().context.error === 'fatal: bad object HEAD')
    check(
      'a failed read offers a retry, because the state has a handler',
      child.getSnapshot().can({ type: 'RETRY' }),
    )
    check('and holds no diff it cannot vouch for', child.getSnapshot().context.diff === null)

    child.send({ type: 'RETRY' })
    check('retrying loads again', String(child.getSnapshot().value) === 'loading')
    check('and says which attempt this is', child.getSnapshot().context.attempts === 2)
    check(
      'with the previous reason cleared, so a second failure is not read as the first',
      child.getSnapshot().context.error === null,
    )
    check('a diff still loading has nothing to retry', !child.getSnapshot().can({ type: 'RETRY' }))
    actor.stop()
  }

  {
    // A loaded diff has no retry, for the same reason a loaded Surface has none:
    // the state has no handler. Nothing is hidden.
    const actor = listed(resolves<{ diff: string }, { path: string }>({ diff: HUNKS }))
    actor.send({ type: 'OPEN_WORKTREE', path: fence.path })
    await waitFor(
      actor,
      (s) => String(s.context.worktreeDiff?.getSnapshot().value) === 'loaded',
      soon,
    )
    check('a loaded diff accepts no retry', !diffOf(actor)!.getSnapshot().can({ type: 'RETRY' }))
    actor.stop()
  }

  {
    /*
      A diff that failed disturbs nothing beside it.

      The same isolation a Surface has, and it matters more here: a developer
      reviewing a branch is doing it *while* an agent works, and a git that will
      not answer must not touch the conversation, the listing, or the agent.
    */
    const actor = createActor(
      harnessMachine.provide({
        actors: {
          listWorktrees: resolves<{ worktrees: readonly PendingWorktree[] }, Record<string, never>>({
            worktrees: [fence, plain],
          }),
          readCredential: resolves<CredentialReading, Record<string, never>>({
            source: 'keychain',
            kind: 'subscription',
          }),
          checkSandbox: resolves<{ ok: true }, { policy: SandboxPolicy }>({ ok: true }),
          worktreeDiff: worktreeDiffMachine.provide({
            actors: {
              readWorktreeDiff: rejects<{ diff: string }, { path: string }>('fatal: no git'),
            },
          }),
        },
      }),
      { input: { policy: seedPolicy } },
    ).start()

    await waitFor(actor, (s) => regionOf(s.value, 'review') === 'listed', soon)
    actor.send({ type: 'OPEN_WORKTREE', path: fence.path })
    await waitFor(
      actor,
      (s) => String(s.context.worktreeDiff?.getSnapshot().value) === 'failed',
      soon,
    )

    check(
      'the listing beside it is untouched',
      regionOf(actor.getSnapshot().value, 'review') === 'listed',
    )
    check('and still holds every entry', actor.getSnapshot().context.worktrees.length === 2)
    actor.send({ type: 'READ_CREDENTIAL' })
    await waitFor(actor, (s) => regionOf(s.value, 'credential') === 'present', soon)
    check(
      'a diff that would not load refuses nothing else',
      regionOf(actor.getSnapshot().value, 'credential') === 'present',
    )
    actor.stop()
  }

  {
    // Re-listing while a diff is open leaves it open. The list is a fact about a
    // filesystem that changes while varnick runs, and refreshing it must not
    // shut what somebody is reading.
    const actor = listed(never<{ diff: string }, { path: string }>())
    actor.send({ type: 'OPEN_WORKTREE', path: fence.path })
    actor.send({ type: 'LIST_WORKTREES' })
    check('a fresh listing does not close an open diff', diffOf(actor) !== null)
    check(
      'and the region is listing again',
      regionOf(actor.getSnapshot().value, 'review') === 'listing',
    )
    actor.stop()
  }

  {
    /*
      The live actor, against a host that answers.

      One call, carrying one path, and what comes back is the text git printed —
      not a shape this side assembled. A host that volunteered a parsed file list
      could not get one into the machine, because there is nowhere for it to
      arrive.
    */
    const realInternals = (globalThis as Record<string, unknown>).__TAURI_INTERNALS__
    const asked: { kind: string; path?: string }[] = []
    ;(globalThis as Record<string, unknown>).__TAURI_INTERNALS__ = {
      invoke: async (_command: string, payload: { request: { kind: string; path?: string } }) => {
        asked.push(payload.request)
        if (payload.request.kind !== 'read-worktree-diff') throw { failure: 'malformed' }
        return { diff: HUNKS, files: ['VOLUNTEERED'] }
      },
    }

    const actor = listed(liveActors().readWorktreeDiff)
    actor.send({ type: 'OPEN_WORKTREE', path: fence.path })
    await waitFor(
      actor,
      (s) => String(s.context.worktreeDiff?.getSnapshot().value) === 'loaded',
      soon,
    )

    check(
      'the live read asks the host for one diff and nothing else',
      asked.map((request) => request.kind).join('|') === 'read-worktree-diff',
    )
    check('naming the worktree that was opened', asked[0]?.path === fence.path)
    const held = JSON.stringify(diffOf(actor)?.getSnapshot().context)
    check('and nothing the host volunteered rides along', !held.includes('VOLUNTEERED'))
    actor.stop()

    if (realInternals === undefined) delete (globalThis as Record<string, unknown>).__TAURI_INTERNALS__
    else (globalThis as Record<string, unknown>).__TAURI_INTERNALS__ = realInternals
  }
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
    const actor = createActor(frozenHarness(scenario.surfaceOutcome, scenario.diffOutcome), {
      input: scenario.input,
    }).start()

    /*
      A diff arrives by event too, and for the same reason a Surface does: a
      developer opens one. The path comes from the scenario's own listing, so a
      card that opened something it does not show would be refused by the guard
      rather than drawn.
    */
    if (scenario.opensWorktree) {
      actor.send({ type: 'OPEN_WORKTREE', path: scenario.opensWorktree })
      for (const path of scenario.covers) {
        if (!path.startsWith('worktreeDiff.')) continue
        const want = path.slice('worktreeDiff.'.length)
        await reaches(
          waitFor(
            actor,
            (s) => String(s.context.worktreeDiff?.getSnapshot().value) === want,
            soon,
          ),
        )
      }
    }

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
    // parent's context instead of out of its state value. An open diff is one
    // too, and there is at most one.
    for (const ref of snap.context.surfaces) {
      reached.add(`surface.${String(ref.getSnapshot().value)}`)
    }
    if (snap.context.worktreeDiff) {
      reached.add(`worktreeDiff.${String(snap.context.worktreeDiff.getSnapshot().value)}`)
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
// A pasted picture — that it reaches the Turn and the record says it did
// ---------------------------------------------------------------------------

{
  const png = (data: string): PastedImage => ({ mediaType: 'image/png', data })
  const shot = (): PastedImage => png('aGVsbG8=')

  {
    // A screenshot with no caption is a message. "look at this" is the whole
    // reason somebody pastes one, and a guard on the draft alone would have
    // made it unsendable.
    const actor = createActor(sessionMachine.provide({ actors: { runTurn: turnNever() } }), {
      input: { sessionId: 'img-1' },
    }).start()
    check('an empty composer refuses SEND', !actor.getSnapshot().can({ type: 'SEND' }))
    actor.send({ type: 'ATTACH_IMAGES', images: [shot()] })
    check('a picture on its own is sendable', actor.getSnapshot().can({ type: 'SEND' }))
    check('and it is held beside the draft', actor.getSnapshot().context.pending.length === 1)
    actor.send({ type: 'DETACH_IMAGE', index: 0 })
    check('taking it back empties the composer again', !actor.getSnapshot().can({ type: 'SEND' }))
    actor.stop()
  }

  {
    /*
      The ordering bug this shape exists to avoid: the actor's input is read on
      entry to `answering`, so clearing the attachments in the same action that
      appends the message would send the message without its pictures. They are
      cleared on exit instead, which is why this asserts what the actor was
      *handed* rather than what the context held afterwards.
    */
    const seen: PastedImage[][] = []
    const actor = createActor(
      sessionMachine.provide({
        actors: {
          runTurn: fromPromise<TurnOutput, TurnInput>(async ({ input }) => {
            seen.push([...input.images])
            return { text: 'ok', tokensUsed: 1 }
          }),
        },
      }),
      { input: { sessionId: 'img-2' } },
    ).start()

    actor.send({ type: 'ATTACH_IMAGES', images: [shot(), png('d29ybGQ=')] })
    actor.send({ type: 'EDIT_DRAFT', text: 'what is wrong here' })
    actor.send({ type: 'SEND' })
    check('the Turn is handed the pictures that were pasted', seen[0]?.length === 2)

    await waitFor(actor, (s) => regionOf(s.value, 'turn') === 'idle', soon)
    const after = actor.getSnapshot().context
    check('and the composer is empty afterwards', after.pending.length === 0)
    // The record has to say a picture went, or a message reading "what is
    // wrong here" is a transcript that lies about the conversation.
    const sent = after.messages.find((m) => m.role === 'user')
    check('the transcript records how many went with it', sent?.attachments === 2)
    check('as a count, not as the bytes — the mirror stays readable', JSON.stringify(sent).length < 200)
    actor.stop()
  }

  {
    // Clearing takes the attachments with it. A picture pasted for a
    // conversation the agent has forgotten is a question about nothing.
    const actor = createActor(sessionMachine.provide({ actors: { runTurn: turnNever() } }), {
      input: { sessionId: 'img-3' },
    }).start()
    actor.send({ type: 'ATTACH_IMAGES', images: [shot()] })
    actor.send({ type: 'CLEAR' })
    check('a clear drops what was waiting to be sent', actor.getSnapshot().context.pending.length === 0)
    actor.stop()
  }

  {
    /*
      The channel's own check, which is the one that matters: this is the first
      bulk payload the control request has ever carried, and the confined half
      rebuilds it rather than trusting it.
    */
    const request = (images: unknown) =>
      parseControlRequest(
        JSON.stringify({
          kind: 'run-turn',
          turnId: 't1',
          prompt: 'p',
          model: 'claude-opus-5',
          effort: 'xhigh',
          images,
        }),
      )

    check('a well-formed picture crosses', request([shot()])?.kind === 'run-turn')
    check('no images at all is an empty list rather than a refusal', request(undefined) !== null)
    // SVG is a document with script in it rather than a picture, which is why
    // the media type is an allowlist and not an `image/` prefix test.
    check('svg is refused', request([{ mediaType: 'image/svg+xml', data: 'aGk=' }]) === null)
    // A newline in the payload would split the request across two lines of a
    // newline-framed channel — the one way a value here could become a request.
    check('a payload with a newline in it is refused', request([{ mediaType: 'image/png', data: 'aGk=\nzz' }]) === null)
    check('a payload that is not base64 is refused', request([{ mediaType: 'image/png', data: 'not base64!' }]) === null)
    // All or nothing: a developer who pasted two and had one dropped is asking
    // about a picture the agent cannot see.
    check(
      'one bad picture refuses the whole Turn',
      request([shot(), { mediaType: 'image/svg+xml', data: 'aGk=' }]) === null,
    )
    check(
      'and a paste too large to frame is refused rather than truncated',
      request([{ mediaType: 'image/png', data: 'a'.repeat(MAX_IMAGE_BYTES + 4) }]) === null,
    )
  }
}

// ---------------------------------------------------------------------------
// Markdown — what the agent wrote, read as what it meant
// ---------------------------------------------------------------------------

{
  /*
    The agent has always written Markdown and the transcript always showed the
    characters. `**Blocked:**` rendered as five asterisks and a word, and a
    fenced diff rendered as three backticks and a diff — the developer was
    reading the source of an answer rather than the answer.

    Asserted here rather than in a browser because the parser is pure by
    design: it produces a tree of tagged nodes and the renderer turns those
    into elements. That split is not tidiness — a Markdown pipeline that
    produced HTML would need sanitising, and every agent answer would then be
    one sanitiser bug away from running script *in the webview that holds the
    bridge to the host*. There is no HTML anywhere in this path to get wrong.
  */
  const kinds = (blocks: readonly { kind: string }[]) => blocks.map((b) => b.kind).join(' ')

  check(
    'a heading is a heading and its level survives',
    (() => {
      const [h] = parseMarkdown('### Three')
      return h?.kind === 'heading' && h.level === 3
    })(),
  )
  check(
    'a paragraph keeps the newlines inside it',
    (() => {
      const [p] = parseMarkdown('one\ntwo')
      // One block, not two: a single newline is a line the agent meant, and the
      // renderer keeps it. CommonMark would fold it into a space, which is right
      // for prose and wrong for an answer that lays out steps.
      return p?.kind === 'paragraph' && p.spans.some((s) => s.kind === 'text' && s.text.includes('\n'))
    })(),
  )
  check('a blank line separates paragraphs', kinds(parseMarkdown('one\n\ntwo')) === 'paragraph paragraph')

  /*
    The rule that matters most, and the one a regex-per-feature parser gets
    wrong: inside a fence, nothing is Markdown. Half of what an agent writes is
    a shell line or a diff, and both are full of the characters every other
    rule is looking for.
  */
  const fenced = parseMarkdown('before\n```sh\n# not a heading\n- not a list\n**not bold**\n```\nafter')
  check('a fence is one code block whatever is inside it', kinds(fenced) === 'paragraph code paragraph')
  check('and the fence keeps its language', fenced[1]?.kind === 'code' && fenced[1].language === 'sh')
  check(
    'and its contents are text, not markup',
    fenced[1]?.kind === 'code' && fenced[1].text === '# not a heading\n- not a list\n**not bold**',
  )
  /*
    A streamed answer is a partial document by definition. An unterminated
    fence runs to the end of what has arrived rather than failing, because half
    a code block is exactly what the developer should see while it is still
    coming.
  */
  const streaming = parseMarkdown('```ts\nconst x = 1')
  check('an unterminated fence is still a code block', kinds(streaming) === 'code')
  check('and holds what arrived', streaming[0]?.kind === 'code' && streaming[0].text === 'const x = 1')

  const list = parseMarkdown('- one\n- two\n- three')
  check('a bulleted list is one block with its items', list[0]?.kind === 'list' && list[0].items.length === 3)
  check('and knows it is not numbered', list[0]?.kind === 'list' && !list[0].ordered)
  const ordered = parseMarkdown('1. one\n2. two')
  check('a numbered list says so', ordered[0]?.kind === 'list' && ordered[0].ordered)
  // Two lists rather than one with a changing marker: it is what it looks like.
  check('a list that changes marker is two lists', kinds(parseMarkdown('- one\n1. two')) === 'list list')

  check('a quote is its own block', kinds(parseMarkdown('> quoted')) === 'quote')
  check('a rule is its own block', kinds(parseMarkdown('---')) === 'rule')

  // Inline
  const spanKinds = (text: string) => parseInline(text).map((s) => s.kind).join(' ')
  check('bold is bold', spanKinds('a **b** c') === 'text strong text')
  check('code is code', spanKinds('run `bun test` now') === 'text code text')
  /*
    Code wins, and its contents are never scanned again. Half of what an agent
    writes is a path or a flag with punctuation in it, so `**` inside backticks
    staying two asterisks is the difference a developer notices immediately.
  */
  check(
    'markup inside backticks is not markup',
    (() => {
      const [span] = parseInline('`**not bold**`')
      return span?.kind === 'code' && span.text === '**not bold**'
    })(),
  )
  check('a bare url is a link', spanKinds('see https://example.com now') === 'text link text')
  check(
    'a labelled link keeps both halves',
    (() => {
      const [span] = parseInline('[docs](https://example.com)')
      return span?.kind === 'link' && span.text === 'docs' && span.href === 'https://example.com'
    })(),
  )
  check('empty text still yields a span, so no renderer branches on nothing', parseInline('').length === 1)

  /*
    The security half, and the reason it is a function rather than a rule in
    the renderer: `javascript:` and `data:` execute, and this is the webview
    holding the bridge to the host process that holds the credential. A link
    that is not plainly http, https or mailto is rendered as text — the URL is
    still shown, so nothing is hidden from the developer; it simply is not
    clickable.
  */
  check('an ordinary link is clickable', isSafeHref('https://example.com') && isSafeHref('http://x.dev'))
  check('mailto is clickable', isSafeHref('mailto:a@b.com'))
  check('javascript: is not', !isSafeHref('javascript:alert(1)'))
  check('and neither is it with padding or case', !isSafeHref('  JaVaScRiPt:alert(1)'))
  check('data: is not', !isSafeHref('data:text/html,<script>'))
  check('nor a bare path, which has no scheme to trust', !isSafeHref('/etc/passwd'))
}

// ---------------------------------------------------------------------------
// The states page's index — that a link goes where it says
// ---------------------------------------------------------------------------

{
  /*
    Anchors are the classic thing that rots in silence. Rename a scenario and
    the index entry still renders, still looks right, and goes nowhere: the page
    mounts, nothing throws, coverage is unchanged, and the only way to find out
    is to click all twenty-four.

    Every claim here is about the pure half — the route parser and the ids — so
    it runs at the same seam everything else in this script does, with no
    browser. What a browser would add is that the element scrolled into view,
    and the element's id is the scenario's id by construction.
  */
  check('the states route is itself', routeOf('#/states') === '#/states')
  check('and a card on it is still the states page', routeOf('#/states/turn-failed') === '#/states')
  check('a card is read back off the route', cardOf('#/states/turn-failed') === 'turn-failed')
  check('the page itself names no card', cardOf('#/states') === null)
  // A card segment on a page with no cards would invent an addressable thing.
  check('only the states page has cards', cardOf('#/designed/turn-failed') === null)
  check('an unknown hash is the chat', routeOf('#/nothing') === '#/designed' && routeOf('') === '#/designed')
  /*
    The near-miss that made the parser sort by length: a route that prefixes
    another would answer for it. Nothing does today, and this is what keeps
    adding one from being the way it starts.
  */
  check('a route is not answered by something that merely prefixes it', routeOf('#/statesish') === '#/designed')

  for (const scenario of SCENARIOS) {
    check(
      `scenario "${scenario.id}" is addressable`,
      linkToCard(scenario.id) === `#/states/${scenario.id}` &&
        cardOf(linkToCard(scenario.id)) === scenario.id,
    )
  }

  // Two cards with one id is two links to one of them, and the coverage banner
  // would not notice: both would still be on the page.
  const ids = SCENARIOS.map((s) => s.id)
  check('no two cards share an id', new Set(ids).size === ids.length)
  // The id is a path segment and an element id. A space or a slash in one
  // breaks the link rather than the build.
  check('every id survives being a URL segment', ids.every((id) => /^[a-z0-9-]+$/.test(id)))

  // The index renders one heading per group and nothing outside the list, so a
  // scenario whose group is not one of them would be a card with no way in —
  // the exact defect ticket 41 closed for whole pages.
  check(
    'every card sits in a group the index renders',
    SCENARIOS.every((s) => (GROUPS as readonly string[]).includes(s.group)),
  )
  check('every group has at least one card', GROUPS.every((g) => SCENARIOS.some((s) => s.group === g)))

  /*
    The count in the nav and the number of cards beside it come from one
    predicate. Asserted with a filter that actually excludes something, because
    a predicate agreeing with itself over the whole list is true of any two
    functions that both return everything.
  */
  const byQuery = SCENARIOS.filter(matches('turn.failed', 'all'))
  check('a state path is searchable, because that is what the page is for', byQuery.length > 0)
  check('and the filter excludes rather than merely sorting', byQuery.length < SCENARIOS.length)
  const byGroup = SCENARIOS.filter(matches('', 'Surfaces'))
  check('a group narrows to itself', byGroup.length > 0 && byGroup.every((s) => s.group === 'Surfaces'))
  check(
    'a filter that answers nothing answers nothing, rather than everything',
    SCENARIOS.filter(matches('nothing-is-called-this', 'all')).length === 0,
  )
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
    { type: 'COMPACTED', summary: 's', tokensUsed: 1 },
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

  check(
    'idle accepts what idle has always accepted',
    at.get('idle') === 'EDIT_DRAFT SEND SAVE CLEAR SET_MODEL SET_EFFORT SET_COMMANDS COMPACTED',
  )
  /*
    `CLEAR` joins every one of these, and the literals move for a reason rather
    than to make a failure go away — which is what the header above warns about.

    It was a command accepted only where a Turn had settled. It is a report now:
    the runtime announcing that the conversation was reset, arriving while the
    Turn that asked for it is still running. A state can decide what to do with
    a fact and cannot decline one, so it is handled at the root.
  */
  check(
    'sending accepts a delta, an interrupt, and the report that the agent forgot',
    at.get('sending') ===
      'EDIT_DRAFT STREAM_DELTA INTERRUPT SAVE CLEAR SET_MODEL SET_EFFORT SET_COMMANDS COMPACTED',
  )
  check(
    'streaming accepts exactly the same, which is why a delta needed no new state',
    at.get('streaming') === at.get('sending'),
  )
  check(
    'interrupting accepts nothing new, not even another interrupt',
    at.get('interrupting') === 'EDIT_DRAFT SAVE CLEAR SET_MODEL SET_EFFORT SET_COMMANDS COMPACTED',
  )
  check(
    'turn-failed offers retry and dismiss, and nothing else new',
    at.get('failed') ===
      'EDIT_DRAFT RETRY_TURN DISMISS_TURN_ERROR SAVE CLEAR SET_MODEL SET_EFFORT SET_COMMANDS COMPACTED',
  )
  /*
    `COMPACTED` joins `CLEAR` in every one of these, and the literals move for a
    reason rather than to make a failure go away.

    A `turn.compacting` row stood here, asserting that a Compaction refused
    everything a running Turn refuses and could not be interrupted. There is no
    such state: varnick does not perform a compaction, so there is nothing to
    watch and nothing to interrupt. What replaced it is the line above — the
    report is accepted everywhere, which is the property the state was never
    able to have.
  */
  check(
    'the report that the agent summarised is accepted in every turn state',
    [...at.values()].every((set) => set.includes('COMPACTED')),
  )
  check('the composer and the model are legal in every turn state', [...at.values()].every((set) => set.startsWith('EDIT_DRAFT') && set.includes('SET_MODEL')))
  /*
    This asserted a count and could not fail: `at` is filled by six
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
    The live half of a compaction, against a host that answers — the only place
    Core's side of it can be driven without a Claude Code process anywhere.

    `tauriHarnessBridge()` reads `__TAURI_INTERNALS__`, which is the same seam
    the real app arrives through, so this exercises the actor exactly as it
    runs. Nothing here starts a session, and nothing here *asks* for a
    compaction: the actor is `runTurn`, and the compaction is something that
    happens to the Turn while it is running.
  */
  const realInternals = (globalThis as Record<string, unknown>).__TAURI_INTERNALS__
  const queue: unknown[] = []
  const asked: string[] = []
  ;(globalThis as Record<string, unknown>).__TAURI_INTERNALS__ = {
    invoke: async (_command: string, payload: { request: { kind: string } }) => {
      const kind = payload.request.kind
      asked.push(kind)
      if (kind === 'run-turn') return { ok: true }
      if (kind === 'next-turn-event') return { event: queue.shift() ?? null }
      throw { failure: 'malformed' }
    },
  }

  const heard: { summary: string; tokensUsed: number | null }[] = []
  const observer = {
    delta: () => {},
    credentialRejected: () => {},
    runtimeReported: () => {},
    commandsReported: () => {},
    conversationReset: () => {},
    conversationCompacted: (summary: string, tokensUsed: number | null) => {
      heard.push({ summary, tokensUsed })
    },
  }

  const turn = liveActors(observer).runTurn
  const run = (input: TurnInput) =>
    new Promise<{ output?: TurnOutput; error?: unknown }>((resolve) => {
      const actor = createActor(turn, { input })
      actor.subscribe({
        next: (snapshot) => {
          if (snapshot.status === 'done') resolve({ output: snapshot.output as TurnOutput })
        },
        error: (error) => resolve({ error }),
      })
      actor.start()
    })

  queue.push(
    { kind: 'compacted', turnId: 'turn-1', summary: 'so far: the sandbox', tokensUsed: 4_000 },
    { kind: 'done', turnId: 'turn-1', text: 'and then this', tokensUsed: 4_200 },
  )
  const done = await run({ sessionId: 'live-1', prompt: 'carry on', model: 'claude-opus-5', effort: 'xhigh', images: [] })
  check('the live turn asks the confined session and nothing else', asked.every((kind) => kind === 'run-turn' || kind === 'next-turn-event'))
  check('a compaction mid-turn is reported to the window', heard.length === 1)
  check('with the summary the Session produced', heard[0]?.summary === 'so far: the sandbox')
  check('and with what the context now measures, not an estimate', heard[0]?.tokensUsed === 4_000)
  check('and it does not end the turn it arrived during', done.output?.text === 'and then this')

  queue.push(
    { kind: 'compacted', turnId: 'turn-2', summary: 'a summary', tokensUsed: null },
    { kind: 'done', turnId: 'turn-2', text: 'carried on', tokensUsed: 1 },
  )
  await run({ sessionId: 'live-1', prompt: 'again', model: 'claude-opus-5', effort: 'xhigh', images: [] })
  check(
    'a compaction the Session would not measure still reaches the window',
    heard.length === 2 && heard[1]?.tokensUsed === null,
  )

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
    ...WORKTREE_DIFF_STATE_PATHS.map((p) => `worktreeDiff.${p}`),
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
// The dev server — a Core change reloads, a Userspace change hot-swaps
// ---------------------------------------------------------------------------

{
  /*
    ADR-0005 required an explicit restart after a Core merge, because
    hot-swapping the module that owns the Session remounts the machine holding
    the conversation that asked for the change. That was a rule someone had to
    remember. ADR-0014 makes it mechanical.

    The decision is a pure function over a path precisely so it can be asserted
    here — no dev server, no browser, no window. What Vite does with the verdict
    is one line in `vite.config.ts`; what the verdict *is* is the part that can
    be got wrong quietly, because both mistakes look like nothing happening.

    A full reload is safe and a hot swap is not: the Session is durable
    host-side and resumes from the mirror (ADR-0009), so a reload costs a moment
    and loses nothing.
  */
  const clone = '/Users/someone/varnick'

  check(
    'a Core source file reloads the window',
    hotUpdateVerdict(`${clone}/packages/core/src/machines/session.ts`, clone) === 'reload',
  )
  check(
    'so does a Core file that is not source — the rule is the path, not the extension',
    hotUpdateVerdict(`${clone}/packages/core/index.html`, clone) === 'reload',
  )

  // The product's main loop: ask for a Surface and it appears, without the
  // window blinking. If this one ever says `reload`, the change meant to
  // protect the conversation has broken the thing it was protecting.
  check(
    'a Userspace Surface still hot-swaps',
    hotUpdateVerdict(`${clone}/packages/userspace/surfaces/runs/index.tsx`, clone) === 'hot-swap',
  )
  check(
    'and so does a Userspace file whose own path contains packages/core',
    hotUpdateVerdict(`${clone}/packages/userspace/packages/core/thing.ts`, clone) === 'hot-swap',
  )

  // Prefix matching on the string would take this one, and it is a different
  // package.
  check(
    'a sibling package whose name starts with core is not Core',
    hotUpdateVerdict(`${clone}/packages/core-tools/src/main.ts`, clone) === 'hot-swap',
  )

  // ADR-0014: Core is authored in a Worktree, and a Preview runs from one. Its
  // Core is Core — the rule is relative to the root that is running, which is
  // the only reason it can be stated as one rule at all.
  const worktree = `${clone}/.claude/worktrees/agent-1`
  check(
    "a Worktree's Core reloads the Preview running from it",
    hotUpdateVerdict(`${worktree}/packages/core/src/app.tsx`, worktree) === 'reload',
  )
  check(
    "and the live tree's rule does not reach into a Worktree",
    hotUpdateVerdict(`${worktree}/packages/core/src/app.tsx`, clone) === 'hot-swap',
  )

  check(
    'a path outside the clone altogether decides nothing',
    hotUpdateVerdict('/tmp/somewhere/packages/core/x.ts', clone) === 'hot-swap',
  )
  check(
    'and neither does a sibling clone with a longer name',
    hotUpdateVerdict(`${clone}-two/packages/core/x.ts`, clone) === 'hot-swap',
  )
}

// ---------------------------------------------------------------------------
// The dev server — one port, and a devUrl that cannot disagree with it
// ---------------------------------------------------------------------------

{
  /*
    A second varnick collides with the first on two numbers that are written
    down twice: `server.port` in the Vite config and `devUrl` in
    `tauri.conf.json`. Making the port an input is the easy half. The half worth
    testing is that the two cannot drift apart, because the failure is not a
    refusal — a `devUrl` pointing at a port another varnick holds opens a window
    onto that varnick's frontend with this one's host behind it, which is a
    worse outcome than a window that does not open.

    So there is one string. The launcher builds it and hands the same value to
    both ends; the frontend reads its port back out of it rather than choosing
    one. The only literal left is `tauri.conf.json`'s default, and that is
    checked against the default here.
  */
  check('nothing chosen is the port varnick has always bound', chosenDevPort(undefined) === 1420)
  check('and DEFAULT_DEV_PORT says so', DEFAULT_DEV_PORT === 1420)
  check('a frontend told nothing binds the same', portToBind(undefined) === DEFAULT_DEV_PORT)

  const conf = JSON.parse(
    readFileSync(new URL('../../../src-tauri/tauri.conf.json', import.meta.url).pathname, 'utf-8'),
  ) as { build: { devUrl: string } }
  check(
    "tauri.conf.json's devUrl is the default port's URL, so a fresh checkout agrees with itself",
    conf.build.devUrl === devUrlFor(DEFAULT_DEV_PORT),
  )

  const chosen = chosenDevPort('1421')
  check('a chosen port becomes exactly one URL', devUrlFor(chosen) === 'http://localhost:1421')
  check('and the frontend binds the port that URL names', portToBind(devUrlFor(chosen)) === 1421)

  const refuses = (label: string, run: () => unknown) => {
    let threw = false
    try {
      run()
    } catch {
      threw = true
    }
    check(label, threw)
  }

  // Refusals, because a port that quietly becomes 1420 is a collision with the
  // varnick that is already running.
  refuses('a port that is not a number is refused', () => chosenDevPort('nineteen'))
  refuses('and so is one with a fraction', () => chosenDevPort('1420.5'))
  refuses('and zero', () => chosenDevPort('0'))
  refuses('and one past the end of the range', () => chosenDevPort('65536'))
  refuses('a devUrl that is not a URL is refused', () => portToBind('localhost:1421'))
  refuses('and one that names no port, because there is nothing to bind', () =>
    portToBind('http://localhost'),
  )

  /*
    The config itself, not a restatement of it. Importing it is what makes this
    an assertion about what `bun tauri dev` does rather than about a function
    that happens to exist beside it.
  */
  const config = (await import('../vite.config.ts')).default as {
    server: { port: number; strictPort: boolean }
    plugins: unknown[]
  }

  check('the dev server binds the default port with nothing set', config.server.port === 1420)
  check(
    'strictPort stays on, which is what makes the bound port the configured one',
    config.server.strictPort === true,
  )

  type Hooked = { name: string; handleHotUpdate?: (ctx: unknown) => unknown }
  const plugins = config.plugins.flat().filter((p): p is Hooked => {
    return typeof p === 'object' && p !== null && 'name' in p
  })
  const reloader = plugins.find((p) => typeof p.handleHotUpdate === 'function')
  check('the config carries a plugin that handles hot updates', reloader !== undefined)

  const sent: string[] = []
  const fire = (file: string) => {
    sent.length = 0
    const modules = [{ id: file }]
    const returned = reloader?.handleHotUpdate?.({
      file,
      timestamp: 0,
      modules,
      read: () => '',
      server: { hot: { send: (payload: { type: string }) => sent.push(payload.type) } },
    })
    return { returned, modules }
  }

  const cloneRoot = new URL('../../../', import.meta.url).pathname.replace(/\/$/, '')

  const core = fire(`${cloneRoot}/packages/core/src/machines/session.ts`)
  check('a Core change tells the window to reload', sent.join() === 'full-reload')
  check(
    'and hands back no modules, so nothing is swapped underneath it',
    Array.isArray(core.returned) && core.returned.length === 0,
  )

  const userspace = fire(`${cloneRoot}/packages/userspace/surfaces/runs/index.tsx`)
  check('a Userspace change sends nothing', sent.length === 0)
  check(
    'and leaves the module list alone, which is how a Surface hot-swaps',
    userspace.returned === undefined,
  )

  /*
    The launch is where the two ends are handed the same value. Asserting the
    spawn's shape is the closest a headless check gets to "two varnicks run at
    once": what a second window loads and what the second frontend binds are one
    string produced once.
  */
  const second = devLaunch(1421)
  const overlay = second.args.at(-1) ?? ''
  const merged = JSON.parse(overlay) as { build: { devUrl: string } }

  check('the launch overrides devUrl and nothing else', Object.keys(merged).join() === 'build')
  check(
    'what the window loads and what the frontend is told are the same string',
    merged.build.devUrl === second.env[DEV_URL_ENV_VAR],
  )
  check(
    'and that string names the port that was asked for',
    portToBind(second.env[DEV_URL_ENV_VAR]) === 1421,
  )
  check(
    'the overlay reaches the Tauri CLI as a config merge',
    second.args.at(-2) === '--config' && second.args.slice(0, 2).join(' ') === 'tauri dev',
  )

  const first = devLaunch(DEFAULT_DEV_PORT)
  check(
    'the default launch asks for the port a fresh checkout already has',
    first.env[DEV_URL_ENV_VAR] === conf.build.devUrl,
  )
}

// ---------------------------------------------------------------------------

console.log(`\n${passed} assertions passed`)
if (failures.length > 0) {
  console.error(`${failures.length} FAILED:`)
  for (const f of failures) console.error(`  ✗ ${f}`)
  process.exit(1)
}
console.log('all green — UI may begin\n')
