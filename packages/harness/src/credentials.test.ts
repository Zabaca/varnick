import { afterEach, describe, expect, test } from 'bun:test'
import { HarnessUnavailable } from './bridge.ts'
import {
  CREDENTIAL_ENV_VAR,
  CREDENTIAL_KEYCHAIN_ACCOUNT,
  CREDENTIAL_KEYCHAIN_SERVICE,
  CredentialUnavailable,
  credentialGuidance,
  credentialRejection,
  readCredential,
  tauriCredentialHost,
  type CredentialAbsence,
  type CredentialHost,
} from './credentials.ts'

/**
 * The seam: the exported surface of the credential module, and nothing below it.
 *
 * No test here reads or writes the real system keychain. It cannot: the only way
 * into `readCredential` is a `CredentialHost`, and every test supplies its own.
 * A test that touched the developer's keychain would be a failed test even if it
 * passed, so the injection point is the assertion.
 */

/** A host that answers the way the Tauri command does on success. */
const answers = (source: unknown): CredentialHost => ({
  read: async () => ({ source }),
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
const LOOKS_LIKE_A_KEY = 'sk-" + "ant-api03-NEVER-LET-THIS-OUT'

describe('a successful read reports the store and nothing else', () => {
  test('the keychain answered', async () => {
    expect(await readCredential(answers('keychain'))).toEqual({ source: 'keychain' })
  })

  test('the environment answered', async () => {
    expect(await readCredential(answers('env'))).toEqual({ source: 'env' })
  })

  test('a reading carries one field, and it is the source', async () => {
    const reading = await readCredential(answers('keychain'))
    expect(Object.keys(reading)).toEqual(['source'])
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

  test('the first-run message names the single thing to do, once', () => {
    const message = credentialGuidance('nothing-stored')
    expect(message).toContain('security add-generic-password')
    expect(message).toContain(CREDENTIAL_KEYCHAIN_SERVICE)
    expect(message).toContain(CREDENTIAL_KEYCHAIN_ACCOUNT)
    // One instruction, not a menu. The env var is the escape hatch, not the
    // advice a fresh clone opens with.
    expect(message.match(/security add-generic-password/g)).toHaveLength(1)
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
      read: async () => ({ source: 'keychain', value: LOOKS_LIKE_A_KEY, apiKey: LOOKS_LIKE_A_KEY }),
    }
    const reading = await readCredential(chatty)
    expect(JSON.stringify(reading)).not.toContain(LOOKS_LIKE_A_KEY)
    expect(Object.keys(reading)).toEqual(['source'])
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
        return { source: 'keychain' }
      },
    }

    const host = tauriCredentialHost()
    expect(host).not.toBeNull()
    expect(await readCredential(host)).toEqual({ source: 'keychain' })
    expect(invoked).toEqual([['harness_call', { request: { kind: 'read-credential' } }]])
  })

  test('the env var the host injects is the one the Agent SDK reads', () => {
    expect(CREDENTIAL_ENV_VAR).toBe('ANTHROPIC_API_KEY')
  })
})
