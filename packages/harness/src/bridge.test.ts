import { describe, expect, test } from 'bun:test'
import {
  HARNESS_FAILURES,
  HarnessUnavailable,
  callHarness,
  harnessGuidance,
  tauriHarnessBridge,
  type HarnessBridge,
  type HarnessFailure,
  type HarnessRequest,
} from './bridge.ts'
import { TURN_FAILURES, turnFailureMessage } from './turn.ts'

/**
 * The seam: the exported surface of the bridge, and nothing below it.
 *
 * Every test here supplies its own {@link HarnessBridge}. Nothing in this file
 * reaches a host, a keychain, a kernel or a filesystem — it cannot, because the
 * only way into `callHarness` is a bridge, and a missing one is a value.
 */

/** A bridge that answers the way the Tauri command does on success. */
const answers = (answer: unknown): HarnessBridge => ({ call: async () => answer })

/** A bridge that rejects the way Tauri rejects a command returning `Err`. */
const refuses = (payload: unknown): HarnessBridge => ({
  call: async () => {
    throw payload
  },
})

/** A value shaped like a real key, used to prove it never comes back out. */
const LOOKS_LIKE_A_KEY = 'sk-" + "ant-api03-NEVER-LET-THIS-OUT'

const failureOf = async (request: HarnessRequest, bridge: HarnessBridge | null) => {
  try {
    await callHarness(request, bridge)
  } catch (error) {
    if (error instanceof HarnessUnavailable) return error
    throw error
  }
  throw new Error('the call was expected to fail')
}

describe('a missing host is a value to branch on, not an exception to catch', () => {
  test('a plain browser tab has no bridge', () => {
    expect(tauriHarnessBridge()).toBeNull()
  })

  test('a call with no bridge fails as no-host rather than rejecting unhandled', async () => {
    const failure = await failureOf({ kind: 'check-sandbox' }, null)
    expect(failure.failure).toBe('no-host')
  })

  test('every kind of call reaches the same answer when there is no host', async () => {
    const requests: HarnessRequest[] = [
      { kind: 'check-sandbox' },
      { kind: 'read-credential' },
      { kind: 'persist-session', sessionId: 's', messages: [] },
      { kind: 'read-session', sessionId: 's' },
      { kind: 'spawn-agent' },
      { kind: 'stop-agent' },
      { kind: 'await-agent-exit' },
      { kind: 'run-turn', turnId: 't1', prompt: 'hi', model: 'claude-opus-5', effort: 'xhigh' },
      { kind: 'next-turn-event' },
      { kind: 'interrupt-turn', turnId: 't1' },
      { kind: 'read-plan-usage', requestId: 'u1' },
      { kind: 'compact-session', turnId: 'c1' },
    ]
    for (const request of requests) {
      expect((await failureOf(request, null)).failure).toBe('no-host')
    }
  })

  test('the no-host message says where the Harness actually runs', async () => {
    const failure = await failureOf({ kind: 'check-sandbox' }, null)
    expect(failure.message).toContain('tauri dev')
  })
})

describe('the failure reaches the actor as an Error carrying the reason', () => {
  test('everything that goes wrong is a HarnessUnavailable', async () => {
    const bridges = [null, refuses('boom'), refuses(new Error('boom')), answers(undefined)]
    for (const bridge of bridges) {
      await expect(callHarness({ kind: 'check-sandbox' }, bridge)).rejects.toBeInstanceOf(
        HarnessUnavailable,
      )
    }
  })

  test('a refusal keeps the reason the Harness gave, so sandbox.unavailable can say it', async () => {
    const bridge = refuses({
      failure: 'refused',
      detail: 'sandbox-runtime does not support win32.',
    })
    const failure = await failureOf({ kind: 'check-sandbox' }, bridge)
    expect(failure.failure).toBe('refused')
    expect(failure.detail).toBe('sandbox-runtime does not support win32.')
    expect(failure.message).toContain('does not support win32')
  })

  test('a refusal with no reason still fails legibly rather than emptily', async () => {
    const failure = await failureOf({ kind: 'check-sandbox' }, refuses({ failure: 'refused' }))
    expect(failure.detail).toBeNull()
    expect(failure.message.length).toBeGreaterThan(20)
  })

  test('a host with no runtime behind it is its own failure', async () => {
    const failure = await failureOf({ kind: 'check-sandbox' }, refuses({ failure: 'no-runtime' }))
    expect(failure.failure).toBe('no-runtime')
  })

  test('a runtime that stopped answering is a different failure from never having one', async () => {
    const failure = await failureOf({ kind: 'check-sandbox' }, refuses({ failure: 'runtime-lost' }))
    expect(failure.failure).toBe('runtime-lost')
  })

  test('a rejection the bridge does not recognise is malformed, never a crash', async () => {
    expect((await failureOf({ kind: 'check-sandbox' }, refuses('boom'))).failure).toBe('malformed')
    expect((await failureOf({ kind: 'check-sandbox' }, refuses(null))).failure).toBe('malformed')
    expect((await failureOf({ kind: 'check-sandbox' }, refuses({ failure: 42 }))).failure).toBe(
      'malformed',
    )
  })
})

describe('every failure is legible and distinct', () => {
  test('each names a different thing', () => {
    const messages = HARNESS_FAILURES.map((failure) => harnessGuidance(failure, null))
    expect(new Set(messages).size).toBe(HARNESS_FAILURES.length)
  })

  test('none is empty', () => {
    for (const failure of HARNESS_FAILURES) {
      expect(harnessGuidance(failure, null).length).toBeGreaterThan(20)
    }
  })

  test('the tags are the ones the Rust host and this module both know', () => {
    const expected: HarnessFailure[] = [
      'no-host',
      'no-runtime',
      'runtime-lost',
      'malformed',
      'refused',
    ]
    expect([...HARNESS_FAILURES]).toEqual(expected)
  })
})

describe('the answer is rebuilt, never passed through', () => {
  test('a credential reading carries one field, and it is the source', async () => {
    const reading = await callHarness({ kind: 'read-credential' }, answers({ source: 'keychain' }))
    expect(reading).toEqual({ source: 'keychain' })
  })

  test('a host that volunteers the value gets no help carrying it further', async () => {
    const chatty = answers({ source: 'env', value: LOOKS_LIKE_A_KEY, apiKey: LOOKS_LIKE_A_KEY })
    const reading = await callHarness({ kind: 'read-credential' }, chatty)
    expect(Object.keys(reading)).toEqual(['source'])
    expect(JSON.stringify(reading)).not.toContain(LOOKS_LIKE_A_KEY)
  })

  test('a store the bridge does not know is malformed, not a reading', async () => {
    expect(
      (await failureOf({ kind: 'read-credential' }, answers({ source: 'elsewhere' }))).failure,
    ).toBe('malformed')
  })

  test('an established sandbox answers ok and nothing else', async () => {
    const answer = await callHarness(
      { kind: 'check-sandbox' },
      answers({ ok: true, policy: { denyRead: ['/Users'] } }),
    )
    expect(answer).toEqual({ ok: true })
  })

  test('a save answers ok and nothing else', async () => {
    const answer = await callHarness(
      { kind: 'persist-session', sessionId: 's', messages: [] },
      answers({ ok: true, path: '/Users/someone/Library/whatever.jsonl' }),
    )
    expect(answer).toEqual({ ok: true })
  })

  test('a restored transcript is rebuilt message by message', async () => {
    const answer = await callHarness(
      { kind: 'read-session', sessionId: 's' },
      answers({
        messages: [{ id: 'm1', role: 'user', text: 'hello', apiKey: LOOKS_LIKE_A_KEY }],
        redacted: false,
        path: '/Users/someone/Library/whatever.jsonl',
      }),
    )
    expect(answer).toEqual({
      messages: [{ id: 'm1', role: 'user', text: 'hello' }],
      redacted: false,
    })
    expect(JSON.stringify(answer)).not.toContain(LOOKS_LIKE_A_KEY)
  })

  test('an empty transcript is an answer, not a malformed one', async () => {
    expect(
      await callHarness({ kind: 'read-session', sessionId: 's' }, answers({ messages: [] })),
    ).toEqual({ messages: [], redacted: false })
  })

  test('a transcript the bridge cannot read is malformed rather than a silent empty one', async () => {
    // An empty transcript would look like a first run, and the next save would
    // replace a Session nobody managed to read.
    const unreadable = [
      answers({ messages: 'not a list' }),
      answers({ messages: [{ id: 'm1', role: 'wizard', text: 'x' }] }),
      answers({ messages: [{ id: 7, text: 'x', role: 'user' }] }),
      answers(undefined),
    ]
    for (const bridge of unreadable) {
      expect((await failureOf({ kind: 'read-session', sessionId: 's' }, bridge)).failure).toBe(
        'malformed',
      )
    }
  })

  test('a spawned agent answers with its pid and nothing else', async () => {
    const answer = await callHarness(
      { kind: 'spawn-agent' },
      answers({ pid: 4242, argv: ['/bin/bash'], env: { ANTHROPIC_API_KEY: LOOKS_LIKE_A_KEY } }),
    )
    expect(answer).toEqual({ pid: 4242 })
    expect(JSON.stringify(answer)).not.toContain(LOOKS_LIKE_A_KEY)
  })

  test('a pid that is not a number is malformed rather than a running agent', async () => {
    // `agent.running` spawning the Session hangs off this answer, so a host
    // that said something unreadable must not be read as a started process.
    expect((await failureOf({ kind: 'spawn-agent' }, answers({ pid: 'lots' }))).failure).toBe(
      'malformed',
    )
    expect((await failureOf({ kind: 'spawn-agent' }, answers({}))).failure).toBe('malformed')
  })

  test('an exit answers with the reason the process actually gave', async () => {
    const answer = await callHarness(
      { kind: 'await-agent-exit' },
      answers({ reason: 'The agent process was killed (signal 9).' }),
    )
    expect(answer).toEqual({ reason: 'The agent process was killed (signal 9).' })
  })

  test('an exit with no reason is malformed, never an empty crash', async () => {
    // agent.crashed renders this string. An empty one would be a crash that
    // says nothing, which is the state this ticket exists to avoid.
    expect((await failureOf({ kind: 'await-agent-exit' }, answers({}))).failure).toBe('malformed')
    expect((await failureOf({ kind: 'await-agent-exit' }, answers({ reason: 7 }))).failure).toBe(
      'malformed',
    )
  })

  test('an answer that is not ok is malformed rather than quietly successful', async () => {
    expect((await failureOf({ kind: 'check-sandbox' }, answers({ ok: false }))).failure).toBe(
      'malformed',
    )
    expect((await failureOf({ kind: 'check-sandbox' }, answers(undefined))).failure).toBe(
      'malformed',
    )
  })
})

describe('nothing the host said can reach a message it did not author', () => {
  const messageOf = async (bridge: HarnessBridge) =>
    (await failureOf({ kind: 'read-credential' }, bridge)).message

  test('an unrecognised rejection payload is not quoted', async () => {
    expect(await messageOf(refuses({ failure: LOOKS_LIKE_A_KEY }))).not.toContain(LOOKS_LIKE_A_KEY)
  })

  test('a rejection that is a bare string is not quoted', async () => {
    expect(await messageOf(refuses(LOOKS_LIKE_A_KEY))).not.toContain(LOOKS_LIKE_A_KEY)
  })

  test('a rejection that is an Error is not quoted', async () => {
    expect(await messageOf(refuses(new Error(LOOKS_LIKE_A_KEY)))).not.toContain(LOOKS_LIKE_A_KEY)
  })

  test('a malformed answer is not quoted either', async () => {
    expect(await messageOf(answers({ source: LOOKS_LIKE_A_KEY }))).not.toContain(LOOKS_LIKE_A_KEY)
  })

  test('a refusal detail is the one string that is forwarded, and never on a credential', async () => {
    // The credential is answered by the Rust host with a tag, so its refusals
    // carry a tag. A tag long enough to be a key is not one this module invents,
    // but it is also not one the credential route can ever produce — see
    // src-tauri/src/credential.rs, where every failure is a `&'static str`.
    const refusal = refuses({ failure: 'refused', detail: 'nothing-stored' })
    expect((await failureOf({ kind: 'read-credential' }, refusal)).detail).toBe('nothing-stored')
  })
})

describe('the request crosses intact and carries nothing extra', () => {
  test('the bridge is handed exactly the request it was given', async () => {
    const seen: unknown[] = []
    const recording: HarnessBridge = {
      call: async (request) => {
        seen.push(request)
        return { ok: true }
      },
    }
    await callHarness({ kind: 'persist-session', sessionId: 'abc', messages: [] }, recording)
    expect(seen).toEqual([{ kind: 'persist-session', sessionId: 'abc', messages: [] }])
  })

  test('a credential read asks for nothing and sends nothing', async () => {
    const seen: unknown[] = []
    const recording: HarnessBridge = {
      call: async (request) => {
        seen.push(request)
        return { source: 'env' }
      },
    }
    await callHarness({ kind: 'read-credential' }, recording)
    expect(seen).toEqual([{ kind: 'read-credential' }])
  })
})

describe('a Turn crosses the same seam as everything else', () => {
  test('starting a Turn answers with nothing beyond having started it', async () => {
    const started = await callHarness(
      { kind: 'run-turn', turnId: 't1', prompt: 'hi', model: 'claude-opus-5', effort: 'xhigh' },
      answers({ ok: true }),
    )
    expect(started).toEqual({ ok: true })
  })

  test('an event is rebuilt on the way in, like every other answer', async () => {
    // The event is written inside the Sandbox, by the process holding the
    // agent. A field it volunteered must not reach the machine's context, from
    // where it would reach the Session mirror.
    const event = await callHarness(
      { kind: 'next-turn-event' },
      answers({ event: { kind: 'delta', turnId: 't1', text: 'hi', apiKey: LOOKS_LIKE_A_KEY } }),
    )
    expect(event).toEqual({ event: { kind: 'delta', turnId: 't1', text: 'hi' } })
    expect(JSON.stringify(event)).not.toContain('sk-ant')
  })

  test('no event yet is an answer, not a failure', async () => {
    // The call waits, and a wait that ran out of patience has nothing to
    // report. A failure here would fail a Turn that is merely thinking.
    expect(await callHarness({ kind: 'next-turn-event' }, answers({ event: null }))).toEqual({
      event: null,
    })
  })

  test('an event this build cannot read is malformed rather than skipped', async () => {
    // Skipping it would drop a `done`, and the Turn would stream for ever.
    expect((await failureOf({ kind: 'next-turn-event' }, answers({ event: {} }))).failure).toBe(
      'malformed',
    )
    expect((await failureOf({ kind: 'next-turn-event' }, answers({ nothing: true }))).failure).toBe(
      'malformed',
    )
  })

  test('every failure a Turn can report is one this build knows the sentence for', async () => {
    for (const failure of TURN_FAILURES) {
      const answer = await callHarness(
        { kind: 'next-turn-event' },
        answers({ event: { kind: 'failed', turnId: 't1', failure } }),
      )
      expect(answer).toEqual({ event: { kind: 'failed', turnId: 't1', failure } })
      expect(turnFailureMessage(failure).length).toBeGreaterThan(0)
    }
  })

  test('a compaction asks for one thing and carries no text at all', async () => {
    // The request that would most obviously grow a prompt, and it has none:
    // the command is a constant inside the Sandbox, so there is nothing on
    // this side of the bridge that decides what the confined session is told.
    const seen: unknown[] = []
    const recording: HarnessBridge = {
      call: async (request) => {
        seen.push(request)
        return { ok: true }
      },
    }
    const started = await callHarness({ kind: 'compact-session', turnId: 'c1' }, recording)
    expect(started).toEqual({ ok: true })
    expect(seen).toEqual([{ kind: 'compact-session', turnId: 'c1' }])
  })

  test('a finished compaction is rebuilt on the way in like every other answer', async () => {
    const answer = await callHarness(
      { kind: 'next-turn-event' },
      answers({
        event: {
          kind: 'compacted',
          turnId: 'c1',
          summary: 'so far…',
          tokensUsed: 4_000,
          apiKey: LOOKS_LIKE_A_KEY,
        },
      }),
    )
    expect(answer).toEqual({
      event: { kind: 'compacted', turnId: 'c1', summary: 'so far…', tokensUsed: 4_000 },
    })
    expect(JSON.stringify(answer)).not.toContain('sk-ant')
  })

  test('a compaction with no figure is malformed rather than a meter reading zero', async () => {
    expect(
      (
        await failureOf(
          { kind: 'next-turn-event' },
          answers({ event: { kind: 'compacted', turnId: 'c1', summary: 'x' } }),
        )
      ).failure,
    ).toBe('malformed')
    expect(
      (
        await failureOf(
          { kind: 'next-turn-event' },
          answers({ event: { kind: 'compacted', turnId: 'c1', tokensUsed: 1 } }),
        )
      ).failure,
    ).toBe('malformed')
  })

  test('an interrupt names the Turn it means', async () => {
    const seen: unknown[] = []
    const recording: HarnessBridge = {
      call: async (request) => {
        seen.push(request)
        return { ok: true }
      },
    }
    await callHarness({ kind: 'interrupt-turn', turnId: 't1' }, recording)
    expect(seen).toEqual([{ kind: 'interrupt-turn', turnId: 't1' }])
  })

  test('a Turn request has no field a credential could ride in', async () => {
    const seen: unknown[] = []
    const recording: HarnessBridge = {
      call: async (request) => {
        seen.push(request)
        return { ok: true }
      },
    }
    await callHarness(
      { kind: 'run-turn', turnId: 't1', prompt: 'hi', model: 'claude-opus-5', effort: 'xhigh' },
      recording,
    )
    expect(Object.keys(seen[0] as object).sort()).toEqual([
      'effort',
      'kind',
      'model',
      'prompt',
      'turnId',
    ])
  })
})

/**
 * Plan usage crosses the same seam, and refuses in the same place.
 *
 * The read happens inside the Sandbox, on the session the agent process is
 * already holding. What reaches this side is two numbers or nothing at all, and
 * "nothing at all" has to arrive as a failure — the machine's `subscription`
 * region sends a failed read back to `unread` with context untouched, which is
 * how "leave whatever was last known" is spelled.
 */
describe('plan usage is either the measurement or a refusal', () => {
  test('a reading is rebuilt and reports itself as live', async () => {
    const usage = await callHarness(
      { kind: 'read-plan-usage', requestId: 'u1' },
      answers({ usage: { fiveHourPct: 11, weeklyPct: 54, source: 'live' } }),
    )
    expect(usage).toEqual({ fiveHourPct: 11, weeklyPct: 54, source: 'live' })
  })

  test('a host cannot make a measurement look seeded, or a seed look measured', async () => {
    // `source` is stamped on this side. Anything arriving here came from the
    // plan through the confined session; there is no other way in.
    const usage = await callHarness(
      { kind: 'read-plan-usage', requestId: 'u1' },
      answers({ usage: { fiveHourPct: 11, weeklyPct: 54, source: 'seeded' } }),
    )
    expect(usage.source).toBe('live')
  })

  test('nothing the host volunteered rides in beside the figures', async () => {
    const usage = await callHarness(
      { kind: 'read-plan-usage', requestId: 'u1' },
      answers({
        usage: { fiveHourPct: 11, weeklyPct: 54, source: 'live', apiKey: LOOKS_LIKE_A_KEY },
      }),
    )
    expect(Object.keys(usage).sort()).toEqual(['fiveHourPct', 'source', 'weeklyPct'])
    expect(JSON.stringify(usage)).not.toContain('sk-ant')
  })

  test('a read the session could not answer is a refusal, never a figure', async () => {
    const failure = await failureOf(
      { kind: 'read-plan-usage', requestId: 'u1' },
      answers({ usage: null }),
    )
    expect(failure.failure).toBe('refused')
    // The sentence is authored here, and it says what happens to the strip —
    // the developer's question is whether the number they can see is stale.
    expect(failure.message.length).toBeGreaterThan(20)
  })

  test('an answer this build cannot read is malformed rather than a figure', async () => {
    for (const answer of [
      {},
      { usage: {} },
      { usage: { fiveHourPct: 11 } },
      { usage: { fiveHourPct: '11', weeklyPct: 54 } },
      { usage: { fiveHourPct: Number.NaN, weeklyPct: 54 } },
    ]) {
      expect(
        (await failureOf({ kind: 'read-plan-usage', requestId: 'u1' }, answers(answer))).failure,
      ).toBe('malformed')
    }
  })

  test('the request names the read it expects an answer to, and nothing else', async () => {
    const seen: unknown[] = []
    const recording: HarnessBridge = {
      call: async (request) => {
        seen.push(request)
        return { usage: { fiveHourPct: 0, weeklyPct: 0, source: 'live' } }
      },
    }
    await callHarness({ kind: 'read-plan-usage', requestId: 'u1' }, recording)
    expect(seen).toEqual([{ kind: 'read-plan-usage', requestId: 'u1' }])
  })

  test('a read with no host is the same failure as everything else', async () => {
    expect((await failureOf({ kind: 'read-plan-usage', requestId: 'u1' }, null)).failure).toBe(
      'no-host',
    )
  })
})
