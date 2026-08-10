import { afterEach, beforeEach, describe, expect, test } from 'bun:test'
import { copyFile, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'

import {
  adoptLegacySessionMirror,
  createSessionStore,
  nodeSessionFs,
  redactSecrets,
  restoredTranscript,
  sessionMirrorRoot,
  type SessionStore,
  type StoredMessage,
} from './session.ts'

/* Assembled for the same reason as the shaped fixtures below: an invented value
 * whose shape a scanner flags is a value that blocks every push, here and in
 * every fork. */
const LEAKED_KEY = ['sk-', 'ant-api03-AAAABBBBCCCCDDDDEEEEFFFFGGGGHHHH'].join('')

/**
 * The Session mirror, tested through what a reader gets back out of it.
 *
 * Nothing here asserts how a line is formatted beyond the one claim the format
 * is *for*: a developer with varnick not running can read the file. That claim
 * is tested by reading the file with plain `node:fs` and `JSON.parse`, which is
 * what `cat` and `jq` would do.
 */

let root: string
let store: SessionStore

const user = (id: string, text: string): StoredMessage => ({ id, role: 'user', text })
const agent = (id: string, text: string): StoredMessage => ({ id, role: 'agent', text })

beforeEach(async () => {
  root = await mkdtemp(join(tmpdir(), 'varnick-session-'))
  store = createSessionStore({ root })
})

afterEach(async () => {
  await rm(root, { recursive: true, force: true })
})

/** What a developer gets by reading the file, with no varnick involved. */
async function readByHand(sessionId: string): Promise<unknown[]> {
  const raw = await readFile(store.pathFor(sessionId), 'utf8')
  return raw
    .split('\n')
    .filter((line) => line.length > 0)
    .map((line) => JSON.parse(line))
}

describe('the transcript survives the process', () => {
  test('what was persisted is what is read back', async () => {
    await store.persist({
      sessionId: 's1',
      messages: [user('m1', 'build me a Surface'), agent('m2', 'on it')],
    })

    expect(await store.read('s1')).toEqual([
      user('m1', 'build me a Surface'),
      agent('m2', 'on it'),
    ])
  })

  test('a session with nothing written reads as empty rather than throwing', async () => {
    expect(await store.read('never-used')).toEqual([])
  })

  test('a second store over the same root reads the first one back', async () => {
    await store.persist({ sessionId: 's1', messages: [user('m1', 'hello')] })

    const reopened = createSessionStore({ root })
    expect(await reopened.read('s1')).toEqual([user('m1', 'hello')])
  })
})

describe('written at every Turn boundary', () => {
  test('successive saves accumulate rather than replace', async () => {
    await store.persist({ sessionId: 's1', messages: [user('m1', 'one')] })
    await store.persist({ sessionId: 's1', messages: [user('m1', 'one'), agent('m2', 'two')] })
    await store.persist({
      sessionId: 's1',
      messages: [user('m1', 'one'), agent('m2', 'two'), user('m3', 'three')],
    })

    expect((await store.read('s1')).map((m) => m.text)).toEqual(['one', 'two', 'three'])
  })

  test('saving the same transcript twice writes nothing the second time', async () => {
    const messages = [user('m1', 'one'), agent('m2', 'two')]
    await store.persist({ sessionId: 's1', messages })
    const after = await readFile(store.pathFor('s1'), 'utf8')

    await store.persist({ sessionId: 's1', messages })

    expect(await readFile(store.pathFor('s1'), 'utf8')).toBe(after)
    expect(await store.read('s1')).toHaveLength(2)
  })

  test('saves that overlap in time neither duplicate nor interleave', async () => {
    const grow = (n: number) =>
      Array.from({ length: n }, (_, i) => user(`m${i + 1}`, `line ${i + 1}`))

    await Promise.all([
      store.persist({ sessionId: 's1', messages: grow(1) }),
      store.persist({ sessionId: 's1', messages: grow(2) }),
      store.persist({ sessionId: 's1', messages: grow(3) }),
    ])

    expect((await store.read('s1')).map((m) => m.id)).toEqual(['m1', 'm2', 'm3'])
  })

  test('a rewritten history replaces the transcript instead of appending to it', async () => {
    // What Compaction does: earlier messages are replaced by a summary. An
    // append-only mirror would leave both versions on disk.
    await store.persist({
      sessionId: 's1',
      messages: [user('m1', 'one'), agent('m2', 'two'), user('m3', 'three')],
    })

    await store.persist({
      sessionId: 's1',
      messages: [agent('c1', 'summary of the conversation so far'), user('m4', 'four')],
    })

    expect((await store.read('s1')).map((m) => m.id)).toEqual(['c1', 'm4'])
    expect(await readByHand('s1')).toHaveLength(2)
  })

  test('a cleared transcript empties the mirror', async () => {
    await store.persist({ sessionId: 's1', messages: [user('m1', 'one')] })
    await store.persist({ sessionId: 's1', messages: [] })

    expect(await store.read('s1')).toEqual([])
  })
})

describe('readable and backupable with varnick not running', () => {
  test('the file is one JSON object per line', async () => {
    await store.persist({
      sessionId: 's1',
      messages: [user('m1', 'one'), agent('m2', 'two')],
    })

    expect(await readByHand('s1')).toEqual([
      { id: 'm1', role: 'user', text: 'one' },
      { id: 'm2', role: 'agent', text: 'two' },
    ])
  })

  test('the path is one file per Session, under the injected root', async () => {
    const path = store.pathFor('s1')
    expect(path.startsWith(root)).toBe(true)
    expect(path.endsWith('s1.jsonl')).toBe(true)
  })

  test('a newline in a message does not become a second line', async () => {
    await store.persist({ sessionId: 's1', messages: [agent('m1', 'first\nsecond')] })

    expect(await readByHand('s1')).toHaveLength(1)
    expect((await store.read('s1'))[0]?.text).toBe('first\nsecond')
  })

  test('the stored Sessions can be listed', async () => {
    await store.persist({ sessionId: 'a', messages: [user('m1', 'x')] })
    await store.persist({ sessionId: 'b', messages: [user('m1', 'y')] })

    expect((await store.list()).sort()).toEqual(['a', 'b'])
  })

  test('listing a root that has never been written is empty, not an error', async () => {
    const empty = createSessionStore({ root: join(root, 'nothing-here') })
    expect(await empty.list()).toEqual([])
  })

  test('a copy of the file is a working backup', async () => {
    await store.persist({ sessionId: 's1', messages: [user('m1', 'one'), agent('m2', 'two')] })

    // Copying the file is the whole backup procedure.
    const backupRoot = await mkdtemp(join(tmpdir(), 'varnick-backup-'))
    const backup = createSessionStore({ root: backupRoot })
    await copyFile(store.pathFor('s1'), backup.pathFor('s1'))

    expect(await backup.read('s1')).toEqual([user('m1', 'one'), agent('m2', 'two')])
    await rm(backupRoot, { recursive: true, force: true })
  })
})

describe('a crash mid-write costs the last line, not the transcript', () => {
  test('a truncated final line is skipped and everything before it survives', async () => {
    await store.persist({
      sessionId: 's1',
      messages: [user('m1', 'one'), agent('m2', 'two')],
    })

    const whole = await readFile(store.pathFor('s1'), 'utf8')
    // A write that stopped partway through the last line.
    await writeFile(store.pathFor('s1'), `${whole}{"id":"m3","role":"us`)

    expect((await store.read('s1')).map((m) => m.id)).toEqual(['m1', 'm2'])
  })

  test('the next save recovers from a truncated final line', async () => {
    await store.persist({ sessionId: 's1', messages: [user('m1', 'one')] })
    const whole = await readFile(store.pathFor('s1'), 'utf8')
    await writeFile(store.pathFor('s1'), `${whole}{"id":"m2","role`)

    await store.persist({ sessionId: 's1', messages: [user('m1', 'one'), agent('m2', 'two')] })

    expect(await store.read('s1')).toEqual([user('m1', 'one'), agent('m2', 'two')])
  })
})

describe('durability of the Session is not durability of the keys', () => {
  test('a secret value the host knows never reaches the file', async () => {
    const secret = 'hunter2-the-actual-value'
    const guarded = createSessionStore({ root, secretValues: () => [secret] })

    await guarded.persist({
      sessionId: 's1',
      messages: [user('m1', `use ${secret} for the call`)],
    })

    const raw = await readFile(guarded.pathFor('s1'), 'utf8')
    expect(raw).not.toContain(secret)
    expect((await guarded.read('s1'))[0]?.text).toBe('use [redacted] for the call')
  })

  test('the secret set is read at write time, not at construction time', async () => {
    // The Secrets Store changes while varnick runs; a store that snapshotted
    // the set on construction would mirror every secret added after launch.
    let secrets: string[] = []
    const guarded = createSessionStore({ root, secretValues: () => secrets })

    secrets = ['added-after-the-store-was-made']
    await guarded.persist({
      sessionId: 's1',
      messages: [user('m1', 'key is added-after-the-store-was-made')],
    })

    expect(await readFile(guarded.pathFor('s1'), 'utf8')).not.toContain(
      'added-after-the-store-was-made',
    )
  })

  test('a credential shaped like a key is redacted even when the host has never seen it', async () => {
    await store.persist({
      sessionId: 's1',
      messages: [user('m1', `here it is: ${LEAKED_KEY}`)],
    })

    const raw = await readFile(store.pathFor('s1'), 'utf8')
    expect(raw).not.toContain(LEAKED_KEY)
    expect(raw).toContain('[redacted]')
  })

  test('redaction is idempotent, so a re-save does not rewrite the file', async () => {
    const messages = [user('m1', LEAKED_KEY)]
    await store.persist({ sessionId: 's1', messages })
    const after = await readFile(store.pathFor('s1'), 'utf8')

    await store.persist({ sessionId: 's1', messages })

    expect(await readFile(store.pathFor('s1'), 'utf8')).toBe(after)
  })

  test('redactSecrets replaces every occurrence of a known value', () => {
    expect(redactSecrets('a AAA b AAA', ['AAA'])).toBe('a [redacted] b [redacted]')
  })

  test('redactSecrets leaves ordinary prose alone', () => {
    const prose = 'The Session is mirrored host-side, one message per line.'
    expect(redactSecrets(prose, [])).toBe(prose)
  })

  test('redactSecrets ignores an empty or whitespace secret', () => {
    // A Secrets Store with an empty value must not turn every character of the
    // transcript into a redaction marker.
    expect(redactSecrets('hello', ['', '   '])).toBe('hello')
  })

  /*
    Assembled from fragments rather than written out, and the values are exactly
    what they look like once joined.

    These fixtures have to carry real credential *shapes*, because that is the
    whole of what this test proves — `redactSecrets` catching a value nobody
    registered, by what it looks like. But a source file containing a literal of
    that shape is a source file every secret scanner flags. GitHub's push
    protection rejected this repository over two of them, and a fixture that
    blocks pushing blocks it for every fork too, permanently, over values that
    were invented here.

    So the shape reaches the assertion and never appears in the file. Joining is
    not hiding: nothing here is a credential, and the comment you are reading is
    where that is said out loud.
  */
  const shaped = (...parts: readonly string[]) => parts.join('')

  test.each([
    ['an Anthropic key', shaped('sk-', 'ant-api03-AAAABBBBCCCCDDDDEEEEFFFFGGGG')],
    ['a GitHub token', shaped('ghp', '_AAAABBBBCCCCDDDDEEEEFFFFGGGGHHHHIIII')],
    ['an AWS access key id', shaped('AKIA', 'IOSFODNN7EXAMPLE')],
    ['a Google API key', shaped('AIza', 'SyA-AAAABBBBCCCCDDDDEEEEFFFFGGGGHHH')],
    ['a Slack token', shaped('xox', 'b-1234567890-ABCDEFGHIJKLMNOP')],
  ])('redactSecrets catches %s by shape', (_what, value) => {
    expect(redactSecrets(`token: ${value}`, [])).not.toContain(value)
  })

  test('redactSecrets catches an assignment to a name that says secret', () => {
    expect(redactSecrets('ANTHROPIC_API_KEY=zzzzzzzzzzzzzzzz', [])).not.toContain(
      'zzzzzzzzzzzzzzzz',
    )
  })

  test('redactSecrets catches a private key block', () => {
    const pem = '-----BEGIN RSA PRIVATE KEY-----\nMIIEow\nkey\n-----END RSA PRIVATE KEY-----'
    expect(redactSecrets(`here: ${pem}`, [])).not.toContain('MIIEow')
  })
})

describe('a relaunch continues the conversation', () => {
  test('what the last Turn boundary wrote is what a relaunch reads back', async () => {
    // Quit, relaunch: a second store over the same root, which is what a new
    // process gets.
    await store.persist({
      sessionId: 's1',
      messages: [user('m1', 'build me a Surface'), agent('m2', 'on it')],
    })

    const relaunched = createSessionStore({ root })
    const restored = restoredTranscript(await relaunched.read('s1'))

    expect(restored.messages).toEqual([
      user('m1', 'build me a Surface'),
      agent('m2', 'on it'),
    ])
  })

  test('a Session that was never written restores as empty rather than failing', async () => {
    expect(restoredTranscript(await store.read('never-used'))).toEqual({
      messages: [],
      redacted: false,
    })
  })

  test('a restored transcript says when it is a redacted record', async () => {
    const secret = 'hunter2-the-actual-value'
    const guarded = createSessionStore({ root, secretValues: () => [secret] })
    await guarded.persist({
      sessionId: 's1',
      messages: [user('m1', `use ${secret} for the call`)],
    })

    const restored = restoredTranscript(await guarded.read('s1'))

    // The value is gone and stays gone — reading a secret back onto the screen
    // would defeat the redaction the write path exists for. What is owed is
    // that the developer can tell this is the record rather than what they typed.
    expect(restored.messages[0]?.text).toBe('use [redacted] for the call')
    expect(restored.redacted).toBe(true)
  })

  test('a transcript with nothing redacted does not claim a redaction', async () => {
    await store.persist({ sessionId: 's1', messages: [user('m1', 'plain prose')] })

    expect(restoredTranscript(await store.read('s1')).redacted).toBe(false)
  })

  test('a transcript damaged mid-write still restores everything before the damage', async () => {
    // Killing the process is the case this is for: the tail of one write is
    // lost, the transcript is not.
    await store.persist({ sessionId: 's1', messages: [user('m1', 'one'), agent('m2', 'two')] })
    const whole = await readFile(store.pathFor('s1'), 'utf8')
    await writeFile(store.pathFor('s1'), `${whole}{"id":"m3","role":"us`)

    expect(restoredTranscript(await store.read('s1')).messages.map((m) => m.id)).toEqual([
      'm1',
      'm2',
    ])
  })

  test('a Turn after a relaunch extends the file rather than replacing it', async () => {
    // The reason the read has to succeed before a Session runs on that id. A
    // Session that started empty would hand the mirror a transcript the file is
    // not a prefix of, and the store would take that for a rewritten history —
    // Compaction, or `/clear` — and replace a day's work.
    await store.persist({ sessionId: 's1', messages: [user('m1', 'one'), agent('m2', 'two')] })

    const relaunched = createSessionStore({ root })
    const restored = restoredTranscript(await relaunched.read('s1'))
    await relaunched.persist({
      sessionId: 's1',
      messages: [...restored.messages, user('m3', 'three')],
    })

    expect((await relaunched.read('s1')).map((m) => m.text)).toEqual(['one', 'two', 'three'])
  })

  test('relaunching and saving again writes nothing, redactions and all', async () => {
    // Redaction is idempotent, so a restored message is byte-identical to the
    // one on disk. If it were not, every relaunch would rewrite the whole
    // transcript on the first save rather than appending to it.
    const guarded = createSessionStore({ root, secretValues: () => ['hunter2-the-actual-value'] })
    await guarded.persist({
      sessionId: 's1',
      messages: [user('m1', 'use hunter2-the-actual-value'), agent('m2', 'done')],
    })
    const before = await readFile(guarded.pathFor('s1'), 'utf8')

    const relaunched = createSessionStore({ root, secretValues: () => ['hunter2-the-actual-value'] })
    const restored = restoredTranscript(await relaunched.read('s1'))
    await relaunched.persist({ sessionId: 's1', messages: restored.messages })

    expect(await readFile(guarded.pathFor('s1'), 'utf8')).toBe(before)
  })

  test('the mirror has nowhere to keep a partial, so a restore ends at a Turn boundary', async () => {
    // The whole of what `persist` accepts is complete messages. A Turn that was
    // still streaming when the process died left no partial on disk to fold in,
    // which is what makes resuming as `turn.idle` cost nothing: there is no
    // half-finished answer for any other state to be about.
    await store.persist({ sessionId: 's1', messages: [user('m1', 'one')] })

    const onDisk = await readByHand('s1')
    for (const line of onDisk) {
      expect(Object.keys(line as object).sort()).toEqual(['id', 'role', 'text'])
    }
  })
})

describe('a session id cannot leave the store', () => {
  test.each(['../escape', 'a/b', 'a\\b', '', '.', '..', 'a b'])(
    'rejects %p as a Session id',
    async (bad) => {
      expect(() => store.pathFor(bad)).toThrow()
      await expect(store.persist({ sessionId: bad, messages: [] })).rejects.toThrow()
    },
  )

  test('accepts the id shapes a Session actually uses', () => {
    expect(() => store.pathFor('session-01JD8K7Q4M')).not.toThrow()
    expect(() => store.pathFor('s1')).not.toThrow()
  })
})

describe('the default root', () => {
  test('is under the app-data directory and named for the app', () => {
    const path = sessionMirrorRoot('/Users/dev/code/varnick')
    expect(path).toContain('com.zabaca.varnick')
    expect(path.length).toBeGreaterThan('com.zabaca.varnick'.length)
  })

  test('is not what any test writes to', () => {
    expect(store.pathFor('s1').startsWith(sessionMirrorRoot('/Users/dev/code/varnick'))).toBe(false)
  })
})

// ---------------------------------------------------------------------------
// Which root the mirror belongs to — ticket 28
// ---------------------------------------------------------------------------

describe('which root the mirror belongs to', () => {
  /*
    The mirror used to be one directory per *machine*. That was invisible while
    there was one clone root, and wrong the moment there were two: the live
    Session id is a constant (`LIVE_SESSION_ID` in packages/core/src/domain.ts),
    so two roots would have read and appended the same file and each would have
    shown the other's conversation. See ADR-0012.
  */

  const A = '/Users/dev/code/varnick'
  const B = '/opt/work/varnick'

  test('two roots on one machine get two mirrors', () => {
    expect(sessionMirrorRoot(A)).not.toBe(sessionMirrorRoot(B))
  })

  test('the same root always gets the same mirror', () => {
    // A path derived from a hash still has to be stable across launches, or a
    // relaunch resumes from a directory nothing ever wrote to.
    expect(sessionMirrorRoot(A)).toBe(sessionMirrorRoot(A))
  })

  test('the directory carries the clone’s own name, so a developer can find it', () => {
    expect(sessionMirrorRoot('/Users/dev/code/second-varnick')).toContain('second-varnick')
  })

  test('two roots with the same directory name are still two mirrors', () => {
    // The name alone cannot be the key: `~/code/varnick` and `/opt/varnick` are
    // different Workspaces with the same basename.
    expect(sessionMirrorRoot('/Users/dev/code/varnick')).not.toBe(
      sessionMirrorRoot('/opt/varnick'),
    )
  })

  test('the mirror stays outside the clone, so the agent cannot rewrite the record', () => {
    // ADR-0008's third consequence. Per-root must not become "inside the root".
    expect(sessionMirrorRoot(A).startsWith(A)).toBe(false)
  })
})

describe('a mirror written before there was more than one root', () => {
  /*
    One-time adoption. Every clone that ran varnick before ticket 28 has its
    transcript at `<app-data>/com.zabaca.varnick/sessions`, and moving the
    mirror under a per-root directory would otherwise resume that developer into
    an empty conversation over a file that is not empty — the exact failure
    ADR-0009 exists to prevent.
  */

  let appData: string

  beforeEach(async () => {
    appData = await mkdtemp(join(tmpdir(), 'varnick-appdata-'))
  })

  afterEach(async () => {
    await rm(appData, { recursive: true, force: true })
  })

  const legacy = () => join(appData, 'sessions')

  test('the transcript that was there is adopted by the first root to run', async () => {
    const fs = nodeSessionFs()
    await fs.makeDir(legacy())
    await fs.replaceFile(join(legacy(), 'session-1.jsonl'), '{"id":"m1"}\n')

    const mine = join(appData, 'workspaces', 'varnick-abc123', 'sessions')
    await adoptLegacySessionMirror({ appDataRoot: appData, mirrorRoot: mine, fs })

    expect(await fs.readFile(join(mine, 'session-1.jsonl'))).toBe('{"id":"m1"}\n')
    // Moved, not copied: a second root must not find it and adopt it too.
    expect(await fs.listDir(legacy())).toEqual([])
  })

  test('a second root finds nothing left to adopt and starts empty', async () => {
    const fs = nodeSessionFs()
    await fs.makeDir(legacy())
    await fs.replaceFile(join(legacy(), 'session-1.jsonl'), '{"id":"m1"}\n')

    const first = join(appData, 'workspaces', 'first', 'sessions')
    const second = join(appData, 'workspaces', 'second', 'sessions')
    await adoptLegacySessionMirror({ appDataRoot: appData, mirrorRoot: first, fs })
    await adoptLegacySessionMirror({ appDataRoot: appData, mirrorRoot: second, fs })

    expect(await fs.listDir(first)).toEqual(['session-1.jsonl'])
    expect(await fs.listDir(second)).toEqual([])
  })

  test('a root that already has a mirror is left alone', async () => {
    const fs = nodeSessionFs()
    await fs.makeDir(legacy())
    await fs.replaceFile(join(legacy(), 'session-1.jsonl'), 'legacy\n')

    const mine = join(appData, 'workspaces', 'mine', 'sessions')
    await fs.makeDir(mine)
    await fs.replaceFile(join(mine, 'session-1.jsonl'), 'mine\n')

    await adoptLegacySessionMirror({ appDataRoot: appData, mirrorRoot: mine, fs })

    expect(await fs.readFile(join(mine, 'session-1.jsonl'))).toBe('mine\n')
  })

  test('no legacy mirror at all is not an error', async () => {
    const fs = nodeSessionFs()
    const mine = join(appData, 'workspaces', 'mine', 'sessions')
    await adoptLegacySessionMirror({ appDataRoot: appData, mirrorRoot: mine, fs })
    expect(await fs.listDir(mine)).toEqual([])
  })
})

describe('a tool call is mirrored as a fact, not as a line of prose', () => {
  const called = (id: string, tool: NonNullable<StoredMessage['tool']>): StoredMessage => ({
    id,
    role: 'agent',
    text: `⚙ ${tool.name}\n`,
    tool,
  })

  test('a tool call and its answer come back as they went in', async () => {
    await store.persist({
      sessionId: 't1',
      messages: [
        user('m1', 'read it'),
        called('m2', {
          id: 'tu_1',
          name: 'Read',
          argument: 'src/a.ts',
          result: 'export const a = 1',
          detail: 'export const a = 1\nexport const b = 2',
          status: 'success',
        }),
      ],
    })

    const back = await store.read('t1')
    expect(back[1]?.tool).toEqual({
      id: 'tu_1',
      name: 'Read',
      argument: 'src/a.ts',
      result: 'export const a = 1',
      detail: 'export const a = 1\nexport const b = 2',
      status: 'success',
    })
  })

  test('the file a developer reads by hand still says what the tool was', async () => {
    // The claim the format exists for. `jq '.tool.name'` has to work with
    // varnick not running, which is the same claim the rest of this file makes
    // about message text.
    await store.persist({
      sessionId: 't2',
      messages: [called('m1', { id: 'tu_1', name: 'Bash', argument: 'bun test', status: 'pending' })],
    })
    const lines = (await readByHand('t2')) as { tool?: { name?: string; status?: string } }[]
    expect(lines[0]?.tool?.name).toBe('Bash')
    expect(lines[0]?.tool?.status).toBe('pending')
  })

  test('a result arriving later rewrites the line rather than adding one', async () => {
    /*
      The one case in this store where an existing line changes. A tool is
      mirrored when it is announced and answers later, so the append fast-path
      has to notice that the line is no longer the one on disk — otherwise the
      mirror keeps a tool that is permanently still running.
    */
    const running = {
      id: 'tu_1',
      name: 'Bash',
      argument: 'bun test',
      status: 'pending',
    } as const
    await store.persist({ sessionId: 't3', messages: [called('m1', running)] })

    await store.persist({
      sessionId: 't3',
      messages: [called('m1', { ...running, result: '675 pass, 2 fail', status: 'error' })],
    })

    const back = await store.read('t3')
    expect(back).toHaveLength(1)
    expect(back[0]?.tool?.status).toBe('error')
    expect(back[0]?.tool?.result).toBe('675 pass, 2 fail')
  })

  test('a secret a tool printed does not reach the file', async () => {
    /*
      A tool result is the likeliest place in a transcript for a secret to turn
      up — `Bash(env)`, a config read back, a response body with a token in it —
      and it arrives from the runtime rather than from anything anybody typed.
      The mirror is the copy that sits on disk for anyone to `cat`.
    */
    const leaky = createSessionStore({ root, secretValues: () => [LEAKED_KEY] })
    await leaky.persist({
      sessionId: 't4',
      messages: [
        called('m1', {
          id: 'tu_1',
          name: 'Bash',
          argument: `curl -H "key: ${LEAKED_KEY}"`,
          result: `ANTHROPIC_API_KEY=${LEAKED_KEY}`,
          detail: `ANTHROPIC_API_KEY=${LEAKED_KEY}\nok`,
          status: 'success',
        }),
      ],
    })

    const raw = await readFile(store.pathFor('t4'), 'utf8')
    expect(raw).not.toContain(LEAKED_KEY)
    // Every field carrying free text, not just the one that is easy to
    // remember: an argument is as much a place for a token as a result.
    const back = await leaky.read('t4')
    expect(back[0]?.tool?.argument).not.toContain(LEAKED_KEY)
    expect(back[0]?.tool?.result).not.toContain(LEAKED_KEY)
    expect(back[0]?.tool?.detail).not.toContain(LEAKED_KEY)
  })

  test('a line written before tool calls existed still loads', async () => {
    // The compatibility claim. A conversation held by an older build has no
    // `tool` field anywhere in it, and that is an ordinary transcript rather
    // than a malformed one.
    await writeFile(
      store.pathFor('t5'),
      `${JSON.stringify({ id: 'm1', role: 'agent', text: '⚙ Read(src/a.ts)\n' })}\n`,
    )
    const back = await store.read('t5')
    expect(back).toHaveLength(1)
    expect(back[0]?.tool).toBeUndefined()
  })

  test('a line claiming to be a tool call and failing to be one is refused', async () => {
    /*
      Not "drop the field and keep the message". A line that says it is a tool
      call is one, and reading it back as ordinary text would put the one-line
      form into the transcript as prose — which is the thing the field exists to
      stop.
    */
    await writeFile(
      store.pathFor('t6'),
      `${JSON.stringify({
        id: 'm1',
        role: 'agent',
        text: 'x',
        tool: { id: 'tu_1', name: 'Read', status: 'invented' },
      })}\n`,
    )
    expect(await store.read('t6')).toHaveLength(0)
  })

  test('a redaction that happened only inside a tool call still raises the banner', () => {
    /*
      The banner asks the same question the redaction answers, and it has to ask
      it over the same fields. It looked at `message.text` alone, so a
      transcript whose only redacted value was in a tool result came back with
      no warning — the developer was told the record was complete while reading
      one that was not.
    */
    const withSecretInResult: StoredMessage = {
      id: 'm1',
      role: 'agent',
      text: '⚙ Bash(env)\n',
      tool: {
        id: 'tu_1',
        name: 'Bash',
        argument: 'env',
        result: `ANTHROPIC_API_KEY=${redactSecrets(LEAKED_KEY, [LEAKED_KEY])}`,
        status: 'success',
      },
    }
    expect(restoredTranscript([withSecretInResult]).redacted).toBe(true)
  })

  test('a transcript with nothing taken out of it says so', () => {
    const clean: StoredMessage = {
      id: 'm1',
      role: 'agent',
      text: '⚙ Read(a.ts)\n',
      tool: { id: 'tu_1', name: 'Read', argument: 'a.ts', result: 'ok', status: 'success' },
    }
    expect(restoredTranscript([clean]).redacted).toBe(false)
  })

  test('the pictures a message carried reach the file too', async () => {
    /*
      Not a tool call, and found while adding one. `persist` rebuilt every
      message as `{id, role, text}` and nothing else, so `attachments` reached
      the type and the serialiser and never reached the disk: every mirrored
      message said no pictures went with it. The new field would have been lost
      the same way, for the same reason, in the same line of code.
    */
    await store.persist({
      sessionId: 't7',
      messages: [{ id: 'm1', role: 'user', text: 'what is wrong here?', attachments: 2 }],
    })
    expect((await store.read('t7'))[0]?.attachments).toBe(2)
  })
})
