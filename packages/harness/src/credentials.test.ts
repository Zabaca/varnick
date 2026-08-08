import { afterEach, describe, expect, test } from 'bun:test'
import { HarnessUnavailable } from './bridge.ts'
import {
  CREDENTIAL_ENV_VARS,
  CREDENTIAL_KEYCHAIN_ACCOUNTS,
  CREDENTIAL_KEYCHAIN_SERVICE,
  CREDENTIAL_SETUP_COMMANDS,
  CREDENTIAL_STORE_FAILURES,
  CredentialNotStored,
  CredentialUnavailable,
  SUBSCRIPTION_TOKEN_COMMAND,
  credentialGuidance,
  credentialRejection,
  credentialStoreGuidance,
  readCredential,
  storeCredential,
  tauriCredentialHost,
  tauriCredentialWriter,
  type CredentialAbsence,
  type CredentialHost,
  type CredentialStoreFailure,
  type CredentialWriter,
} from './credentials.ts'

/**
 * The seam: the exported surface of the credential module, and nothing below it.
 *
 * No test here reads or writes the real system keychain. It cannot: the only way
 * into `readCredential` is a `CredentialHost`, and every test supplies its own.
 * A test that touched the developer's keychain would be a failed test even if it
 * passed, so the injection point is the assertion.
 */

/**
 * A host that answers the way the Tauri command does on success.
 *
 * Two facts, because a reading is two facts: which store answered, and what was
 * in it. The kind defaults to `api-key` so the cases that predate ADR-0011 read
 * as what they always were.
 */
const answers = (source: unknown, kind: unknown = 'api-key'): CredentialHost => ({
  read: async () => ({ source, kind }),
})

/** A host that rejects the way the bridge rejects a refused call. */
const refuses = (payload: unknown): CredentialHost => ({
  read: async () => {
    throw payload
  },
})

/** The bridge's own refusal, carrying the tag the Rust host chose. */
const refusal = (tag: string) => new HarnessUnavailable('refused', tag)

/** A value shaped like a real key, used to prove it never comes back out. */
/*
  Assembled rather than written out: the value is invented, but its shape is one
  every secret scanner flags, and a literal of that shape blocks pushing for this
  repository and every fork of it.
*/
const LOOKS_LIKE_A_KEY = ['sk-', 'ant-api03-NEVER-LET-THIS-OUT'].join('')

describe('a successful read reports the store and the kind, and nothing else', () => {
  test('the keychain answered', async () => {
    expect(await readCredential(answers('keychain'))).toEqual({
      source: 'keychain',
      kind: 'api-key',
    })
  })

  test('the environment answered', async () => {
    expect(await readCredential(answers('env'))).toEqual({ source: 'env', kind: 'api-key' })
  })

  test('a subscription token is a reading of its own kind, from either store', async () => {
    // ADR-0011: the kind is a property of the credential that was resolved, not
    // a setting. Either kind can come from either store, so the two facts are
    // orthogonal and both have to travel.
    expect(await readCredential(answers('keychain', 'subscription'))).toEqual({
      source: 'keychain',
      kind: 'subscription',
    })
    expect(await readCredential(answers('env', 'subscription'))).toEqual({
      source: 'env',
      kind: 'subscription',
    })
  })

  test('a reading carries two fields, and they are the source and the kind', async () => {
    const reading = await readCredential(answers('keychain'))
    expect(Object.keys(reading)).toEqual(['source', 'kind'])
  })
})

describe('a failed read records which failure it was', () => {
  const absenceOf = async (host: CredentialHost | null): Promise<CredentialAbsence> => {
    try {
      await readCredential(host)
    } catch (error) {
      if (error instanceof CredentialUnavailable) return error.absence
      throw error
    }
    throw new Error('the read was expected to fail')
  }

  test('no host at all — a browser tab has no keychain to reach', async () => {
    expect(await absenceOf(null)).toBe('no-host')
  })

  test('nothing stored — the first-run case', async () => {
    expect(await absenceOf(refuses(refusal('nothing-stored')))).toBe('nothing-stored')
  })

  test('a store that exists and would not answer', async () => {
    expect(await absenceOf(refuses(refusal('store-unreadable')))).toBe('store-unreadable')
  })

  test('a bridge that never reached the host is an absence too, not a crash', async () => {
    expect(await absenceOf(refuses(new HarnessUnavailable('no-runtime')))).toBe('store-unreadable')
  })

  test('an absence the host does not name is still an absence, never a crash', async () => {
    expect(await absenceOf(refuses('something went wrong'))).toBe('store-unreadable')
  })

  test('a success the host malformed is a failure, not a reading', async () => {
    expect(await absenceOf(answers('elsewhere'))).toBe('store-unreadable')
  })

  test('a kind the host did not name is a failure, never a guess', async () => {
    // The kind decides which variable the agent is spawned with. Defaulting it
    // would mean spawning with a variable nobody resolved, and the symptom is
    // an agent that starts and cannot authenticate.
    // No `kind` field at all — an older host, or one that answered a shape
    // this build does not know.
    expect(await absenceOf({ read: async () => ({ source: 'keychain' }) })).toBe('store-unreadable')
    expect(await absenceOf(answers('keychain', 'oauth'))).toBe('store-unreadable')
  })

  test('every failure is a CredentialUnavailable, so nothing rejects unhandled', async () => {
    for (const host of [null, refuses(refusal('nothing-stored')), answers(undefined)]) {
      await expect(readCredential(host)).rejects.toBeInstanceOf(CredentialUnavailable)
    }
  })
})

describe('the three absences are legible and distinct', () => {
  const all: CredentialAbsence[] = ['nothing-stored', 'store-unreadable', 'no-host']

  test('each names a different thing', () => {
    const messages = all.map(credentialGuidance)
    expect(new Set(messages).size).toBe(all.length)
  })

  test('none is empty', () => {
    for (const absence of all) expect(credentialGuidance(absence).length).toBeGreaterThan(20)
  })

  test('the first-run message names both ways to supply a credential', () => {
    /*
      There are two kinds now, and a developer holding a Claude subscription who
      is told only about an API key is being told to pay twice. So the message
      names both — and it still names only the keychain for each, because the
      environment variables are the escape hatch rather than the advice a fresh
      clone opens with.
    */
    const message = credentialGuidance('nothing-stored')
    expect(message).toContain(CREDENTIAL_KEYCHAIN_SERVICE)
    expect(message).toContain(CREDENTIAL_KEYCHAIN_ACCOUNTS['api-key'])
    expect(message).toContain(CREDENTIAL_KEYCHAIN_ACCOUNTS.subscription)
    expect(message.match(/security add-generic-password/g)).toHaveLength(2)
  })

  test('the first-run message names the command that mints a subscription token', () => {
    // `claude setup-token`, and nothing about Claude Code's own credential
    // store. ADR-0011 refuses to read that item; a message that pointed at it
    // would be the refused implementation, described.
    const message = credentialGuidance('nothing-stored')
    expect(message).toContain(SUBSCRIPTION_TOKEN_COMMAND)
    expect(message).not.toContain('Claude Code-credentials')
  })

  test('every setup command ends at the flag that prompts, with no value on it', () => {
    // `security add-generic-password` takes the keychain as a positional
    // argument, so a `-w VALUE` written before it writes into whatever comes
    // next. Twice in this project's history that has been the wrong keychain.
    // Ending at a bare `-w` makes the tool prompt instead.
    for (const command of Object.values(CREDENTIAL_SETUP_COMMANDS)) {
      expect(command.endsWith(' -w')).toBe(true)
    }
  })

  test('the no-host message says where the credential is actually read', () => {
    expect(credentialGuidance('no-host')).toContain('tauri dev')
  })

  test('the error message is the guidance, so the machine records it verbatim', () => {
    expect(new CredentialUnavailable('nothing-stored').message).toBe(
      credentialGuidance('nothing-stored'),
    )
  })
})

describe('nothing the host said can reach a message', () => {
  const messageOf = async (host: CredentialHost): Promise<string> => {
    try {
      await readCredential(host)
    } catch (error) {
      return error instanceof Error ? error.message : String(error)
    }
    throw new Error('the read was expected to fail')
  }

  test('an unrecognised rejection payload is not quoted', async () => {
    const message = await messageOf(refuses(refusal(LOOKS_LIKE_A_KEY)))
    expect(message).not.toContain(LOOKS_LIKE_A_KEY)
  })

  test('a rejection that is a bare string is not quoted', async () => {
    expect(await messageOf(refuses(LOOKS_LIKE_A_KEY))).not.toContain(LOOKS_LIKE_A_KEY)
  })

  test('a rejection that is an Error is not quoted', async () => {
    expect(await messageOf(refuses(new Error(LOOKS_LIKE_A_KEY)))).not.toContain(LOOKS_LIKE_A_KEY)
  })

  test('a malformed success is not quoted either', async () => {
    expect(await messageOf(answers(LOOKS_LIKE_A_KEY))).not.toContain(LOOKS_LIKE_A_KEY)
  })

  test('a host that volunteers the value gets no help carrying it further', async () => {
    const chatty: CredentialHost = {
      read: async () => ({
        source: 'keychain',
        kind: 'subscription',
        value: LOOKS_LIKE_A_KEY,
        apiKey: LOOKS_LIKE_A_KEY,
      }),
    }
    const reading = await readCredential(chatty)
    expect(JSON.stringify(reading)).not.toContain(LOOKS_LIKE_A_KEY)
    expect(Object.keys(reading)).toEqual(['source', 'kind'])
  })
})

describe('a credential can be stored from inside the window', () => {
  /**
   * A writer that records what it was handed and says it worked.
   *
   * Like {@link answers} above, this is the seam: `storeCredential` takes a
   * `CredentialWriter` and there is no code path from it to a keychain. A test
   * that wrote into the developer's own store would be a failed test even if it
   * passed, and here that is impossible rather than merely forbidden.
   */
  const records = () => {
    const seen: { kind: string; value: string }[] = []
    const writer: CredentialWriter = {
      store: async (request) => {
        seen.push({ ...request })
      },
    }
    return { seen, writer }
  }

  /** A writer that rejects the way the bridge rejects a refused call. */
  const refusesWrite = (payload: unknown): CredentialWriter => ({
    store: async () => {
      throw payload
    },
  })

  const failureOf = async (
    writer: CredentialWriter | null,
    value = LOOKS_LIKE_A_KEY,
  ): Promise<CredentialStoreFailure> => {
    try {
      await storeCredential({ kind: 'api-key', value }, writer)
    } catch (error) {
      if (error instanceof CredentialNotStored) return error.failure
      throw error
    }
    throw new Error('the store was expected to fail')
  }

  test('the value reaches the host once, with the kind the developer chose', async () => {
    const { seen, writer } = records()
    await storeCredential({ kind: 'subscription', value: LOOKS_LIKE_A_KEY }, writer)
    expect(seen).toEqual([{ kind: 'subscription', value: LOOKS_LIKE_A_KEY }])
  })

  test('either kind can be written, and the choice is only which item', async () => {
    // ADR-0011 is unchanged by this: the developer picks which item is
    // *written*, and the host still resolves the kind by what it finds on the
    // next read. Nothing here records a preference for it to consult.
    const { seen, writer } = records()
    await storeCredential({ kind: 'api-key', value: 'a-key' }, writer)
    await storeCredential({ kind: 'subscription', value: 'a-token' }, writer)
    expect(seen.map((s) => s.kind)).toEqual(['api-key', 'subscription'])
  })

  test('a store answers with nothing, so nothing can come back in it', async () => {
    /*
      The whole of "the value goes one direction". `storeCredential` is typed
      `Promise<void>`, so there is no shape on the success path a value could
      ride back in — the same property `Reading` has for a read, one step
      stronger because a store has nothing at all to report.
    */
    const chatty: CredentialWriter = {
      store: async () => ({ value: LOOKS_LIKE_A_KEY }) as unknown as void,
    }
    const answer = await storeCredential({ kind: 'api-key', value: LOOKS_LIKE_A_KEY }, chatty)
    expect(answer).toBeUndefined()
  })

  test('no host is a failure with a reason, never a throw from the bridge', async () => {
    expect(await failureOf(null)).toBe('no-host')
  })

  test('every tag the host can choose is carried through as itself', async () => {
    // Each of these is a `&'static str` in src-tauri/src/credential.rs, chosen
    // by a match arm. They are kept apart because each has a different single
    // next action, the same reason `CredentialAbsence` has three.
    expect(await failureOf(refusesWrite(refusal('nothing-pasted')))).toBe('nothing-pasted')
    expect(await failureOf(refusesWrite(refusal('unstorable-value')))).toBe('unstorable-value')
    expect(await failureOf(refusesWrite(refusal('store-refused')))).toBe('store-refused')
    expect(await failureOf(refusesWrite(refusal('no-keychain')))).toBe('no-keychain')
  })

  test('a tag this build does not know is a refused store, never a quoted one', async () => {
    // An unrecognised payload is exactly the payload nobody has checked for a
    // secret, so it is classified rather than repeated.
    expect(await failureOf(refusesWrite(refusal('something-new')))).toBe('store-refused')
    expect(await failureOf(refusesWrite(new HarnessUnavailable('runtime-lost')))).toBe(
      'store-refused',
    )
    expect(await failureOf(refusesWrite('a bare string'))).toBe('store-refused')
  })

  test('every failure is a CredentialNotStored, so nothing rejects unhandled', async () => {
    for (const writer of [null, refusesWrite(refusal('store-refused')), refusesWrite(new Error('x'))]) {
      await expect(
        storeCredential({ kind: 'api-key', value: 'a-value' }, writer),
      ).rejects.toBeInstanceOf(CredentialNotStored)
    }
  })

  test('nothing a failed store says can contain what was pasted', async () => {
    /*
      The one assertion this whole path exists for, and it is asserted rather
      than inspected. Every way a store can fail, over a value shaped like a
      real key, and the sentence the developer reads must not contain it —
      including the case where the host itself echoed it back.
    */
    const rejections: unknown[] = [
      refusal('nothing-pasted'),
      refusal('unstorable-value'),
      refusal('store-refused'),
      refusal('no-keychain'),
      refusal(LOOKS_LIKE_A_KEY),
      new Error(LOOKS_LIKE_A_KEY),
      LOOKS_LIKE_A_KEY,
      { failure: 'refused', detail: LOOKS_LIKE_A_KEY },
    ]
    for (const rejection of rejections) {
      try {
        await storeCredential({ kind: 'subscription', value: LOOKS_LIKE_A_KEY }, refusesWrite(rejection))
      } catch (error) {
        const thrown = error as CredentialNotStored
        expect(thrown.message).not.toContain(LOOKS_LIKE_A_KEY)
        expect(JSON.stringify(thrown, Object.getOwnPropertyNames(thrown))).not.toContain(
          LOOKS_LIKE_A_KEY,
        )
        continue
      }
      throw new Error('the store was expected to fail')
    }
  })

  test('each failure names a different thing to do about it', () => {
    const messages = CREDENTIAL_STORE_FAILURES.map(credentialStoreGuidance)
    expect(new Set(messages).size).toBe(CREDENTIAL_STORE_FAILURES.length)
    for (const message of messages) expect(message.length).toBeGreaterThan(20)
  })

  test('the refusals a paste can earn say what about the paste was wrong', () => {
    // These two are the developer's own typing rather than a broken machine,
    // and the sentence has to be about what they did.
    expect(credentialStoreGuidance('nothing-pasted')).toContain('paste')
    expect(credentialStoreGuidance('unstorable-value')).toContain('one line')
  })

  test('the no-host message says where a credential is actually written', () => {
    expect(credentialStoreGuidance('no-host')).toContain('tauri dev')
  })

  test('the error message is the guidance, so the machine records it verbatim', () => {
    expect(new CredentialNotStored('store-refused').message).toBe(
      credentialStoreGuidance('store-refused'),
    )
  })

  test('a browser tab has nowhere to write, and that is a value rather than a throw', () => {
    expect(tauriCredentialWriter()).toBeNull()
  })
})

describe('a rejection by the API is its own outcome', () => {
  test('a 401 is a rejected credential', () => {
    expect(credentialRejection({ status: 401 })).not.toBeNull()
  })

  test('an authentication_error is a rejected credential', () => {
    expect(credentialRejection(new Error('authentication_error: invalid x-api-key'))).not.toBeNull()
  })

  test('the Agent SDK’s own name for it is a rejected credential too', () => {
    // The SDK reports a refused credential as `authentication_failed` rather
    // than as an HTTP status. A classifier that missed it would let the one
    // failure meaning `credential.rejected` land as an ordinary failed turn,
    // and a developer would retry the conversation instead of fixing the key.
    expect(credentialRejection(new Error('authentication_failed'))).not.toBeNull()
    expect(credentialRejection('authentication_failed')).not.toBeNull()
  })

  test('a 500 is not — that is the agent being broken, which is a different fix', () => {
    expect(credentialRejection({ status: 500 })).toBeNull()
  })

  test('an ordinary failure is not a rejected credential', () => {
    expect(credentialRejection(new Error('stream closed unexpectedly'))).toBeNull()
  })

  test('nothing is not a rejected credential', () => {
    expect(credentialRejection(undefined)).toBeNull()
    expect(credentialRejection(null)).toBeNull()
  })

  test('the detail is constructed, never copied out of the failure', () => {
    const rejection = credentialRejection(new Error(`401 authentication_error ${LOOKS_LIKE_A_KEY}`))
    expect(rejection).not.toBeNull()
    expect(rejection?.detail).not.toContain(LOOKS_LIKE_A_KEY)
    expect(rejection?.detail.length).toBeGreaterThan(0)
  })
})

describe('the read rides the one bridge, like every other Harness call', () => {
  afterEach(() => {
    delete (globalThis as { __TAURI_INTERNALS__?: unknown }).__TAURI_INTERNALS__
  })

  test('a plain browser tab has no host, and that is a value rather than a throw', () => {
    expect(tauriCredentialHost()).toBeNull()
  })

  test('a read is a bridge call, and asks for nothing but the credential', async () => {
    const invoked: unknown[] = []
    ;(globalThis as { __TAURI_INTERNALS__?: unknown }).__TAURI_INTERNALS__ = {
      invoke: async (command: string, payload?: unknown) => {
        invoked.push([command, payload])
        return { source: 'keychain', kind: 'subscription' }
      },
    }

    const host = tauriCredentialHost()
    expect(host).not.toBeNull()
    expect(await readCredential(host)).toEqual({ source: 'keychain', kind: 'subscription' })
    expect(invoked).toEqual([['harness_call', { request: { kind: 'read-credential' } }]])
  })

  test('a store is a bridge call too, and the value goes one way', async () => {
    const invoked: unknown[] = []
    ;(globalThis as { __TAURI_INTERNALS__?: unknown }).__TAURI_INTERNALS__ = {
      invoke: async (command: string, payload?: unknown) => {
        invoked.push([command, payload])
        return { ok: true }
      },
    }

    const writer = tauriCredentialWriter()
    expect(writer).not.toBeNull()
    await storeCredential({ kind: 'subscription', value: LOOKS_LIKE_A_KEY }, writer)
    expect(invoked).toEqual([
      [
        'harness_call',
        {
          request: {
            kind: 'store-credential',
            credentialKind: 'subscription',
            value: LOOKS_LIKE_A_KEY,
          },
        },
      ],
    ])
  })

  test('each kind names the variable the Agent SDK reads it from', () => {
    // Both are first-class authentication variables to the Agent SDK, listed
    // side by side in its own credential table — ADR-0011. Mirrored as ENV_VAR
    // in src-tauri/src/credential.rs and CREDENTIAL_ENV_VAR_NAMES in ./agent.ts.
    expect(CREDENTIAL_ENV_VARS['api-key']).toBe('ANTHROPIC_API_KEY')
    expect(CREDENTIAL_ENV_VARS.subscription).toBe('CLAUDE_CODE_OAUTH_TOKEN')
  })
})
