import { afterAll, describe, expect, test } from 'bun:test'
import { execFileSync } from 'node:child_process'
import { mkdtempSync, readdirSync, readFileSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { inspect } from 'node:util'
import { agentEnvironment } from './agent.ts'
import { createSessionStore } from './session.ts'
import { openSecretsStore, type SecretsKeychain, type SecretsStore } from './secrets.ts'
import { hostEnvOrRefuse, hostSecretResolution } from './secret-resolution.ts'

/**
 * The seam: what a resolution does to the environment, and for how long.
 *
 * Every test below is about one of two claims. The first is that
 * `process.env.NAME` works while the host runs Userspace code and at no other
 * moment. The second is that the value it yields is reachable *only* by naming
 * it — that no copy of the environment, no serialisation of it, no subprocess
 * spawned from it and no failure raised inside it carries the value anywhere the
 * agent could read it.
 *
 * The second claim is the one ADR-0006 rests on, so it is tested against the
 * real machinery rather than a stand-in: the real `process.env`, the real
 * `agentEnvironment` that builds the agent's environment, a real child process,
 * and a real Session mirror over a real temp filesystem.
 */

/** A keychain in a Map. No test here touches the system one. */
function fakeKeychain(): SecretsKeychain {
  const items = new Map<string, string>()
  return {
    async read(account) {
      return items.get(account) ?? null
    },
    async write(account, value) {
      items.set(account, value)
    },
    async remove(account) {
      items.delete(account)
    },
  }
}

/** Values shaped like real keys, so a leak is unmistakable in a grep. */
const STRIPE = 'sk_test_51RESOLVEDNEVERSEEN0000000'
const BILLING = 'tok_billing_NEVER_ENUMERABLE_9999'

const storeWith = async (entries: Record<string, string>): Promise<SecretsStore> => {
  const store = await openSecretsStore({ keychain: fakeKeychain() })
  for (const [name, value] of Object.entries(entries)) await store.store(name, value)
  return store
}

describe('a name resolves while the host runs Userspace code, and at no other moment', () => {
  test('process.env.NAME is the value inside the window and nothing outside it', async () => {
    const store = await storeWith({ STRIPE_KEY: STRIPE })
    const resolution = hostSecretResolution({ store })

    expect(process.env.STRIPE_KEY).toBeUndefined()
    const seen = await resolution.around(() => process.env.STRIPE_KEY)
    expect(seen).toBe(STRIPE)
    expect(process.env.STRIPE_KEY).toBeUndefined()
  })

  test('the window closes even when the module it was opened for throws', async () => {
    const store = await storeWith({ STRIPE_KEY: STRIPE })
    const resolution = hostSecretResolution({ store })

    await expect(
      resolution.around(() => {
        throw new Error('this module does not compile')
      }),
    ).rejects.toThrow('this module does not compile')
    expect(process.env.STRIPE_KEY).toBeUndefined()
  })

  test('a variable the host already had comes back exactly as it was', async () => {
    const store = await storeWith({ VARNICK_PROBE_REAL: 'the-secret-one' })
    const resolution = hostSecretResolution({ store })

    process.env.VARNICK_PROBE_REAL = 'the-developers-one'
    try {
      const seen = await resolution.around(() => process.env.VARNICK_PROBE_REAL)
      expect(seen).toBe('the-secret-one')
      expect(process.env.VARNICK_PROBE_REAL).toBe('the-developers-one')
    } finally {
      delete process.env.VARNICK_PROBE_REAL
    }
  })

  test('two modules loading at once share one window, and the last one out closes it', async () => {
    const store = await storeWith({ STRIPE_KEY: STRIPE })
    const resolution = hostSecretResolution({ store })

    let release = (): void => {}
    const held = new Promise<void>((resolve) => {
      release = resolve
    })

    const slow = resolution.around(async () => {
      await held
      return process.env.STRIPE_KEY
    })
    const quick = await resolution.around(() => process.env.STRIPE_KEY)

    // The quick one has already finished and restored nothing out from under
    // the slow one — which is the failure this test exists to catch.
    expect(quick).toBe(STRIPE)
    release()
    expect(await slow).toBe(STRIPE)
    expect(process.env.STRIPE_KEY).toBeUndefined()
  })

  test('a secret removed from the store stops resolving, with no new resolution', async () => {
    const store = await storeWith({ STRIPE_KEY: STRIPE })
    const resolution = hostSecretResolution({ store })

    expect(await resolution.around(() => process.env.STRIPE_KEY)).toBe(STRIPE)
    await store.remove('STRIPE_KEY')
    expect(await resolution.around(() => process.env.STRIPE_KEY)).toBeUndefined()
  })

  test('resolution refuses where there is no host process to resolve into', () => {
    expect(() => hostEnvOrRefuse(undefined)).toThrow(/host/)
    expect(() => hostEnvOrRefuse(null)).toThrow(/host/)
    expect(hostEnvOrRefuse({ PATH: '/usr/bin' })).toEqual({ PATH: '/usr/bin' })
  })
})

describe('a resolved value is reachable only by naming it', () => {
  /** Everything the environment yields to code that did not name the secret. */
  const waysToCopyTheEnvironment = (env: Record<string, string | undefined>) => [
    Object.keys(env).join(','),
    JSON.stringify(env),
    JSON.stringify({ ...env }),
    JSON.stringify(Object.entries(env)),
    JSON.stringify(Object.assign({}, env)),
    inspect(env, { depth: 2 }),
    String(new URLSearchParams(env as Record<string, string>)),
  ]

  test('no copy, spread, serialisation or inspection of the environment holds it', async () => {
    const store = await storeWith({ BILLING_TOKEN: BILLING })
    const resolution = hostSecretResolution({ store })

    const copies = await resolution.around(() => {
      // Named, so it is there.
      expect(process.env.BILLING_TOKEN).toBe(BILLING)
      return waysToCopyTheEnvironment(process.env)
    })

    for (const copy of copies) expect(copy).not.toContain(BILLING)
  })

  test('the environment the agent is spawned with does not carry it', async () => {
    const store = await storeWith({ BILLING_TOKEN: BILLING })
    const resolution = hostSecretResolution({ store })

    const forAgent = await resolution.around(() => {
      expect(process.env.BILLING_TOKEN).toBe(BILLING)
      // The real function that computes what Claude Code runs with. It walks
      // `Object.entries`, so a non-enumerable binding is not something it has to
      // remember to skip — it cannot see one.
      return agentEnvironment(process.env, { cloneRoot: '/tmp/clone', inherit: false })
    })

    expect(JSON.stringify(forAgent)).not.toContain(BILLING)
    expect(forAgent.BILLING_TOKEN).toBeUndefined()
  })

  test('a child process handed the whole environment does not receive it', async () => {
    const store = await storeWith({ BILLING_TOKEN: BILLING })
    const resolution = hostSecretResolution({ store })

    const printed = await resolution.around(() => {
      // The control and the claim in one command: a plain assignment crosses
      // into the child, and the resolved secret beside it does not.
      process.env.VARNICK_PROBE_PLAIN = 'plainly-inherited'
      try {
        return execFileSync('/usr/bin/env', [], { encoding: 'utf8', env: process.env })
      } finally {
        delete process.env.VARNICK_PROBE_PLAIN
      }
    })

    expect(printed).toContain('plainly-inherited')
    expect(printed).not.toContain(BILLING)
  })
})

describe('the resolution itself yields no value to anyone who holds it', () => {
  test('no member of a resolution, called, produces a value', async () => {
    const store = await storeWith({ BILLING_TOKEN: BILLING })
    const resolution = hostSecretResolution({ store })

    // `around` takes code and gives back what that code returned; `redact` takes
    // text and gives back less of it. Neither has a shape that could hand a
    // caller a value, and this asserts it over the object rather than the list.
    const yielded = [
      JSON.stringify(resolution),
      inspect(resolution, { depth: 3 }),
      ...Object.getOwnPropertyNames(resolution).map((name) => String(name)),
      resolution.redact(`the token is ${BILLING}`),
      await resolution.around(() => 'a module ran'),
    ]
    for (const item of yielded) expect(String(item)).not.toContain(BILLING)
  })

  test('redact removes a resolved value from text and leaves the name behind', async () => {
    const store = await storeWith({ BILLING_TOKEN: BILLING })
    const resolution = hostSecretResolution({ store })

    const said = resolution.redact(
      `BILLING_TOKEN was rejected: Bearer ${BILLING} is not a valid token`,
    )
    expect(said).not.toContain(BILLING)
    expect(said).toContain('[redacted]')
    expect(said).toContain('BILLING_TOKEN')
  })

  test('redact reads the store at the moment it is called, not when it was built', async () => {
    const store = await storeWith({})
    const resolution = hostSecretResolution({ store })

    expect(resolution.redact(`later: ${BILLING}`)).toContain(BILLING)
    await store.store('BILLING_TOKEN', BILLING)
    expect(resolution.redact(`later: ${BILLING}`)).not.toContain(BILLING)
  })
})

describe('nothing a resolved secret is worth reaches the Session mirror', () => {
  const roots: string[] = []
  const tempRoot = () => {
    const root = mkdtempSync(join(tmpdir(), 'varnick-resolution-mirror-'))
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

  test('a failure raised by resolved code cannot be found in the file the mirror wrote', async () => {
    const store = await storeWith({ BILLING_TOKEN: BILLING })
    const resolution = hostSecretResolution({ store })

    // The leak this closes: an integration that fails while it holds the value
    // and quotes it back. Real clients do this — the token is in the URL, or in
    // the header the error prints — and the sentence goes on screen and then
    // into the transcript.
    const said = await resolution
      .around(() => {
        throw new Error(`POST /charges failed: Bearer ${process.env.BILLING_TOKEN} rejected`)
      })
      .then(
        () => '',
        (error: unknown) =>
          resolution.redact(error instanceof Error ? error.message : String(error)),
      )

    expect(said).not.toContain(BILLING)
    expect(said).toContain('[redacted]')

    const root = tempRoot()
    const sessions = createSessionStore({ root, secretValues: () => store.secretValues() })
    await sessions.persist({
      sessionId: 'resolution-probe',
      messages: [
        { id: 'm1', role: 'agent', text: `The billing Surface failed: ${said}` },
        // And the unredacted form, to prove the mirror is the second net rather
        // than the only one.
        { id: 'm2', role: 'agent', text: `raw: Bearer ${BILLING} rejected` },
      ],
    })

    const onDisk = everythingUnder(root)
    expect(onDisk.length).toBeGreaterThan(0)
    expect(onDisk).not.toContain(BILLING)
    expect(onDisk).toContain('[redacted]')
  })
})
