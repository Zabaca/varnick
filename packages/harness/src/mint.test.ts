import { describe, expect, test } from 'bun:test'
import { HarnessUnavailable, type HarnessBridge, type HarnessRequest } from './bridge.ts'
import {
  CREDENTIAL_MINT_FAILURES,
  CredentialNotMinted,
  SUBSCRIPTION_TOKEN_COMMAND,
  credentialMintGuidance,
  mintSubscriptionToken,
  type CredentialMintFailure,
  type MintObserver,
} from './credentials.ts'
import { parseMintEvent } from './mint.ts'

/**
 * The seam: what Core can learn from a mint, and nothing below it.
 *
 * **No test here runs the real flow, and none can.** `claude setup-token` opens
 * a browser and authenticates a human, and what it prints is a live credential —
 * one ended up in a session transcript during measurement and had to be treated
 * as compromised. The only way into `mintSubscriptionToken` is a
 * {@link HarnessBridge}, and every test supplies its own, so a test that reached
 * the real command would be a compile error rather than a bad afternoon.
 *
 * The value itself is never in scope on this side at all: the host mints it,
 * reads it off a pty and writes it into the keychain. What these tests are
 * about is that the two things that *do* cross — a URL and an outcome — carry
 * nothing else, and that every way of failing produces a sentence Core authored.
 */

/** A value shaped like a real token, used to prove nothing here can carry one. */
/*
  Assembled rather than written out, like its counterparts elsewhere: the value
  is invented, but its shape is one every secret scanner flags, and a literal of
  that shape blocks pushing for this repository and every fork of it.
*/
const LOOKS_LIKE_A_TOKEN = ['sk-', 'ant-oat01-NEVER-LET-THIS-OUT'].join('')

const SIGN_IN_AT = 'https://claude.com/cai/oauth/authorize?state=test'

/** A host that answers the mint with these events, in order, then nothing. */
function answering(events: unknown[]): HarnessBridge & { asked: string[] } {
  const asked: string[] = []
  const queue = [...events]
  return {
    asked,
    call: async (request: HarnessRequest) => {
      asked.push(request.kind)
      if (request.kind === 'mint-subscription-token') return { ok: true }
      if (request.kind === 'next-mint-event') return { event: queue.shift() ?? null }
      throw new HarnessUnavailable('malformed')
    },
  }
}

/** A host that refuses the way the Rust host refuses, with its tag. */
const refusing = (tag: string): HarnessBridge => ({
  call: async () => {
    throw new HarnessUnavailable('refused', tag)
  },
})

/** A mint nobody is watching, for the cases the URL is not about. */
const unwatched: MintObserver = { authorizing: () => {} }

const failureOf = async (bridge: HarnessBridge | null): Promise<CredentialMintFailure> => {
  try {
    await mintSubscriptionToken(unwatched, bridge)
  } catch (error) {
    if (error instanceof CredentialNotMinted) return error.failure
    throw error
  }
  throw new Error('the mint was expected to fail')
}

describe('a mint answers with nothing, because there is nothing it could answer with', () => {
  test('a stored token settles the call and returns void', async () => {
    const bridge = answering([{ kind: 'stored' }])
    expect(await mintSubscriptionToken(unwatched, bridge)).toBeUndefined()
  })

  test('two calls, and neither of them is about a value', async () => {
    // Start it, then read what it says until it says it is done. The token is
    // minted and stored on the far side of this, which is why there is no third
    // call and no field on either of these two.
    const bridge = answering([{ kind: 'authorize', url: SIGN_IN_AT }, { kind: 'stored' }])
    await mintSubscriptionToken(unwatched, bridge)
    expect(bridge.asked).toEqual([
      'mint-subscription-token',
      'next-mint-event',
      'next-mint-event',
    ])
  })

  test('nothing said yet is a working mint, not a failed one', async () => {
    // Most of a mint is a person signing in to a website. A `null` event is
    // that, and treating it as an end would fail every real sign-in.
    const bridge = answering([null, null, { kind: 'stored' }])
    await mintSubscriptionToken(unwatched, bridge)
    expect(bridge.asked.filter((kind) => kind === 'next-mint-event')).toHaveLength(3)
  })
})

describe('the URL is the one thing a running mint says', () => {
  test('it reaches the observer while the mint is still running', async () => {
    const seen: string[] = []
    const bridge = answering([{ kind: 'authorize', url: SIGN_IN_AT }, { kind: 'stored' }])
    await mintSubscriptionToken({ authorizing: (url) => seen.push(url) }, bridge)
    expect(seen).toEqual([SIGN_IN_AT])
  })

  test('a URL is a URL, and an https one', () => {
    /*
      The scheme is checked rather than assumed, because this string is handed
      to a person to open. A host that answered with something else — a path, a
      `file://`, a bare word — would be putting that in front of them under a
      sentence saying it is where to sign in.
    */
    expect(parseMintEvent({ kind: 'authorize', url: SIGN_IN_AT })).toEqual({
      kind: 'authorize',
      url: SIGN_IN_AT,
    })
    expect(parseMintEvent({ kind: 'authorize', url: 'file:///etc/passwd' })).toBeNull()
    expect(parseMintEvent({ kind: 'authorize', url: 'claude.com/authorize' })).toBeNull()
    expect(parseMintEvent({ kind: 'authorize' })).toBeNull()
    expect(parseMintEvent({ kind: 'authorize', url: 7 })).toBeNull()
  })

  test('an event is rebuilt, so nothing volunteered beside it comes through', () => {
    /*
      The same rule every answer on the bridge follows, and the reason it is
      worth restating for this one: the host reads the URL out of the same
      buffer the token is in. A field forwarded from here would reach machine
      context, and from there the surface and the Session mirror.
    */
    const event = parseMintEvent({
      kind: 'authorize',
      url: SIGN_IN_AT,
      token: LOOKS_LIKE_A_TOKEN,
    })
    expect(event).toEqual({ kind: 'authorize', url: SIGN_IN_AT })
    expect(JSON.stringify(event)).not.toContain('sk-')
  })

  test('an outcome carries nothing but its outcome', () => {
    expect(parseMintEvent({ kind: 'stored', token: LOOKS_LIKE_A_TOKEN })).toEqual({
      kind: 'stored',
    })
    expect(parseMintEvent({ kind: 'failed', failure: 'no-token' })).toEqual({
      kind: 'failed',
      failure: 'no-token',
    })
  })

  test('a line this build cannot read is not an event', () => {
    // Strict rather than forgiving: an unreadable event dropped as though it
    // were nothing would swallow the outcome, and the machine would sit in
    // `credential.minting` against a command that had already finished.
    expect(parseMintEvent(null)).toBeNull()
    expect(parseMintEvent({})).toBeNull()
    expect(parseMintEvent('stored')).toBeNull()
    expect(parseMintEvent({ kind: 'delta', text: 'hi' })).toBeNull()
  })
})

describe('every way of failing produces a sentence Core authored', () => {
  test('a failure the host named comes back as itself', async () => {
    for (const tag of ['no-command', 'no-terminal', 'no-workspace', 'already-minting'] as const) {
      expect(await failureOf(refusing(tag))).toBe(tag)
    }
  })

  test('a failure the flow reported comes back as itself', async () => {
    for (const tag of ['no-token', 'unreadable-token', 'store-refused', 'no-keychain'] as const) {
      expect(await failureOf(answering([{ kind: 'failed', failure: tag }]))).toBe(tag)
    }
  })

  test('no host at all — a browser tab cannot spawn a command', async () => {
    expect(await failureOf(null)).toBe('no-host')
  })

  test('a tag this build does not know is not repeated back', async () => {
    /*
      Deliberately not reported verbatim, and more deliberately here than
      anywhere else on this bridge: an unrecognised payload is exactly the
      payload nobody has checked for a secret, and the process on the other end
      of this call is the one holding a live credential.
    */
    expect(await failureOf(refusing('surprise'))).toBe('mint-failed')
    expect(await failureOf(refusing(LOOKS_LIKE_A_TOKEN))).toBe('mint-failed')
    expect(await failureOf(answering([{ kind: 'failed', failure: LOOKS_LIKE_A_TOKEN }]))).toBe(
      'mint-failed',
    )
  })

  test('a bridge that never reached the host is a failed mint, not a crash', async () => {
    const lost: HarnessBridge = {
      call: async () => {
        throw new HarnessUnavailable('runtime-lost')
      },
    }
    expect(await failureOf(lost)).toBe('mint-failed')
  })

  test('nothing the host said can reach a message', async () => {
    // Every tag is a `&'static str` chosen by a match arm in
    // src-tauri/src/mint.rs, so there is no `String` on that path for a value
    // to be formatted into. Asserted from this side anyway, over every way a
    // mint can fail, because this is the one call whose far end has a
    // credential in hand when it goes wrong.
    for (const tag of [...CREDENTIAL_MINT_FAILURES, LOOKS_LIKE_A_TOKEN]) {
      let message = ''
      try {
        await mintSubscriptionToken(unwatched, refusing(tag))
      } catch (error) {
        message = error instanceof Error ? error.message : String(error)
      }
      expect(message).not.toContain('sk-')
      expect(message.length).toBeGreaterThan(20)
    }
  })
})

describe('the ten failures are legible and distinct', () => {
  test('each names a different thing', () => {
    const messages = CREDENTIAL_MINT_FAILURES.map(credentialMintGuidance)
    expect(new Set(messages).size).toBe(CREDENTIAL_MINT_FAILURES.length)
  })

  test('every one of them leaves the developer with something to do', () => {
    /*
      A mint that will not work is one step longer, not a dead end: the terminal
      route it replaced is still there. So most of these name the command, and
      the two that do not — no subscription, no keychain — name the other way in
      instead of pretending this one can be retried into working.
      */
    for (const failure of CREDENTIAL_MINT_FAILURES) {
      const message = credentialMintGuidance(failure)
      const offersSomething =
        message.includes(SUBSCRIPTION_TOKEN_COMMAND) ||
        message.includes('API key') ||
        message.includes('CLAUDE_CODE_OAUTH_TOKEN') ||
        message.includes('try again') ||
        message.includes('tauri dev') ||
        message.includes('browser')
      expect(offersSomething).toBe(true)
    }
  })

  test('the error message is the guidance, so the machine records it verbatim', () => {
    expect(new CredentialNotMinted('no-token').message).toBe(credentialMintGuidance('no-token'))
  })

  test('the unreadable-token sentence says nothing was stored', () => {
    // The loud failure this whole path is built around. A developer who is told
    // it failed but not that the keychain is untouched will go looking for a
    // half-written item that does not exist.
    const message = credentialMintGuidance('unreadable-token')
    expect(message).toContain('nothing was stored')
  })
})
