import { describe, expect, test } from 'bun:test'
import { answerHarnessLine, type HarnessCapabilities } from './runtime.ts'
import { callHarness, type HarnessBridge } from './bridge.ts'
import type { StoredMessage } from './session.ts'

/*
  The join, which nothing drove until it had already broken.

  Every other test in this package drives one side. `runtime.test.ts` asserts
  what the runtime writes; `bridge.test.ts` asserts what the client makes of an
  answer it was handed. Both passed while the runtime answered `{}` and the
  client threw `malformed` on anything without `ok: true` — each side agreed
  with itself and disagreed with the other, and the disagreement was the whole
  product: `check-sandbox` failed on every launch, so the Sandbox reported
  unavailable, so no agent could start, and the message shown blamed a version
  mismatch.

  ADR-0008 already named this gap in its last consequence — "nothing yet drives
  the Rust half against the real runtime process" — and reached for a runner on
  PATH as the reason it was hard. It is not hard. The Rust half is a pipe: it
  forwards the runtime's payload verbatim (src-tauri/src/bridge.rs) and its own
  framing is asserted against identical literals on both sides. What was missing
  is this, which needs no process at all.

  So: a real request, through the real runtime answer function, through the real
  client parser. If the two ever disagree again about the shape of an answer,
  this fails and nothing else does.
*/

/** The Rust host, as far as an answer is concerned: it forwards the payload. */
function bridgeOver(capabilities: HarnessCapabilities): HarnessBridge {
  let id = 0
  return {
    call: async (request) => {
      const line = await answerHarnessLine(JSON.stringify({ id: ++id, request }), capabilities)
      const reply = JSON.parse(line) as { ok?: unknown; error?: unknown }
      // What src-tauri/src/bridge.rs does with a reply: an `error` becomes a
      // rejection carrying the reason, an `ok` is handed over untouched.
      if (reply.error !== undefined) throw { failure: 'refused', detail: reply.error }
      return reply.ok
    },
  }
}

const capabilities = (over: Partial<HarnessCapabilities> = {}): HarnessCapabilities => ({
  establishSandbox: async () => ({}),
  wrapAgentCommand: async () => ({ argv: ['/bin/bash'], env: {}, cwd: '/tmp' }),
  persist: async () => ({ ok: true }) as { ok: true },
  readSession: async () => [],
  ...over,
})

describe('the runtime and the client agree about the shape of an answer', () => {
  test('a sandbox check comes back as a success rather than as malformed', async () => {
    // The one that was broken. `{}` here made every launch report
    // sandbox.unavailable with a message about mismatched versions.
    const answer = await callHarness({ kind: 'check-sandbox' }, bridgeOver(capabilities()))
    expect(answer).toEqual({ ok: true })
  })

  test('a save comes back as a success rather than as malformed', async () => {
    const messages: StoredMessage[] = [{ id: 'm1', role: 'user', text: 'mirror this' }]
    const answer = await callHarness(
      { kind: 'persist-session', sessionId: 's1', messages },
      bridgeOver(capabilities()),
    )
    expect(answer).toEqual({ ok: true })
  })

  test('a restore comes back as the transcript it read', async () => {
    const stored: StoredMessage[] = [{ id: 'm1', role: 'agent', text: 'kept' }]
    const answer = await callHarness(
      { kind: 'read-session', sessionId: 's1' },
      bridgeOver(capabilities({ readSession: async () => stored })),
    )
    expect(answer).toEqual({ messages: stored, redacted: false })
  })

  test('a capability that throws reaches the caller as a refusal, with its reason', async () => {
    // The other half of the contract: a failure has to arrive as one, carrying
    // the sentence sandbox.unavailable renders.
    const failing = capabilities({
      establishSandbox: async () => {
        throw new Error('sandbox-runtime does not support this platform')
      },
    })
    await expect(
      callHarness({ kind: 'check-sandbox' }, bridgeOver(failing)),
    ).rejects.toThrow(/does not support this platform/)
  })

  test('the credential is refused by the runtime, whatever the client asks for', async () => {
    // Routing keeps this away from the runtime, but the runtime refuses it too —
    // an unhandled case is a case someone can quietly implement.
    await expect(
      callHarness({ kind: 'read-credential' }, bridgeOver(capabilities())),
    ).rejects.toThrow(/does not read the credential/)
  })
})
