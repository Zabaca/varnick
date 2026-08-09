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
  readCommands: async () => [],
  readSecretNames: async () => [],
  listWorktrees: async () => [],
  readFenceDiff: async () => '',
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

/*
  The stored-message shape, checked at both ends rather than written once.

  A message is validated twice crossing this seam, by two functions in two
  files. `storedMessage` in runtime.ts decides what may be written to the
  mirror; the transcript reader in bridge.ts decides what may come back into a
  machine's context. They are deliberately not one function: bridge.ts is
  bundled into the webview and must reach no Node, runtime.ts imports the
  filesystem, and a shared parser would be a module the renderer pulls the host
  half in through. They are also not redundant — they guard opposite directions,
  and neither can be dropped in favour of the other.

  What that costs is an agreement nothing kept. Adding a role to one and not the
  other makes a transcript the mirror will happily store into `malformed` on the
  way back, which presents as a corrupt mirror rather than as a missing line of
  code. So the two are driven over the same values here, asserting only that
  they answer the same way. A shared abstraction would have made them agree by
  construction and coupled two processes to do it; this fails the moment they
  stop agreeing and constrains nothing else.
*/

/** A message value, as it would arrive from either direction. */
const CANDIDATES: readonly { readonly what: string; readonly value: unknown }[] = [
  { what: 'a message from the developer', value: { id: 'm1', role: 'user', text: 'one' } },
  { what: 'a message from the agent', value: { id: 'm2', role: 'agent', text: 'two' } },
  { what: 'an empty text, which is a message that said nothing', value: { id: 'm3', role: 'user', text: '' } },
  { what: 'a role neither end has agreed to', value: { id: 'm4', role: 'system', text: 'three' } },
  { what: 'no id', value: { role: 'user', text: 'four' } },
  { what: 'no text', value: { id: 'm5', role: 'user' } },
  { what: 'an id that is not a string', value: { id: 5, role: 'user', text: 'five' } },
  { what: 'nothing at all', value: null },
]

/** Whether the mirror would store it. `persist-session`, the way in. */
async function storable(value: unknown): Promise<boolean> {
  return await callHarness(
    {
      kind: 'persist-session',
      sessionId: 's1',
      messages: [value] as readonly StoredMessage[],
    },
    bridgeOver(capabilities()),
  ).then(
    () => true,
    () => false,
  )
}

/** Whether a machine would take it back. `read-session`, the way out. */
async function restorable(value: unknown): Promise<boolean> {
  return await callHarness(
    { kind: 'read-session', sessionId: 's1' },
    bridgeOver(
      capabilities({ readSession: async () => [value] as readonly StoredMessage[] }),
    ),
  ).then(
    () => true,
    () => false,
  )
}

describe('the two ends agree about what a stored message is', () => {
  for (const { what, value } of CANDIDATES) {
    test(what, async () => {
      // Deliberately not asserting *which* answer: the point is that a shape
      // the mirror accepts is a shape a relaunch can read, whatever the two of
      // them decide that shape is.
      expect(await storable(value)).toBe(await restorable(value))
    })
  }

  test('a field neither end agreed to reaches neither the mirror nor a machine', async () => {
    // Both sides rebuild rather than forward, and both say so. Driven here
    // because a sender that volunteered a field is exactly the sender that
    // would put something in the transcript a developer later reads.
    const volunteered = { id: 'm1', role: 'user', text: 'one', note: 'not part of the shape' }

    let persisted: readonly StoredMessage[] = []
    await callHarness(
      {
        kind: 'persist-session',
        sessionId: 's1',
        messages: [volunteered] as readonly StoredMessage[],
      },
      bridgeOver(
        capabilities({
          persist: async ({ messages }) => {
            persisted = messages
            return { ok: true } as { ok: true }
          },
        }),
      ),
    )
    expect(persisted).toEqual([{ id: 'm1', role: 'user', text: 'one' }])

    const restored = await callHarness(
      { kind: 'read-session', sessionId: 's1' },
      bridgeOver(
        capabilities({ readSession: async () => [volunteered] as readonly StoredMessage[] }),
      ),
    )
    expect(restored).toEqual({ messages: [{ id: 'm1', role: 'user', text: 'one' }], redacted: false })
  })
})
