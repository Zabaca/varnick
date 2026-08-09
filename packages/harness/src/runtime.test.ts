import { describe, expect, test } from 'bun:test'
import { answerHarnessLine, hostCapabilities, type HarnessCapabilities } from './runtime.ts'
import { openSecretsStore, SECRETS_INDEX_ACCOUNT } from './secrets.ts'
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
  reads: string[]
  secretNameReads: number
  worktreeListings: number
  fenceDiffs: string[]
}

function capabilities(
  overrides: Partial<HarnessCapabilities> = {},
): HarnessCapabilities & { recorded: Recorded } {
  const recorded: Recorded = {
    sandboxChecks: 0,
    saves: [],
    reads: [],
    secretNameReads: 0,
    worktreeListings: 0,
    fenceDiffs: [],
  }
  return {
    recorded,
    establishSandbox: async () => {
      recorded.sandboxChecks += 1
    },
    wrapAgentCommand: async () => ({
      argv: ['/bin/bash', '-c', 'sandbox-exec ... agent.ts'],
      env: { SANDBOX_RUNTIME: '1' },
      cwd: '/Users/dev/code/varnick',
    }),
    persist: async (input) => {
      recorded.saves.push(input)
      return { ok: true as const }
    },
    readSession: async (sessionId) => {
      recorded.reads.push(sessionId)
      return []
    },
    readCommands: async () => [],
    readSecretNames: async () => {
      recorded.secretNameReads += 1
      return ['STRIPE_KEY']
    },
    listWorktrees: async () => {
      recorded.worktreeListings += 1
      return []
    },
    readFenceDiff: async (worktree) => {
      recorded.fenceDiffs.push(worktree)
      return ''
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
    expect(await reply(call(17, { kind: 'check-sandbox' }))).toMatchObject({ id: 17, ok: { ok: true } })
  })
})

describe('check-sandbox establishes the real sandbox', () => {
  test('the capability is called and the answer carries nothing from it', async () => {
    const caps = capabilities({ establishSandbox: async () => ({ policy: { denyRead: ['/Users'] } }) })
    expect(await reply(call(1, { kind: 'check-sandbox' }), caps)).toEqual({ id: 1, ok: { ok: true } })
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
    expect(answer).toEqual({ id: 1, ok: { ok: true } })
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

describe('read-session is how a relaunch continues the conversation', () => {
  test('the transcript comes back, with whether it is a redacted record', async () => {
    const caps = capabilities({
      readSession: async () => [
        { id: 'm1', role: 'user', text: 'use [redacted] for the call' },
        { id: 'm2', role: 'agent', text: 'done' },
      ],
    })

    expect(await reply(call(1, { kind: 'read-session', sessionId: 'abc' }), caps)).toEqual({
      id: 1,
      ok: {
        messages: [
          { id: 'm1', role: 'user', text: 'use [redacted] for the call' },
          { id: 'm2', role: 'agent', text: 'done' },
        ],
        redacted: true,
      },
    })
  })

  test('the Session asked for is the Session read', async () => {
    const caps = capabilities()
    await reply(call(1, { kind: 'read-session', sessionId: 'session-1' }), caps)
    expect(caps.recorded.reads).toEqual(['session-1'])
  })

  test('a Session with nothing mirrored answers empty rather than refusing', async () => {
    const caps = capabilities()
    expect(await reply(call(1, { kind: 'read-session', sessionId: 'fresh' }), caps)).toEqual({
      id: 1,
      ok: { messages: [], redacted: false },
    })
  })

  test('a read that failed answers with the reason rather than an empty transcript', async () => {
    // Answering `[]` here would look like a first run and let the next save
    // replace a transcript nobody managed to read.
    const caps = capabilities({
      readSession: async () => {
        throw new Error('EACCES: permission denied')
      },
    })
    const answer = await reply(call(1, { kind: 'read-session', sessionId: 'a' }), caps)
    expect(answer.ok).toBeUndefined()
    expect(answer.error).toContain('EACCES')
  })

  test('a request with no Session id never reaches the store', async () => {
    const caps = capabilities()
    expect((await reply(call(1, { kind: 'read-session' }), caps)).ok).toBeUndefined()
    expect((await reply(call(2, { kind: 'read-session', sessionId: 7 }), caps)).ok).toBeUndefined()
    expect(caps.recorded.reads).toEqual([])
  })
})

describe('the credential is the host’s, never the runtime’s', () => {
  test('a runtime asked for a credential refuses instead of finding a way', async () => {
    const answer = await reply(call(1, { kind: 'read-credential' }))
    expect(answer.ok).toBeUndefined()
    expect(String(answer.error)).toContain('credential')
  })
})

describe('wrap-agent-command computes the wrapping and nothing else', () => {
  test('the answer is argv, an overlay and the directory to spawn in', async () => {
    const answer = await reply(call(1, { kind: 'wrap-agent-command' }))
    expect(answer.ok).toEqual({
      argv: ['/bin/bash', '-c', 'sandbox-exec ... agent.ts'],
      env: { SANDBOX_RUNTIME: '1' },
      cwd: '/Users/dev/code/varnick',
    })
  })

  test('the runtime refuses when the Sandbox is not established', async () => {
    // The product's only real claim. There is no flag, no environment variable
    // and no state in which this answers anything but a refusal — and because
    // the Rust host spawns nothing without this answer, the refusal is what
    // makes "no fallback to unconfined" structural rather than a rule.
    const caps = capabilities({
      wrapAgentCommand: async () => {
        throw new Error('The Sandbox is not established, so no agent may be started.')
      },
    })
    const answer = await reply(call(1, { kind: 'wrap-agent-command' }), caps)
    expect(answer.ok).toBeUndefined()
    expect(String(answer.error)).toContain('not established')
  })

  test('the answer carries no environment beyond the overlay', async () => {
    // The overlay crosses a pipe to the process that holds the credential. The
    // whole environment must not, because the runtime inherits the host's.
    const caps = capabilities({
      wrapAgentCommand: async () => ({
        argv: ['/bin/bash', '-c', 'agent'],
        env: { HTTPS_PROXY: 'http://srt:tok@localhost:1' },
        cwd: '/clone',
      }),
    })
    const answer = await reply(call(1, { kind: 'wrap-agent-command' }), caps)
    expect(JSON.stringify(answer)).not.toContain('sk-ant')
    expect(Object.keys((answer.ok as { env: Record<string, string> }).env)).toEqual(['HTTPS_PROXY'])
  })

  test('the real capabilities refuse to wrap an agent before a Sandbox exists', async () => {
    // Not the injected double: the actual gate, in the actual object the
    // runtime process uses. Nothing here establishes a Sandbox, so this is the
    // state a run is in before `check-sandbox` succeeds — and it is the state a
    // run stays in when `check-sandbox` fails. No flag reaches past it, because
    // there is no flag: the only thing that sets the Sandbox is establishing
    // one.
    await expect(
      hostCapabilities({ cloneRoot: process.cwd() }).wrapAgentCommand(),
    ).rejects.toThrow(/not established/)
  })

  test('the real capabilities are built for one named root', async () => {
    // Ticket 28. `hostCapabilities()` took nothing and the root arrived from
    // `process.cwd()` four hops later; it is an argument now, and the Sandbox
    // this refuses to establish is the one for the root it was given.
    await expect(
      hostCapabilities({ cloneRoot: '/Users/dev/moved-away-1234' }).establishSandbox(),
    ).rejects.toThrow(/no directory at \/Users\/dev\/moved-away-1234/)
  })

  test('the runtime never spawns the agent itself', async () => {
    // ADR-0008's third rejection. The runtime holds the Sandbox, so spawning
    // here reads as natural — and would mean sending the credential across the
    // bridge. `spawn-agent` is not a kind this process answers, and that is the
    // assertion, not a comment.
    const answer = await reply(call(1, { kind: 'spawn-agent' }))
    expect(answer.ok).toBeUndefined()
    expect(String(answer.error)).toContain('spawn-agent')
  })
})

/*
  ADR-0006's naming end, at the only process that can answer it.

  The Secrets Store is a keychain under `$HOME`; the agent host is inside the
  Sandbox and the Rust host does not read it. So this is where "which secrets
  exist" is answered, and — because the values are in this process too — it is
  where the claim that only names leave has to be taken.

  No test here touches a real keychain. `openSecretsStore` takes a
  `SecretsKeychain` and has no default, so it cannot be reached by forgetting an
  argument.
*/
describe('read-secret-names answers with names and never a value', () => {
  /** A value shaped like a real key, so a leak is greppable rather than subtle. */
  const STRIPE = ['sk_live_', 'NEVER_LEAVES_THE_HOST'].join('')

  /** A keychain in a Map, and the real store over it. */
  const storeOver = (items: Map<string, string>) =>
    openSecretsStore({
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

  test('the names come back', async () => {
    const answer = await reply(call(1, { kind: 'read-secret-names' }))
    expect(answer.ok).toEqual({ names: ['STRIPE_KEY'] })
  })

  test('the value is nowhere on the wire, over a real store holding a real one', async () => {
    // The assertion, taken on the serialised line rather than on an object: the
    // line is what crosses to the Rust host and then to the confined process,
    // and a value that is not in it is a value that cannot arrive there.
    const store = await storeOver(new Map<string, string>())
    await store.store('STRIPE_KEY', STRIPE)

    const raw = await answerHarnessLine(
      call(1, { kind: 'read-secret-names' }),
      capabilities({ readSecretNames: async () => store.names() }),
    )
    expect(raw).toContain('STRIPE_KEY')
    expect(raw).not.toContain(STRIPE)
  })

  test('a secret added by another process is named without a relaunch', async () => {
    /*
      The whole reason this is a call rather than a variable in the spawn
      environment. `bun run secret add` runs in a different process against the
      same keychain, so the store this one holds is a stale snapshot until it is
      re-read — which is exactly what ticket 06 had to do for the mirror, and
      the same answer is right here.

      The store is the real one; "the other process" is a write straight into
      the keychain behind its back, which is what another process looks like
      from in here.
    */
    const items = new Map<string, string>()
    const store = await storeOver(items)
    await store.store('STRIPE_KEY', STRIPE)

    const capability = capabilities({
      readSecretNames: async () => {
        await store.reload()
        return store.names()
      },
    })

    items.set('BILLING_TOKEN', 'tok_added_later')
    items.set(SECRETS_INDEX_ACCOUNT, JSON.stringify(['STRIPE_KEY', 'BILLING_TOKEN']))

    const answer = await reply(call(1, { kind: 'read-secret-names' }), capability)
    expect(answer.ok).toEqual({ names: ['STRIPE_KEY', 'BILLING_TOKEN'] })
  })

  test('the answer is rebuilt, so nothing rides along with the names', async () => {
    const extra = ['sk_live_', 'VOLUNTEERED'].join('')
    const raw = await answerHarnessLine(
      call(1, { kind: 'read-secret-names' }),
      capabilities({
        readSecretNames: async () =>
          Object.assign(['STRIPE_KEY'], { values: [extra] }) as readonly string[],
      }),
    )
    expect(JSON.parse(raw)).toMatchObject({ id: 1, ok: { names: ['STRIPE_KEY'] } })
    expect(raw).not.toContain(extra)
  })
})

/*
  The review list, which is git's answer rather than anybody's account of it.

  Answered here because this process has a filesystem and can spawn a
  subprocess. Nothing in this file runs git: `listWorktrees` is a capability, so
  the tests are about what crosses the wire, and packages/harness/src/worktrees.ts
  is where the commands themselves are asserted.
*/
describe('list-worktrees answers with what git said', () => {
  const pending = {
    path: '/Users/dev/code/varnick/.claude/worktrees/49',
    branch: 'ticket/49',
    commits: 3,
    changed: ['src-tauri/src/bridge.rs'],
    touchesFence: true,
  }

  test('the entries come back', async () => {
    const answer = await reply(
      call(1, { kind: 'list-worktrees' }),
      capabilities({ listWorktrees: async () => [pending] }),
    )
    expect(answer.ok).toEqual({ worktrees: [pending] })
  })

  test('nothing pending is an answer rather than a refusal', async () => {
    // `review.empty` and `review.listFailed` are two states because they are two
    // problems. This is the first one, and it must not arrive as the second.
    const caps = capabilities()
    const answer = await reply(call(1, { kind: 'list-worktrees' }), caps)
    expect(answer.ok).toEqual({ worktrees: [] })
    expect(caps.recorded.worktreeListings).toBe(1)
  })

  test('a git that failed answers with the reason rather than an empty list', async () => {
    const answer = await reply(
      call(1, { kind: 'list-worktrees' }),
      capabilities({
        listWorktrees: async () => {
          throw new Error('fatal: not a git repository')
        },
      }),
    )
    expect(answer.ok).toBeUndefined()
    expect(answer.error).toBe('fatal: not a git repository')
  })

  test('the answer is rebuilt, so nothing rides along with the entries', async () => {
    /*
      A body volunteered beside the summary is the failure this rebuild is for.
      The list carries names and counts; the hunks are fetched for the one
      worktree a developer opens, and a diff arriving here would be rendered by a
      surface that promised not to read one — at the size of every branch at once.
    */
    const raw = await answerHarnessLine(
      call(1, { kind: 'list-worktrees' }),
      capabilities({
        listWorktrees: async () =>
          [{ ...pending, diff: '@@ -1 +1 @@ VOLUNTEERED' }] as never,
      }),
    )
    expect(raw).not.toContain('VOLUNTEERED')
    expect(JSON.parse(raw)).toMatchObject({ id: 1, ok: { worktrees: [pending] } })
  })
})

describe('read-fence-diff answers with hunks and takes a path it was given', () => {
  test('the worktree it names is the one the diff is taken in', async () => {
    const caps = capabilities()
    const answer = await reply(
      call(1, {
        kind: 'read-fence-diff',
        worktree: '/Users/dev/varnick/.claude/worktrees/agent-one',
      }),
      caps,
    )
    expect(answer.ok).toEqual({ hunks: '' })
    expect(caps.recorded.fenceDiffs).toEqual([
      '/Users/dev/varnick/.claude/worktrees/agent-one',
    ])
  })

  test('an empty answer is the answer that launches without a dialog', async () => {
    // One condition on the dialog, and this is the value of it. A worktree
    // whose Fence matches the running one is a Preview nobody is asked about.
    const answer = await reply(
      call(1, { kind: 'read-fence-diff', worktree: '/w' }),
      capabilities({ readFenceDiff: async () => '' }),
    )
    expect(answer.ok).toEqual({ hunks: '' })
  })

  test('the hunks cross as git wrote them, newlines and all, on one line', async () => {
    const hunks = 'diff --git a/src-tauri/src/credential.rs b/…\n@@ -1 +1 @@\n-a\n+b\n'
    const raw = await answerHarnessLine(
      call(1, { kind: 'read-fence-diff', worktree: '/w' }),
      capabilities({ readFenceDiff: async () => hunks }),
    )
    // A diff is the one answer on this pipe that is full of newlines, and the
    // framing is one reply per line. `JSON.stringify` is what holds that.
    expect(raw.slice(0, -1)).not.toContain('\n')
    expect((JSON.parse(raw) as { ok: { hunks: string } }).ok.hunks).toBe(hunks)
  })

  test('a request naming no worktree is refused rather than defaulted', async () => {
    // There is no sensible default. The live tree would be the one worth
    // guessing at, and a diff of the live tree against itself is empty — which
    // reads as "no fence change" for a request that named nothing.
    for (const request of [
      { kind: 'read-fence-diff' },
      { kind: 'read-fence-diff', worktree: '' },
      { kind: 'read-fence-diff', worktree: 3 },
    ]) {
      const answer = await reply(call(1, request))
      expect(answer.ok).toBeUndefined()
      expect(answer.error).toBeTypeOf('string')
    }
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
