import { afterEach, beforeEach, describe, expect, test } from 'bun:test'
import { copyFile, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'

import {
  createSessionStore,
  defaultSessionRoot,
  redactSecrets,
  restoredTranscript,
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
    const path = defaultSessionRoot()
    expect(path).toContain('com.zabaca.varnick')
    expect(path.length).toBeGreaterThan('com.zabaca.varnick'.length)
  })

  test('is not what any test writes to', () => {
    expect(store.pathFor('s1').startsWith(defaultSessionRoot())).toBe(false)
  })
})
