// The Secrets Store: host-side storage the agent can never read.
//
// The agent is told a secret's *name* and writes code that references it; the
// host substitutes the value when it runs that code (ADR-0006). This module is
// the store half. Resolution — the substitution itself — is ./secret-resolution.ts.
//
// **Storage is the system keychain**, the same store the credential lives in
// (src-tauri/src/credential.rs), one item per secret under its own service.
// The transcript's answer — JSON Lines the developer can `cat` — is deliberately
// not reused: a file you can read is exactly right for a transcript and exactly
// wrong for a key.
//
// ## The keychain does not currently keep the agent out, and that was measured
//
// The keychain was chosen partly because the Sandbox denies the agent read on
// `/usr/bin/security`, so it could not run the one program that opens the store.
// The first half is true and the second does not follow: srt allows `process-exec`
// unconditionally, and `security` reaches securityd over Mach rather than by
// reading the keychain files that the home-directory denial covers. A command
// under the real policy read a stored value back in plaintext. The measurement
// and what it would take to close it are in sandbox.boundary.test.ts and in the
// correction appended to ADR-0003.
//
// Nothing in this module can fix that, and nothing in it pretends to. What it
// still does is keep values out of everywhere else — out of the renderer, out of
// argv, out of an error message, and out of the Session mirror.
//
// Nothing here imports from `packages/core`; the dependency runs Core -> Harness.
//
// ## Where the values are, and are not
//
// This module is host-side by construction. `securityKeychain()` reaches
// `node:child_process` through a dynamic import with a non-literal specifier, so
// a browser bundle never contains it and a renderer that calls it throws. The
// values a loaded store holds live in that host process and leave it in exactly
// one direction: `secretValues()`, which exists to feed the Session mirror's
// redaction pass and is named so that a call site reads as what it is. Every
// other member answers with names.
//
// It has a second reader now: `hostSecretResolution` in ./secret-resolution.ts
// zips it against `names()` to bind `process.env.NAME` while the host runs a
// Userspace module. Still one direction out, and still through the member that
// says what it yields — there is deliberately no `get(name)`, because a store
// with one is a store something can be talked into asking.

/**
 * The keychain service holding one item per secret.
 *
 * Its own service rather than the credential's, so that a bug in one cannot
 * address the other: the credential is `varnick`/`anthropic-api-key`, and no
 * secret can be named `anthropic-api-key` because a secret name has to be an
 * identifier.
 */
export const SECRETS_KEYCHAIN_SERVICE = 'varnick-secrets'

/**
 * The account holding the list of names.
 *
 * `security` can find an item by service and account but cannot enumerate a
 * service, so the names are stored as an item of their own. The dot is what
 * keeps it out of the namespace of real secrets, which are identifiers and
 * therefore cannot contain one.
 */
export const SECRETS_INDEX_ACCOUNT = 'varnick.index'

/** What a developer types, once per secret. Reads the value on stdin. */
export const SECRET_ADD_COMMAND = 'bun run secret add <NAME>'
export const SECRET_REMOVE_COMMAND = 'bun run secret remove <NAME>'

/**
 * The keychain, as a port.
 *
 * Injected rather than reached directly, and with **no default** — see
 * `openSecretsStore`. Accounts are secret names, plus {@link SECRETS_INDEX_ACCOUNT}.
 */
export interface SecretsKeychain {
  /** The item's value, or `null` when there is no such item. */
  read(account: string): Promise<string | null>
  /** Create or replace the item. */
  write(account: string, value: string): Promise<void>
  /** Delete the item. Removing one that is not there is not an error. */
  remove(account: string): Promise<void>
}

/**
 * A secret name has to be something the agent can write into code.
 *
 * `process.env.STRIPE_KEY` is the shape ADR-0006 describes, so a name is a
 * JavaScript identifier: anything else produces code that does not compile, and
 * the agent cannot see the value to notice. It doubles as the reason a name can
 * never address another keychain account — no dot, no colon, no slash.
 *
 * Pure. Returns the sentence to show, or `null` when the name is fine.
 */
export function secretNameProblem(name: unknown): string | null {
  if (typeof name !== 'string' || name.length === 0) {
    return 'A secret needs a name. Names are what the agent is given in place of values, so an unnamed secret is one it can never use.'
  }
  if (name.length > 128) {
    return `That name is ${name.length} characters. A secret name is at most 128, because it has to be legible in the code the agent writes.`
  }
  if (!/^[A-Za-z_][A-Za-z0-9_]*$/.test(name)) {
    return `${JSON.stringify(name)} is not usable as a name. A secret is referenced from code as \`process.env.NAME\`, so a name must start with a letter or underscore and hold only letters, digits and underscores.`
  }
  return null
}

/**
 * A value the store will accept, and why the set is not "any string".
 *
 * `security find-generic-password -w` prints the item as a hex string the
 * moment its data holds a byte outside printable ASCII, and there is no flag
 * that says which of the two forms you were handed. Measured, not assumed: a
 * tab, a newline, and a `é` all come back as hex; quotes, backslashes, `=` and
 * spaces all come back verbatim. A store that accepted a tab would read that
 * secret back as a string of hex digits and hand the built code the wrong bytes,
 * failing as an authentication error far from the cause.
 *
 * So the accepted set is printable ASCII with no whitespace at either end. That
 * is every API key and token, and it is not a PEM private key — which is a real
 * limit, stated here rather than discovered later.
 *
 * The value itself is never quoted into the sentence.
 */
function secretValueProblem(value: unknown, name: string): string | null {
  if (typeof value !== 'string' || value.trim().length === 0) {
    return `${name} was given an empty value. An empty secret resolves to nothing at run time, which fails as an authentication error rather than as a missing secret.`
  }
  if (value !== value.trim()) {
    return `${name} was given a value with whitespace around it. The store refuses rather than trimming, because a value it trimmed and a value it stored would look the same afterwards and only one of them would work.`
  }
  if (!/^[\x20-\x7e]+$/.test(value)) {
    return `${name} was given a value holding a line break, a tab, or a character outside printable ASCII. varnick keeps secrets in the system keychain, and \`security\` hands such a value back hex-encoded with no way to tell that apart from a value that was hex to begin with — so the store refuses it rather than resolving it to the wrong bytes later. Single-line keys and tokens are what fits; a PEM private key does not.`
  }
  return null
}

/** Refusals and store failures alike. One class, so nothing rejects unhandled. */
export class SecretsError extends Error {
  constructor(message: string, options?: { cause?: unknown }) {
    super(message, options)
    this.name = 'SecretsError'
  }
}

export interface SecretsStore {
  /** The names, in the order they were added. Never a value. */
  names(): readonly string[]
  has(name: string): boolean
  /**
   * Re-read the keychain.
   *
   * The store a developer changed from the CLI is a different process holding
   * a different snapshot, so a running varnick learns about it here. Every
   * change made *through this store* is already visible without one.
   */
  reload(): Promise<void>
  /** Add a secret, or replace the value under a name already stored. */
  store(name: string, value: string): Promise<void>
  rename(from: string, to: string): Promise<void>
  remove(name: string): Promise<void>
  /**
   * The values, for redaction and nothing else.
   *
   * This is what `createSessionStore`'s `secretValues` option is fed, and the
   * only member of this interface that yields a value. It is deliberately not
   * called `values()`: a call site reading `secrets.secretValues()` says what it
   * is doing with them.
   */
  secretValues(): Iterable<string>
}

export interface SecretsStoreOptions {
  /**
   * Required, with no default.
   *
   * `createSessionStore` takes an optional `fs` because the wrong default there
   * writes a file. The wrong default here reads the developer's actual keychain,
   * so there is no argument to leave out: a test cannot touch the real store by
   * forgetting one, because forgetting one does not typecheck.
   */
  keychain: SecretsKeychain
}

function parseIndex(raw: string | null): string[] {
  if (raw === null) return []
  const trimmed = raw.trim()
  if (trimmed.length === 0) return []

  let parsed: unknown
  try {
    parsed = JSON.parse(trimmed)
  } catch (cause) {
    throw new SecretsError(
      `The Secrets Store index is not readable as a list of names. Nothing has been lost — the secrets are still in the keychain under the ${SECRETS_KEYCHAIN_SERVICE} service — but varnick will not guess at which ones exist. Repair or delete the ${SECRETS_INDEX_ACCOUNT} item and add the names back.`,
      { cause },
    )
  }

  if (!Array.isArray(parsed) || parsed.some((name) => secretNameProblem(name) !== null)) {
    throw new SecretsError(
      `The Secrets Store index holds something other than a list of secret names. Repair or delete the ${SECRETS_INDEX_ACCOUNT} item in the ${SECRETS_KEYCHAIN_SERVICE} service, then add the names back.`,
    )
  }

  return parsed as string[]
}

/**
 * Open the store and load what the keychain holds.
 *
 * Loading up front is what lets `names()` and `secretValues()` be synchronous:
 * `secretValues` is called on the Session mirror's write path, once per save,
 * and a store that shelled out to `security` there would put a subprocess
 * between a Turn and its transcript.
 *
 * A keychain that refuses raises. Nothing here degrades into an empty store on
 * failure — an empty store is indistinguishable from a working one that knows
 * no secrets, and it would silently stop the mirror redacting.
 */
export async function openSecretsStore(options: SecretsStoreOptions): Promise<SecretsStore> {
  const keychain = options.keychain

  /** Name -> value, in insertion order. The loaded snapshot. */
  let held = new Map<string, string>()

  const readIndex = async (): Promise<string[]> =>
    parseIndex(await keychain.read(SECRETS_INDEX_ACCOUNT))

  const writeIndex = (names: readonly string[]): Promise<void> =>
    keychain.write(SECRETS_INDEX_ACCOUNT, JSON.stringify(names))

  const load = async (): Promise<void> => {
    const loaded = new Map<string, string>()
    for (const name of await readIndex()) {
      const value = await keychain.read(name)
      // A name whose item has gone — deleted by hand with `security`, usually.
      // Dropped rather than listed: a name the agent builds against and the host
      // cannot resolve fails at run time, in the built Surface, far from here.
      if (value === null) continue
      loaded.set(name, value.trim())
    }
    held = loaded
  }

  // Writes are serialised. Two overlapping changes would each read the index
  // before either wrote it, and the second would drop the first's name.
  let queue: Promise<unknown> = Promise.resolve()
  const serialised = <T>(work: () => Promise<T>): Promise<T> => {
    const run = queue.then(work, work)
    queue = run.then(
      () => undefined,
      () => undefined,
    )
    return run
  }

  await load()

  return {
    names: () => [...held.keys()],

    has: (name) => held.has(name),

    reload: () => serialised(load),

    store: (name, value) =>
      serialised(async () => {
        const nameProblem = secretNameProblem(name)
        if (nameProblem !== null) throw new SecretsError(nameProblem)
        const valueProblem = secretValueProblem(value, name)
        if (valueProblem !== null) throw new SecretsError(valueProblem)

        // The item first, then the index. This order can leave an orphan item
        // that nothing lists, which is invisible and harmless. The other order
        // leaves a listed name with no value, which is what the agent writes
        // code against.
        await keychain.write(name, value)
        const names = held.has(name) ? [...held.keys()] : [...held.keys(), name]
        await writeIndex(names)

        const next = new Map<string, string>()
        for (const listed of names)
          next.set(listed, listed === name ? value : (held.get(listed) as string))
        held = next
      }),

    rename: (from, to) =>
      serialised(async () => {
        const problem = secretNameProblem(to)
        if (problem !== null) throw new SecretsError(problem)
        const value = held.get(from)
        if (value === undefined) {
          throw new SecretsError(
            `There is no secret named ${JSON.stringify(from)}. \`bun run secret list\` shows the names this store holds.`,
          )
        }
        if (from !== to && held.has(to)) {
          throw new SecretsError(
            `A secret named ${JSON.stringify(to)} already exists. Rename or remove that one first — replacing it here would discard a value nobody can read back.`,
          )
        }
        if (from === to) return

        // Same order as `store`, one step longer: the new item, then the index,
        // then the old item. A failure at any point leaves every listed name
        // resolvable.
        await keychain.write(to, value)
        const names = [...held.keys()].map((listed) => (listed === from ? to : listed))
        await writeIndex(names)
        await keychain.remove(from)

        const next = new Map<string, string>()
        for (const listed of names)
          next.set(listed, listed === to ? value : (held.get(listed) as string))
        held = next
      }),

    remove: (name) =>
      serialised(async () => {
        if (!held.has(name)) {
          throw new SecretsError(
            `There is no secret named ${JSON.stringify(name)}. \`bun run secret list\` shows the names this store holds.`,
          )
        }

        // The index first this time, for the same reason in reverse: what must
        // never happen is a listed name with no item behind it.
        const names = [...held.keys()].filter((listed) => listed !== name)
        await writeIndex(names)
        await keychain.remove(name)

        const next = new Map(held)
        next.delete(name)
        held = next
      }),

    secretValues: () => [...held.values()],
  }
}

/**
 * What the agent is told about secrets.
 *
 * Names, the shape to reference them by, and the fact that asking for a value
 * is not a thing that can succeed — an agent that does not know the last part
 * spends turns trying. Composed from names alone, so there is no code path here
 * through which a value could arrive.
 */
export function describeSecretsForAgent(names: readonly string[]): string {
  const rule =
    'You cannot read a secret value, and no tool will return one. Reference a secret by name only; the host substitutes the value when it runs the code you wrote.'

  if (names.length === 0) {
    return [
      'No secrets are stored.',
      '',
      rule,
      `The developer adds one with \`${SECRET_ADD_COMMAND}\`.`,
    ].join('\n')
  }

  return [
    'Secrets available to code you write, by name:',
    '',
    ...names.map((name) => `  ${name}`),
    '',
    rule,
    'In code that means `process.env.NAME`.',
  ].join('\n')
}

/**
 * The keychain as the host has it: `/usr/bin/security`.
 *
 * `node:child_process` is reached through a dynamic import with a non-literal
 * specifier so that a browser bundler leaves it alone entirely — the same reason
 * `nodeSessionFs` does it. Called from a renderer this throws, which is the
 * honest answer: the store is host-side by definition, and a webview that could
 * open it is a webview that holds secret values.
 */
export function securityKeychain(): SecretsKeychain {
  const specifier = 'node:child_process'
  const load = async () => {
    try {
      return (await import(/* @vite-ignore */ specifier)) as typeof import('node:child_process')
    } catch (cause) {
      throw new SecretsError(
        'The Secrets Store needs a host process to reach the keychain and there is none here. Supply a SecretsKeychain, or open the store from the host.',
        { cause },
      )
    }
  }

  /**
   * Run `security` and answer with its exit code and stdout.
   *
   * `stderr` is captured and dropped. Nothing `security` printed is ever put in
   * an error message: the one command that handles secrets is the one most
   * likely to echo one back.
   *
   * `input` is `security`'s own interactive mode — commands read from stdin.
   * That is how a value is written without ever appearing in argv, and it
   * matters here: `/bin/ps` is not on the denied list, so a sandboxed agent that
   * caught a `security add-generic-password -w <value>` in flight would read the
   * secret out of the process table. Exit codes propagate through `-i` unchanged
   * — measured, including 44 for a missing item.
   */
  const security = async (
    args: string[],
    input?: string,
  ): Promise<{ code: number; stdout: string }> => {
    const { execFile } = await load()
    return new Promise((resolve, reject) => {
      const child = execFile('/usr/bin/security', args, { encoding: 'utf8' }, (error, stdout) => {
        if (error === null) return resolve({ code: 0, stdout })
        const code = (error as NodeJS.ErrnoException & { code?: number | string }).code
        if (typeof code === 'number') return resolve({ code, stdout })
        // No `security` binary at all — a platform with no keychain. Reported
        // as a store that would not answer, never as an empty one.
        reject(
          new SecretsError(
            'The Secrets Store could not run /usr/bin/security. varnick keeps secrets in the system keychain, which this platform does not have.',
          ),
        )
      })
      if (input !== undefined) {
        child.stdin?.end(input)
      }
    })
  }

  return {
    async read(account) {
      const { code, stdout } = await security([
        'find-generic-password',
        '-s',
        SECRETS_KEYCHAIN_SERVICE,
        '-a',
        account,
        '-w',
      ])
      // 44 is `security`'s "item not found" — an absent item, not a broken store.
      if (code === 44) return null
      if (code !== 0) {
        throw new SecretsError(
          `The keychain would not answer for the ${SECRETS_KEYCHAIN_SERVICE} service. Open Keychain Access and allow varnick to read it, then try again.`,
        )
      }
      return stdout.replace(/\n$/, '')
    },

    async write(account, value) {
      // Hex, so the only part of this command line that varies is `[0-9a-f]+`
      // and there is nothing to quote — `security -i` has its own tokeniser and
      // a value carrying a space or a quote would otherwise be parsed as two
      // arguments. `-X` sets the item's data to the bytes that hex decodes to,
      // so what lands in the keychain is the value itself and a developer
      // reading the item by hand sees their key.
      //
      // `-U` updates in place when the item exists, so storing over a name is
      // one call rather than a delete and an add with a gap between them.
      const hex = Buffer.from(value, 'utf8').toString('hex')
      const { code } = await security(
        ['-i'],
        `add-generic-password -s ${SECRETS_KEYCHAIN_SERVICE} -a ${account} -X ${hex} -U\n`,
      )
      if (code !== 0) {
        throw new SecretsError(
          `The keychain refused to store an item in the ${SECRETS_KEYCHAIN_SERVICE} service. Nothing was changed.`,
        )
      }
    },

    async remove(account) {
      const { code } = await security([
        'delete-generic-password',
        '-s',
        SECRETS_KEYCHAIN_SERVICE,
        '-a',
        account,
      ])
      if (code !== 0 && code !== 44) {
        throw new SecretsError(
          `The keychain refused to delete an item from the ${SECRETS_KEYCHAIN_SERVICE} service.`,
        )
      }
    },
  }
}
