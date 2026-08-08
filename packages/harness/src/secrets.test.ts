import { afterAll, describe, expect, test } from 'bun:test'
import { mkdtempSync, readdirSync, readFileSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { createSessionStore } from './session.ts'
import {
  describeSecretsForAgent,
  openSecretsStore,
  secretNameProblem,
  SECRETS_INDEX_ACCOUNT,
  type SecretsKeychain,
} from './secrets.ts'

/**
 * The seam: the exported surface of the Secrets Store, and nothing below it.
 *
 * No test here reads or writes the real system keychain, and it cannot by
 * construction — `openSecretsStore` has no default keychain, so every test has
 * to hand it one. That is the same bar ticket 02 set, moved one step further:
 * there is no argument to forget.
 *
 * A store is tested by what a reader can and cannot get out of it, so most of
 * what is below is a refusal.
 */

/** A keychain in a Map. `failOn` makes one account's write or delete refuse. */
function fakeKeychain(
  seed: Record<string, string> = {},
  failOn?: { write?: string; remove?: string; read?: string },
): SecretsKeychain & { items: Map<string, string> } {
  const items = new Map(Object.entries(seed))
  return {
    items,
    async read(account) {
      if (failOn?.read === account) throw new Error('the keychain would not answer')
      return items.get(account) ?? null
    },
    async write(account, value) {
      if (failOn?.write === account) throw new Error('the keychain would not answer')
      items.set(account, value)
    },
    async remove(account) {
      if (failOn?.remove === account) throw new Error('the keychain would not answer')
      items.delete(account)
    },
  }
}

/** Values shaped like real keys, used to prove they never come back out. */
const STRIPE = 'sk_test_51NEVERLETTHISOUT0000000000'
const OPENAI = 'sk-" + "ant-api03-ALSO-NEVER-LET-THIS-OUT'

const index = (names: readonly string[]) => JSON.stringify(names)

describe('a name is checked before anything is stored under it', () => {
  test('a name the agent could write as process.env.NAME is fine', () => {
    for (const name of ['STRIPE_KEY', '_private', 'a1', 'X'])
      expect(secretNameProblem(name)).toBeNull()
  })

  test('an empty name is not a name', () => {
    expect(secretNameProblem('')).not.toBeNull()
    expect(secretNameProblem('   ')).not.toBeNull()
  })

  test('a name that is not an identifier is refused, so generated code compiles', () => {
    for (const name of ['1KEY', 'MY-KEY', 'MY KEY', 'MY.KEY', 'MY/KEY'])
      expect(secretNameProblem(name)).not.toBeNull()
  })

  test('a name carrying a colon cannot address another keychain account', () => {
    expect(secretNameProblem('varnick.index')).not.toBeNull()
    expect(secretNameProblem('a:b')).not.toBeNull()
  })

  test('every problem says what to do about it', () => {
    for (const name of ['', '1KEY', 'MY-KEY'])
      expect(secretNameProblem(name)?.length ?? 0).toBeGreaterThan(20)
  })
})

describe('secrets are stored, listed, renamed and removed without a restart', () => {
  test('a fresh keychain is an empty store, not a failure', async () => {
    const store = await openSecretsStore({ keychain: fakeKeychain() })
    expect(store.names()).toEqual([])
  })

  test('a stored secret is listed by the same store instance, with no reopen', async () => {
    const store = await openSecretsStore({ keychain: fakeKeychain() })
    await store.store('STRIPE_KEY', STRIPE)
    expect(store.names()).toEqual(['STRIPE_KEY'])
    expect(store.has('STRIPE_KEY')).toBe(true)
  })

  test('a rename is visible immediately, and keeps the value', async () => {
    const keychain = fakeKeychain()
    const store = await openSecretsStore({ keychain })
    await store.store('STRIPE_KEY', STRIPE)
    await store.rename('STRIPE_KEY', 'PAYMENTS_KEY')
    expect(store.names()).toEqual(['PAYMENTS_KEY'])
    expect([...store.secretValues()]).toEqual([STRIPE])
    expect(keychain.items.has('STRIPE_KEY')).toBe(false)
  })

  test('a removal is visible immediately, and takes the item with it', async () => {
    const keychain = fakeKeychain()
    const store = await openSecretsStore({ keychain })
    await store.store('STRIPE_KEY', STRIPE)
    await store.remove('STRIPE_KEY')
    expect(store.names()).toEqual([])
    expect([...store.secretValues()]).toEqual([])
    expect(keychain.items.has('STRIPE_KEY')).toBe(false)
  })

  test('storing over a name replaces the value and does not list it twice', async () => {
    const store = await openSecretsStore({ keychain: fakeKeychain() })
    await store.store('STRIPE_KEY', STRIPE)
    await store.store('STRIPE_KEY', OPENAI)
    expect(store.names()).toEqual(['STRIPE_KEY'])
    expect([...store.secretValues()]).toEqual([OPENAI])
  })

  test('order is the order they were added, and a rename holds its place', async () => {
    const store = await openSecretsStore({ keychain: fakeKeychain() })
    await store.store('FIRST', 'one-value-here')
    await store.store('SECOND', 'two-value-here')
    await store.rename('FIRST', 'RENAMED')
    expect(store.names()).toEqual(['RENAMED', 'SECOND'])
  })

  test('another process wrote the keychain — reload sees it, no restart', async () => {
    const keychain = fakeKeychain()
    const store = await openSecretsStore({ keychain })
    // What the CLI in another process would have left behind.
    await keychain.write('STRIPE_KEY', STRIPE)
    await keychain.write(SECRETS_INDEX_ACCOUNT, index(['STRIPE_KEY']))
    expect(store.names()).toEqual([])
    await store.reload()
    expect(store.names()).toEqual(['STRIPE_KEY'])
  })

  test('what one store wrote, the next store opened over it reads', async () => {
    const keychain = fakeKeychain()
    const first = await openSecretsStore({ keychain })
    await first.store('STRIPE_KEY', STRIPE)
    const second = await openSecretsStore({ keychain })
    expect(second.names()).toEqual(['STRIPE_KEY'])
  })
})

describe('the store refuses rather than corrupting', () => {
  test('an invalid name is refused, and nothing is written under it', async () => {
    const keychain = fakeKeychain()
    const store = await openSecretsStore({ keychain })
    await expect(store.store('MY-KEY', STRIPE)).rejects.toThrow()
    expect(keychain.items.size).toBe(0)
    expect(store.names()).toEqual([])
  })

  test('an empty value is a mistake, not a secret', async () => {
    const store = await openSecretsStore({ keychain: fakeKeychain() })
    await expect(store.store('STRIPE_KEY', '')).rejects.toThrow()
    await expect(store.store('STRIPE_KEY', '   ')).rejects.toThrow()
  })

  test('a value with surrounding whitespace is refused, never trimmed', async () => {
    // `security -w` prints a trailing newline it did not store, so a read has
    // to trim. Refusing here is what keeps that trim lossless.
    const store = await openSecretsStore({ keychain: fakeKeychain() })
    await expect(store.store('STRIPE_KEY', ` ${STRIPE}`)).rejects.toThrow()
    await expect(store.store('STRIPE_KEY', `${STRIPE}\n`)).rejects.toThrow()
  })

  test('a value security would hand back as hex is refused, not stored ambiguously', async () => {
    // `security find-generic-password -w` prints the value as hex the moment it
    // holds a byte outside printable ASCII, and there is no flag that says which
    // form you got. A store that accepted a tab would read it back as a hex
    // string and hand the agent's code the wrong bytes.
    const store = await openSecretsStore({ keychain: fakeKeychain() })
    await expect(store.store('K', 'has\ttab')).rejects.toThrow()
    await expect(store.store('K', 'line-one\nline-two')).rejects.toThrow()
    await expect(store.store('K', 'café-key-value')).rejects.toThrow()
    await expect(store.store('K', '-----BEGIN PRIVATE KEY-----\nMII\n-----END')).rejects.toThrow()
  })

  test('an ordinary key with punctuation and spacing inside it is fine', async () => {
    const store = await openSecretsStore({ keychain: fakeKeychain() })
    for (const value of ['sk-" + "ant-api03-a_b-c=', 'a{b}c[d]e(f)!@#$%^&*', 'two words here'])
      await store.store('K', value)
    expect(store.names()).toEqual(['K'])
  })

  test('renaming onto a name already in use is refused', async () => {
    const store = await openSecretsStore({ keychain: fakeKeychain() })
    await store.store('FIRST', 'one-value-here')
    await store.store('SECOND', 'two-value-here')
    await expect(store.rename('FIRST', 'SECOND')).rejects.toThrow()
    expect(store.names()).toEqual(['FIRST', 'SECOND'])
    expect([...store.secretValues()].sort()).toEqual(['one-value-here', 'two-value-here'])
  })

  test('renaming or removing a name that is not there is refused', async () => {
    const store = await openSecretsStore({ keychain: fakeKeychain() })
    await expect(store.rename('NOPE', 'ALSO_NOPE')).rejects.toThrow()
    await expect(store.remove('NOPE')).rejects.toThrow()
  })

  test('an index that is not a list of names is a loud failure, not an empty store', async () => {
    const keychain = fakeKeychain({ [SECRETS_INDEX_ACCOUNT]: '{ not a list' })
    await expect(openSecretsStore({ keychain })).rejects.toThrow()
  })

  test('a name whose item has gone is dropped rather than listed unresolvable', async () => {
    // Someone deleted the item with `security` by hand. A name with no value
    // would have the agent write code against a secret that cannot resolve.
    const keychain = fakeKeychain({
      [SECRETS_INDEX_ACCOUNT]: index(['STRIPE_KEY', 'GONE']),
      STRIPE_KEY: STRIPE,
    })
    const store = await openSecretsStore({ keychain })
    expect(store.names()).toEqual(['STRIPE_KEY'])
  })

  test('an index write that fails leaves no half-stored name', async () => {
    const keychain = fakeKeychain({}, { write: SECRETS_INDEX_ACCOUNT })
    const store = await openSecretsStore({ keychain })
    await expect(store.store('STRIPE_KEY', STRIPE)).rejects.toThrow()
    // The item may survive as an orphan — invisible, and harmless. What must
    // not happen is a listed name, because that is what the agent builds on.
    expect(store.names()).toEqual([])
    expect([...store.secretValues()]).toEqual([])
  })
})

describe('the agent is given names and never a value', () => {
  test('names() carries no value, whatever is stored', async () => {
    const store = await openSecretsStore({ keychain: fakeKeychain() })
    await store.store('STRIPE_KEY', STRIPE)
    await store.store('OPENAI_KEY', OPENAI)
    const serialised = JSON.stringify(store.names())
    expect(serialised).toContain('STRIPE_KEY')
    expect(serialised).not.toContain(STRIPE)
    expect(serialised).not.toContain(OPENAI)
  })

  test('the text the agent is handed lists names and quotes no value', async () => {
    const store = await openSecretsStore({ keychain: fakeKeychain() })
    await store.store('STRIPE_KEY', STRIPE)
    await store.store('OPENAI_KEY', OPENAI)
    const briefing = describeSecretsForAgent(store.names())
    expect(briefing).toContain('STRIPE_KEY')
    expect(briefing).toContain('OPENAI_KEY')
    expect(briefing).not.toContain(STRIPE)
    expect(briefing).not.toContain(OPENAI)
  })

  test('with nothing stored the briefing says so rather than going blank', () => {
    expect(describeSecretsForAgent([]).length).toBeGreaterThan(20)
  })

  test('the briefing says the values cannot be read, so the agent stops asking', () => {
    expect(describeSecretsForAgent(['STRIPE_KEY'])).toMatch(/cannot read|never see|no value/i)
  })

  test('secretValues is the only member that yields one, and it is named for it', async () => {
    const store = await openSecretsStore({ keychain: fakeKeychain() })
    await store.store('STRIPE_KEY', STRIPE)
    const yielded = Object.entries(store)
      .filter(([name]) => name !== 'secretValues')
      .map(([, member]) => (typeof member === 'function' ? member.call(store) : member))
    expect(JSON.stringify(yielded)).not.toContain(STRIPE)
  })

  test('a failure never quotes the value it was handed', async () => {
    const store = await openSecretsStore({ keychain: fakeKeychain() })
    const message = await store.store('MY-KEY', STRIPE).then(
      () => '',
      (error: unknown) => (error instanceof Error ? error.message : String(error)),
    )
    expect(message).not.toContain(STRIPE)
    expect(message).toContain('MY-KEY')
  })
})

describe('nothing a stored secret is worth reaches the Session mirror', () => {
  const roots: string[] = []
  const tempRoot = () => {
    const root = mkdtempSync(join(tmpdir(), 'varnick-secrets-mirror-'))
    roots.push(root)
    return root
  }

  afterAll(() => {
    for (const root of roots) rmSync(root, { recursive: true, force: true })
  })

  /** Every byte the mirror left on disk, the way `grep -r` would see it. */
  const everythingUnder = (root: string): string =>
    readdirSync(root)
      .map((name) => readFileSync(join(root, name), 'utf8'))
      .join('\n')

  test('a value put through a Session cannot be found in the file it wrote', async () => {
    const secrets = await openSecretsStore({ keychain: fakeKeychain() })
    await secrets.store('STRIPE_KEY', STRIPE)

    const root = tempRoot()
    const sessions = createSessionStore({ root, secretValues: () => secrets.secretValues() })

    await sessions.persist({
      sessionId: 'grep-probe',
      messages: [
        { id: 'm1', role: 'user', text: `use my stripe key ${STRIPE} for the checkout surface` },
        { id: 'm2', role: 'agent', text: `Wrote code that reads STRIPE_KEY. (${STRIPE})` },
      ],
    })

    const onDisk = everythingUnder(root)
    expect(onDisk.length).toBeGreaterThan(0)
    expect(onDisk).not.toContain(STRIPE)
    expect(onDisk).toContain('[redacted]')
    // The name survives — that is the half the agent is allowed to have.
    expect(onDisk).toContain('STRIPE_KEY')
  })

  test('a secret stored after the mirror was built is redacted too — no restart', async () => {
    const secrets = await openSecretsStore({ keychain: fakeKeychain() })
    const root = tempRoot()
    const sessions = createSessionStore({ root, secretValues: () => secrets.secretValues() })

    // The mirror exists first. The secret arrives while varnick is running.
    await secrets.store('LATE_KEY', OPENAI)
    await sessions.persist({
      sessionId: 'late-probe',
      messages: [{ id: 'm1', role: 'user', text: `the late one is ${OPENAI}` }],
    })

    expect(everythingUnder(root)).not.toContain(OPENAI)
  })

  test('a value with no recognisable shape is still redacted, because it is known', async () => {
    // The shape patterns cannot catch this one. The exact-value list can.
    const shapeless = 'hunter2-but-longer-and-quite-ordinary'
    const secrets = await openSecretsStore({ keychain: fakeKeychain() })
    await secrets.store('ODD_KEY', shapeless)

    const root = tempRoot()
    const sessions = createSessionStore({ root, secretValues: () => secrets.secretValues() })
    await sessions.persist({
      sessionId: 'shapeless-probe',
      messages: [{ id: 'm1', role: 'agent', text: `it is ${shapeless}, apparently` }],
    })

    expect(everythingUnder(root)).not.toContain(shapeless)
  })

  test('a removed secret stops being redacted, because it is no longer a secret', async () => {
    const secrets = await openSecretsStore({ keychain: fakeKeychain() })
    await secrets.store('GONE_KEY', 'formerly-a-secret-value')
    await secrets.remove('GONE_KEY')
    expect([...secrets.secretValues()]).toEqual([])
  })
})
