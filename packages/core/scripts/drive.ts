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
import { createActor, fromPromise, waitFor } from 'xstate'
import { harnessMachine } from '../src/machines/harness.ts'
import { sessionMachine } from '../src/machines/session.ts'
import { surfaceMachine } from '../src/machines/surface.ts'
import { regionOf, canStartAgent } from '../src/domain.ts'
import { seedPolicy, seedSurfaces, brokenSurfaceError } from '../src/data/seed.ts'
import type { SandboxPolicy } from '../src/domain.ts'

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
    sessionMachine.provide({ actors: { runTurn: never() } }),
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
    sessionMachine.provide({ actors: { runTurn: never() }, delays: { interruptGrace: 1 } }),
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
        runTurn: fromPromise(async () => {
          turnAttempts++
          if (turnAttempts === 1) throw new Error('stream closed')
          return { text: 'second time' }
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
        runTurn: never(),
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

  actor.send({ type: 'UNLOAD_SURFACE', id: 'broken' })
  check('unloading removes it from the parent', actor.getSnapshot().context.surfaces.length === 2)
  actor.stop()
}

// ---------------------------------------------------------------------------

console.log(`\n${passed} assertions passed`)
if (failures.length > 0) {
  console.error(`${failures.length} FAILED:`)
  for (const f of failures) console.error(`  ✗ ${f}`)
  process.exit(1)
}
console.log('all green — UI may begin\n')
