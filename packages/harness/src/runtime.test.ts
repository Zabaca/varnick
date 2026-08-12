import { describe, expect, test } from 'bun:test'
import {
  answerHarnessLine,
  hostCapabilities,
  traceLine,
  UNTRACED_KINDS,
  worthTracing,
  type HarnessCapabilities,
} from './runtime.ts'
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
  diffReads: string[]
  merges: string[]
  /** Which Worktree paths the agent's landing tool reached the runtime with. */
  landings: string[]
  /** Which feature slugs its release tool did. */
  releases: string[]
  reaps: string[]
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
    diffReads: [],
    merges: [],
    landings: [],
    releases: [],
    reaps: [],
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
    liveTreeDirty: async () => false,
    readWorktreeDiff: async (path) => {
      recorded.diffReads.push(path)
      return ''
    },
    /*
      The default merges nothing and records that it was asked.

      A capability that actually merged would be a unit test writing this
      repository's own history, which is the reason nothing in this file runs
      git — packages/harness/src/merge.test.ts is where the sequence itself is
      asserted, against ports.
    */
    mergeWorktree: async (path) => {
      recorded.merges.push(path)
      return {
        branch: 'ticket/49',
        commit: 'abc1234',
        squashed: 3,
        worktreeRemoved: true,
        branchDeleted: true,
        heldBy: [],
        leftOver: null,
      }
    },
    // Records like the merge does, and for the same reason: the property under
    // the runtime's tests is which path crossed, not what git would have done
    // with it.
    readPendingRelease: async () => null,
    promoteRelease: async () => ({ promoted: false, reason: 'not in this test' }),
    /*
      The agent's two asks, recorded rather than performed, for the reason the
      merge above is: what these tests hold is which string crossed the runtime's
      dispatch, not what git or a release script would have done with it. The
      gate itself is proved in packages/harness/src/landing.test.ts, against
      ports, with no repository at all.
    */
    landWorktree: async (path) => {
      recorded.landings.push(path)
      return { outcome: 'refused' as const, detail: 'not in this test' }
    },
    cutPreRelease: async (feature) => {
      recorded.releases.push(feature)
      return { outcome: 'refused' as const, detail: 'not in this test' }
    },
    reapWorktree: async (path) => {
      recorded.reaps.push(path)
      return {
        path,
        branch: 'ticket/49',
        worktreeRemoved: true,
        branchDeleted: true,
        heldBy: [],
        leftOver: null,
      }
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
    merge: { kind: 'clean' as const },
    landed: false,
  }

  test('the entries come back', async () => {
    const answer = await reply(
      call(1, { kind: 'list-worktrees' }),
      capabilities({ listWorktrees: async () => [pending] }),
    )
    expect(answer.ok).toEqual({ worktrees: [pending], liveTreeDirty: false })
  })

  test('nothing pending is an answer rather than a refusal', async () => {
    // `review.empty` and `review.listFailed` are two states because they are two
    // problems. This is the first one, and it must not arrive as the second.
    const caps = capabilities()
    const answer = await reply(call(1, { kind: 'list-worktrees' }), caps)
    expect(answer.ok).toEqual({ worktrees: [], liveTreeDirty: false })
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

/*
  `read-fence-diff` was here.

  It answered the diff the approval dialog in front of a Preview showed, and its
  tests were about the one distinction that mattered: an empty diff launched
  without asking, and a git that would not answer refused the launch rather than
  launching with an empty dialog. Both went with the dialog — a Preview is
  confined by the live tree's policy now, so there is nothing to approve
  (ADR-0019). What replaced the assertions is a measurement:
  `containment.probe.test.ts` runs a command under the policy a Preview would
  get and reports what it reached.
*/

/*
  The hunks of the one worktree a developer opened.

  The only call on the review path carrying a field, so the tests here are about
  the field: that it reaches the capability unchanged, that a request without one
  is refused rather than guessed at, and that a capability which refused the path
  refuses the call. Which paths are *allowed* is worktrees.ts's assertion — this
  is the wire.
*/
describe('read-worktree-diff answers with the hunks git printed', () => {
  const opened = '/Users/dev/code/varnick/.claude/worktrees/49'
  const hunks = 'diff --git a/x b/x\n@@ -1 +1 @@\n-was\n+is\n'

  test('the diff comes back, for the worktree that was asked about', async () => {
    const asked: string[] = []
    const answer = await reply(
      call(1, { kind: 'read-worktree-diff', path: opened }),
      capabilities({
        readWorktreeDiff: async (path) => {
          asked.push(path)
          return hunks
        },
      }),
    )
    expect(answer.ok).toEqual({ diff: hunks })
    // The path crosses unchanged. Which paths may be opened is decided against
    // git's own listing one layer down, and asserted in worktrees.test.ts.
    expect(asked).toEqual([opened])
  })

  test('a request naming no worktree is refused rather than answered about some other one', async () => {
    const caps = capabilities()
    const answer = await reply(call(1, { kind: 'read-worktree-diff' }), caps)
    expect(answer.ok).toBeUndefined()
    expect(answer.error).toBeTypeOf('string')
    expect(caps.recorded.diffReads).toEqual([])
  })

  test('a path that is not a pending worktree is the capability’s refusal, carried through', async () => {
    const answer = await reply(
      call(1, { kind: 'read-worktree-diff', path: '/somewhere/else' }),
      capabilities({
        readWorktreeDiff: async () => {
          throw new Error('/somewhere/else is not a worktree with unmerged commits')
        },
      }),
    )
    expect(answer.ok).toBeUndefined()
    expect(answer.error).toContain('not a worktree')
  })

  test('an empty diff is an answer rather than a refusal', async () => {
    const answer = await reply(call(1, { kind: 'read-worktree-diff', path: opened }))
    expect(answer.ok).toEqual({ diff: '' })
  })

  test('a diff with a newline in every line still crosses as one line', async () => {
    // The framing this pipe rests on, exercised by the one call whose payload is
    // guaranteed to be full of newlines. `serde_json` and `JSON.stringify` both
    // escape them; that is what makes "one call per line" a framing rather than
    // a hope, and a diff is where it would first stop being true.
    const raw = await answerHarnessLine(
      call(1, { kind: 'read-worktree-diff', path: opened }),
      capabilities({ readWorktreeDiff: async () => hunks }),
    )
    expect(raw.endsWith('\n')).toBe(true)
    expect(raw.slice(0, -1)).not.toContain('\n')
    expect(JSON.parse(raw)).toMatchObject({ id: 1, ok: { diff: hunks } })
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

// ---------------------------------------------------------------------------
// The trace, which exists because a merge that wrote nothing left nothing to read
// ---------------------------------------------------------------------------

describe('the agent’s two asks reach the capability that gates them', () => {
  /*
    The dispatch and nothing else. What the gate decides is
    packages/harness/src/landing.test.ts, and what a release does is
    `packages/core/scripts/release.ts` — here the property is that the request
    reaches the right capability with the right string, and that a request naming
    nothing does not quietly become a request naming something.
  */

  test('a landing forwards the selector and answers with the outcome and its reason', async () => {
    const caps = capabilities()
    const answer = await reply(
      call(1, { kind: 'land-worktree', path: '/w/49' }),
      caps,
    )
    expect(caps.recorded.landings).toEqual(['/w/49'])
    expect(answer).toEqual({
      id: 1,
      ok: { outcome: 'refused', detail: 'not in this test' },
    })
  })

  test('a landing that names no worktree is refused rather than defaulted', async () => {
    // Picking one would be the host choosing which of the agent's branches to
    // write into the developer's tree.
    const caps = capabilities()
    for (const request of [
      { kind: 'land-worktree' },
      { kind: 'land-worktree', path: '' },
      { kind: 'land-worktree', path: 42 },
    ]) {
      const answer = await reply(call(1, request), caps)
      expect(answer.ok).toBeUndefined()
      expect(answer.error).toContain('named none')
    }
    expect(caps.recorded.landings).toEqual([])
  })

  test('a release forwards the slug, and a request with none reaches the shape check', async () => {
    const caps = capabilities()
    expect(await reply(call(1, { kind: 'cut-release', feature: 'autonomous-runs' }), caps)).toEqual({
      id: 1,
      ok: { outcome: 'refused', detail: 'not in this test' },
    })
    await reply(call(2, { kind: 'cut-release' }), caps)
    // The empty string rather than a guess: it is not a feature slug, and the
    // capability says so in one sentence instead of the dispatch inventing one.
    expect(caps.recorded.releases).toEqual(['autonomous-runs', ''])
  })

  test('the real capability refuses a slug that could climb or flag, before anything is spawned', async () => {
    /*
      `hostCapabilities` rather than a stub, because this is the one check that
      stands between an agent's string and an argv. A stub that answered
      `not-a-feature` would prove nothing about the code that runs.

      Only refusals are asked for here: every one of these returns before the
      spawn, so no test in this file starts a release.
    */
    const real = hostCapabilities({ cloneRoot: '/Users/dev/code/varnick' })
    for (const shapeless of ['', '..', '../../etc', '-f', '--json', 'runs/../..', 'a b']) {
      expect(await real.cutPreRelease(shapeless), shapeless).toEqual({
        outcome: 'not-a-feature',
        detail: null,
      })
    }
  })

  test('both are traced, because both write the developer’s clone', async () => {
    // The defect the tracing came from was a merge that left nothing to read.
    // These are the same write asked for by a process nobody is watching.
    expect(worthTracing('land-worktree')).toBe(true)
    expect(worthTracing('cut-release')).toBe(true)
  })
})

describe('every act the runtime performs is traceable', () => {
  /*
    The defect this comes from. A merge writes the developer's repository, and it
    did so with no observable trace anywhere: no line in the runtime, none in the
    host, and none in git's reflog until a commit succeeds. When a merge did not
    happen there was nothing at all to read — and nothing to tell "Core never
    sent it" apart from "the runtime refused it", which is a debugging session
    that has to guess.
  */

  const traced = async (line: string, caps: HarnessCapabilities = capabilities()) => {
    const lines: string[] = []
    await answerHarnessLine(line, caps, (written) => lines.push(written), () => 0)
    return lines
  }

  test('an act that succeeds says so, with its kind', async () => {
    const [line] = await traced(call(1, { kind: 'check-sandbox' }))
    expect(line).toContain('check-sandbox')
    expect(line).toContain('ok')
  })

  test('an act that fails carries what it said', async () => {
    const [line] = await traced(
      call(1, { kind: 'merge-worktree', path: '/w/x' }),
      capabilities({
        mergeWorktree: async () => {
          throw new Error('The live tree has uncommitted work in DESIGN.md.')
        },
      }),
    )
    expect(line).toContain('merge-worktree')
    expect(line).toContain('failed')
    expect(line).toContain('DESIGN.md')
  })

  test('a line that is not a call is traced too, because that is the confusing case', async () => {
    expect((await traced('not json at all'))[0]).toContain('refused')
    expect((await traced(JSON.stringify({ request: { kind: 'check-sandbox' } })))[0]).toContain(
      'no id',
    )
  })

  test('a wait that succeeds writes nothing, or an idle varnick would fill the log', async () => {
    // Each of these is re-asked for the life of the process. See UNTRACED_KINDS.
    for (const kind of UNTRACED_KINDS) expect(worthTracing(kind)).toBe(false)
    expect(worthTracing('merge-worktree')).toBe(true)
  })

  test('a wait that FAILS is still traced', async () => {
    // The filter is about noise, not about hiding failures — a poll that fails
    // is precisely the thing nobody would otherwise see.
    const [line] = await traced(
      call(1, { kind: 'read-session', sessionId: 's' }),
      capabilities({
        readSession: async () => {
          throw new Error('the mirror would not open')
        },
      }),
    )
    expect(line).toContain('failed')
  })

  test('nothing from the request body ever reaches the line', async () => {
    /*
      The rule this whole thing lives under. These calls carry a pasted
      credential, a minted token, a developer's prompt and their pasted images.
      A trace that logged requests would put every one of those into a file the
      developer's terminal is writing — which is the thing the product is
      arranged to prevent.

      Only `kind` is read, and it is a closed vocabulary this codebase writes.
    */
    const secret = 'sk-ant-notarealkey-0123456789'
    const lines = await traced(
      call(1, { kind: 'store-credential', value: secret, secret, prompt: secret }),
    )
    for (const line of lines) expect(line).not.toContain(secret)
  })

  test('a kind that is not a string cannot smuggle one in either', () => {
    // The trace must never fail, so a request that is not one still produces a
    // line — and what it prints is a literal, not whatever arrived.
    expect(traceLine('<no kind>', 'refused', 0)).toContain('<no kind>')
    // Bounded, because a kind is untrusted by the time it reaches here.
    expect(traceLine('k'.repeat(500), 'ok', 1).length).toBeLessThan(200)
  })
})
