import { describe, expect, test } from 'bun:test'
import { answerHarnessLine, type HarnessCapabilities } from './runtime.ts'
import type { StoredMessage } from './session.ts'

/**
 * The seam: one line in, one line out.
 *
 * The runtime is the host-side half of the bridge — the process that holds the
 * Sandbox and owns the Session mirror. Its whole interface with the Tauri host
 * is newline-delimited JSON, so that is what is tested: no child process is
 * spawned here, no sandbox is established, and nothing is written to disk. Every
 * test supplies its own {@link HarnessCapabilities}.
 */

interface Recorded {
  sandboxChecks: number
  saves: { sessionId: string; messages: readonly StoredMessage[] }[]
}

function capabilities(
  overrides: Partial<HarnessCapabilities> = {},
): HarnessCapabilities & { recorded: Recorded } {
  const recorded: Recorded = { sandboxChecks: 0, saves: [] }
  return {
    recorded,
    establishSandbox: async () => {
      recorded.sandboxChecks += 1
    },
    persist: async (input) => {
      recorded.saves.push(input)
      return { ok: true as const }
    },
    ...overrides,
  }
}

const reply = async (line: string, caps: HarnessCapabilities = capabilities()) =>
  JSON.parse(await answerHarnessLine(line, caps)) as Record<string, unknown>

const call = (id: number, request: unknown) => JSON.stringify({ id, request })

describe('the reply is one line, always', () => {
  test('every reply ends with exactly one newline and holds no other', async () => {
    const lines = [
      call(1, { kind: 'check-sandbox' }),
      call(2, { kind: 'persist-session', sessionId: 's', messages: [] }),
      call(3, { kind: 'nonsense' }),
      'not json at all',
    ]
    for (const line of lines) {
      const raw = await answerHarnessLine(line, capabilities())
      expect(raw.endsWith('\n')).toBe(true)
      expect(raw.slice(0, -1)).not.toContain('\n')
    }
  })

  test('a reason with a newline in it cannot desynchronise the pipe', async () => {
    const caps = capabilities({
      establishSandbox: async () => {
        throw new Error('line one\nline two')
      },
    })
    const raw = await answerHarnessLine(call(1, { kind: 'check-sandbox' }), caps)
    expect(raw.slice(0, -1)).not.toContain('\n')
    expect(JSON.parse(raw)).toMatchObject({ id: 1, error: 'line one\nline two' })
  })

  test('the id comes back so a desynchronised pipe is detectable', async () => {
    expect(await reply(call(17, { kind: 'check-sandbox' }))).toMatchObject({ id: 17, ok: {} })
  })
})

describe('check-sandbox establishes the real sandbox', () => {
  test('the capability is called and the answer carries nothing from it', async () => {
    const caps = capabilities({ establishSandbox: async () => ({ policy: { denyRead: ['/Users'] } }) })
    expect(await reply(call(1, { kind: 'check-sandbox' }), caps)).toEqual({ id: 1, ok: {} })
  })

  test('a sandbox that cannot be established answers with the reason, never with ok', async () => {
    const caps = capabilities({
      establishSandbox: async () => {
        throw new Error('sandbox-runtime does not support win32.')
      },
    })
    const answer = await reply(call(1, { kind: 'check-sandbox' }), caps)
    expect(answer.ok).toBeUndefined()
    expect(answer.error).toContain('does not support win32')
  })
})

describe('persist-session writes through the mirror', () => {
  test('the store is handed the session and its messages', async () => {
    const caps = capabilities()
    const messages: StoredMessage[] = [{ id: 'm1', role: 'user', text: 'hello' }]
    const answer = await reply(call(1, { kind: 'persist-session', sessionId: 'abc', messages }), caps)
    expect(answer).toEqual({ id: 1, ok: {} })
    expect(caps.recorded.saves).toEqual([{ sessionId: 'abc', messages }])
  })

  test('a save that failed answers with the reason rather than ok', async () => {
    const caps = capabilities({
      persist: async () => {
        throw new Error('ENOSPC: no space left on device')
      },
    })
    const answer = await reply(call(1, { kind: 'persist-session', sessionId: 'a', messages: [] }), caps)
    expect(answer.ok).toBeUndefined()
    expect(answer.error).toContain('ENOSPC')
  })

  test('a request the runtime cannot read never reaches the store', async () => {
    const caps = capabilities()
    const bad = [
      { kind: 'persist-session', sessionId: 42, messages: [] },
      { kind: 'persist-session', sessionId: 'a', messages: 'not an array' },
      { kind: 'persist-session', sessionId: 'a', messages: [{ id: 'm', role: 'wizard', text: '' }] },
      { kind: 'persist-session', sessionId: 'a' },
    ]
    for (const request of bad) {
      expect((await reply(call(1, request), caps)).ok).toBeUndefined()
    }
    expect(caps.recorded.saves).toEqual([])
  })

  test('only the three fields the mirror stores cross, whatever else was sent', async () => {
    const caps = capabilities()
    const messages = [{ id: 'm1', role: 'user', text: 'hello', apiKey: 'sk-ant-LEAK' }]
    await reply(call(1, { kind: 'persist-session', sessionId: 'a', messages }), caps)
    expect(caps.recorded.saves[0]?.messages).toEqual([{ id: 'm1', role: 'user', text: 'hello' }])
  })
})

describe('the credential is the host’s, never the runtime’s', () => {
  test('a runtime asked for a credential refuses instead of finding a way', async () => {
    const answer = await reply(call(1, { kind: 'read-credential' }))
    expect(answer.ok).toBeUndefined()
    expect(String(answer.error)).toContain('credential')
  })
})

describe('a bad line does not take the runtime down', () => {
  test('a line that is not JSON answers rather than throwing', async () => {
    const answer = await reply('}{')
    expect(answer.id).toBeNull()
    expect(answer.error).toBeTypeOf('string')
  })

  test('a kind the runtime does not know is refused', async () => {
    const answer = await reply(call(1, { kind: 'spawn-agent' }))
    expect(answer.ok).toBeUndefined()
    expect(answer.error).toBeTypeOf('string')
  })

  test('a call with no id at all is still answered', async () => {
    const answer = await reply(JSON.stringify({ request: { kind: 'check-sandbox' } }))
    expect(answer.id).toBeNull()
    expect(answer.error).toBeTypeOf('string')
  })
})
