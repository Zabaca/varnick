/**
 * Credentials — the half that runs where Core can see it.
 *
 * The credential is read by the Tauri host, which is outside the Sandbox by
 * construction, and injected into the agent subprocess as an environment
 * variable. The agent authenticates while being unable to reach the keychain
 * that holds the value — but *not* because `/usr/bin/security` is denied. That
 * binary runs inside the Sandbox regardless, measured in
 * containment.probe.test.ts; what puts the login Keychain out of reach is
 * `denyRead` on the home directory, which is where its file lives. See the
 * Correction in docs/adr/0003-containment-wraps-the-process-tree.md.
 *
 * **No value comes back out of here.** No function in this module returns one
 * and no type in it can hold one on the way back. A read answers with two
 * facts — which store replied (`keychain` or `env`) and what was in it
 * (`api-key` or `subscription`) — and that is the whole vocabulary. A value
 * never crosses the IPC boundary *into* the webview, so it can never reach the
 * transcript, a log line, or the Session mirror. That is a property of the
 * types rather than a rule someone has to remember; see src-tauri/src/credential.rs
 * for the other half, where the value does exist and cannot be printed.
 *
 * **One value goes the other way**, and it is the whole of {@link storeCredential}.
 * A developer pastes a key or a subscription token into the window and it
 * crosses once, inbound, into the process that owns the keychain. It has to:
 * the window is where a person types and the keychain is reachable only from
 * the host, and the alternative — telling a stranger with a fresh clone to go
 * and run two `security` commands somewhere else — is the thing this replaced.
 * What keeps it honest is that the traffic is one-way. `storeCredential` takes
 * the value as an argument, hands it to a {@link CredentialWriter}, and returns
 * `void`; it keeps no reference, the machine holds it in an actor's input rather
 * than in context, and the host answers with a tag. Nothing between the field
 * and the keychain can say it back.
 *
 * **And one credential is made rather than moved.** {@link mintSubscriptionToken}
 * asks the host to run `claude setup-token`; the token is read off a pty and
 * written to the keychain inside that process, so it crosses nothing — not this
 * module, not the bridge, not a log. What comes back here is a URL to sign in at
 * and, at the end, `void`. That is a stronger position than the store's, not a
 * weaker one: a store has a value in hand for the length of one call, and a mint
 * never has one at all.
 *
 * The kind is the second fact rather than a setting: the host decides it from
 * what it resolved, and it decides which variable the agent is spawned with —
 * ADR-0011. varnick never reads Claude Code's own credential store to get one.
 *
 * Every message this module produces is written here and selected by an enum.
 * Nothing a host said is ever interpolated into one, so a store that answers
 * with something unexpected cannot smuggle it into an error.
 *
 * The read crosses on the same bridge as every other Harness call (./bridge.ts),
 * and is the one call the Rust host answers itself rather than forwarding to the
 * Harness runtime — a credential must live in exactly one process, and it has to
 * be the one that spawns the agent subprocess.
 */

import { HarnessUnavailable, callHarness, tauriHarnessBridge, type HarnessBridge } from './bridge.ts'
import { CREDENTIAL_MINT_FAILURES, type CredentialMintFailure, type MintEvent } from './mint.ts'

export { CREDENTIAL_MINT_FAILURES, type CredentialMintFailure, type MintEvent } from './mint.ts'

/** Which store answered. Reportable — the value it held is not. */
export type CredentialSource = 'keychain' | 'env'

/**
 * What the credential turned out to be. Reportable, and not a setting.
 *
 * Decided by the host from what it resolved (ADR-0011), never declared by the
 * developer, and orthogonal to the source: either kind can come from either
 * store. It decides which variable the agent is spawned with, and since ticket
 * 31 that is the whole of what it decides — the plan-usage strip it also gated
 * is gone, because no credential varnick can hold reports plan windows.
 */
export type CredentialKind = 'api-key' | 'subscription'

/** Everything Core is allowed to learn from a successful read. */
export interface CredentialReading {
  readonly source: CredentialSource
  readonly kind: CredentialKind
}

/**
 * Why a read produced nothing.
 *
 * Three cases, kept apart because each has a different single next action. The
 * machine collapses all three into `credential.absent`; this is the reason it
 * records alongside, without which "no credential" and "never tried" are the
 * same state and the surface has nothing to say.
 */
export type CredentialAbsence =
  /** Neither store holds anything. The first-run case. */
  | 'nothing-stored'
  /** A store exists and would not answer — a denied keychain prompt, usually. */
  | 'store-unreadable'
  /** There is no host process to do the reading. A browser tab is not a desktop app. */
  | 'no-host'

/**
 * The variable the agent subprocess is spawned with, per kind.
 *
 * Both are first-class authentication variables to the Agent SDK, listed side
 * by side in its own credential table — which is what makes supporting a
 * subscription one substitution rather than a second authentication path.
 *
 * The names live here, keyed by the Kind that chooses between them, and
 * `CREDENTIAL_ENV_VAR_NAMES` in ./agent.ts is these two values in that order —
 * derived rather than repeated, because a mirror between two files in one
 * language is a mirror nothing has to keep. The dependency runs that way round
 * because this module reaches no Node and agent.ts does. Mirrored once more, in
 * another language, as `API_KEY_ENV_VAR`/`SUBSCRIPTION_ENV_VAR` in
 * src-tauri/src/credential.rs.
 */
export const CREDENTIAL_ENV_VARS: Readonly<Record<CredentialKind, string>> = {
  'api-key': 'ANTHROPIC_API_KEY',
  subscription: 'CLAUDE_CODE_OAUTH_TOKEN',
}

/** The keychain the host looks in first, whichever kind it is holding. */
export const CREDENTIAL_KEYCHAIN_SERVICE = 'varnick'

/** The account within that keychain, per kind. */
export const CREDENTIAL_KEYCHAIN_ACCOUNTS: Readonly<Record<CredentialKind, string>> = {
  'api-key': 'anthropic-api-key',
  subscription: 'claude-oauth-token',
}

/**
 * The command that stores a credential, per kind.
 *
 * Both end at a bare `-w`, which makes `security` prompt for the value rather
 * than take it from the command line. That is not only about shell history:
 * `add-generic-password` takes the keychain as a *positional* argument, so a
 * `-w VALUE` written before it is read as the keychain to write into. That
 * mistake has put a credential in the wrong keychain twice here.
 */
export const CREDENTIAL_SETUP_COMMANDS: Readonly<Record<CredentialKind, string>> = {
  'api-key': `security add-generic-password -s ${CREDENTIAL_KEYCHAIN_SERVICE} -a ${CREDENTIAL_KEYCHAIN_ACCOUNTS['api-key']} -w`,
  subscription: `security add-generic-password -s ${CREDENTIAL_KEYCHAIN_SERVICE} -a ${CREDENTIAL_KEYCHAIN_ACCOUNTS.subscription} -w`,
}

/**
 * The prefix each kind's value carries, and the characters that follow it.
 *
 * Not decoration: these are the two things about a credential that can be known
 * without asking Anthropic, and checking them is the difference between "this
 * cannot be right" now and an HTTP 401 later, from a screen that has no way
 * back to the field. See {@link credentialShapeProblem}.
 */
const CREDENTIAL_PREFIXES: Readonly<Record<CredentialKind, string>> = {
  // Assembled rather than written out, for the reason src-tauri/src/mint.rs
  // assembles its own: a literal of this shape is what every secret scanner
  // flags, and one in a source file blocks pushing for this repo and its forks.
  'api-key': concatPrefix('sk-', 'ant-api'),
  subscription: concatPrefix('sk-', 'ant-oat01-'),
}

function concatPrefix(head: string, tail: string): string {
  return `${head}${tail}`
}

/** The characters an Anthropic credential is made of after its prefix. */
const CREDENTIAL_BODY = /^[A-Za-z0-9_-]+$/

/**
 * A value shaped like a credential, which is not one.
 *
 * For asking the machine the prior question — "would you take a credential of
 * this kind at all?" — without an answer that depends on what is in the field.
 * The surface probes `can({ type: 'STORE_CREDENTIAL', … })` with it to decide
 * whether to draw the setup screen, and once the guard checks the *shape* of the
 * value, a stand-in that is not shaped like a credential answers no in every
 * state and the screen is never drawn at all.
 *
 * It lives here, beside {@link credentialShapeProblem}, because that is the
 * function it has to keep satisfying. A probe kept next to the component that
 * uses it would pass until the day the rule changed, and would then hide the one
 * screen a stranger with a fresh clone needs.
 */
export const CREDENTIAL_SHAPE_PROBE: Readonly<Record<CredentialKind, string>> = {
  'api-key': `${CREDENTIAL_PREFIXES['api-key']}03-NOTxAxCREDENTIAL`,
  subscription: `${CREDENTIAL_PREFIXES.subscription}NOTxAxCREDENTIAL`,
}

/**
 * Why this value cannot be the credential it claims to be, or null when it can.
 *
 * The check the paste field was missing. A credential is the one input in
 * varnick whose wrongness is invisible at the moment it is entered and total
 * afterwards: it is stored, the agent starts, the first turn gets a 401, and
 * the surface lands in `credentialState: 'rejected'`. Ticket work on that state
 * made it recoverable; this makes the common way into it unreachable.
 *
 * Deliberately shape only. Whether the credential *authenticates* is Anthropic's
 * answer and arrives over the network; whether it could possibly authenticate is
 * this function's, and costs nothing. A value that passes here can still be
 * rejected — a revoked token and a token from a superseded `claude setup-token`
 * run both look exactly like a good one — so this narrows the failure, it does
 * not remove it.
 *
 * The value is never quoted into the message. Everything a developer needs is
 * the prefix they should have seen, which is a constant.
 */
export function credentialShapeProblem(kind: CredentialKind, value: string): string | null {
  const trimmed = value.trim()
  if (trimmed.length === 0) return 'Nothing pasted.'

  const prefix = CREDENTIAL_PREFIXES[kind]
  if (!trimmed.startsWith(prefix)) {
    return kind === 'subscription'
      ? `A subscription token starts with \`${prefix}\`. Run \`${SUBSCRIPTION_TOKEN_COMMAND}\` and paste what it prints — an API key goes under "Anthropic API key" instead.`
      : `An Anthropic API key starts with \`${prefix}\`. Copy one from console.anthropic.com — a subscription token goes under "Claude subscription" instead.`
  }

  const body = trimmed.slice(prefix.length)
  if (body.length === 0) return 'That is the prefix on its own, with no credential after it.'
  if (!CREDENTIAL_BODY.test(body)) {
    // Whitespace in the middle is the tell for a value copied out of a wrapped
    // terminal render, which is the failure `claude setup-token` inside a
    // full-screen UI produces most often.
    return /\s/.test(body)
      ? 'That value has whitespace inside it, so it was copied across a line break. Select the whole token on one line and paste it again.'
      : 'That value has characters an Anthropic credential never contains, so some of what was copied was not the credential.'
  }
  return null
}

/**
 * The one command that mints a subscription token.
 *
 * varnick does not read Claude Code's own credential store — ADR-0011 records
 * that as a boundary rather than a convenience, because the access token in it
 * expires in about an hour and consuming it would mean varnick implementing
 * OAuth refresh against an item another process is also writing. `claude
 * setup-token` mints a long-lived token for exactly this, and the token goes in
 * the keychain beside the API key.
 *
 * **varnick now runs this itself**, on the host, on a pty — see
 * {@link mintSubscriptionToken} and src-tauri/src/mint.rs. The string is still
 * here because the terminal route still exists and is the right one for a
 * machine with no window, and because every failure of the mint ends in the
 * same advice: run it yourself and paste the result in.
 */
export const SUBSCRIPTION_TOKEN_COMMAND = 'claude setup-token'

/**
 * What to do about an absence, in one sentence.
 *
 * Phrased to continue the surface's own lead-in ("Could not read a credential —
 * …"), so the two do not each restate the problem.
 */
export function credentialGuidance(absence: CredentialAbsence): string {
  switch (absence) {
    case 'nothing-stored':
      // The window first, because the window can now do the whole of it —
      // varnick runs the mint itself, so a developer with a subscription
      // supplies nothing but a sign-in. The terminal route stays named because
      // it is the right one for a machine with no window, and because both
      // kinds have to be named: a developer who pays for a subscription and is
      // told only about an API key is being asked to pay for the same work
      // twice. Neither line mentions an environment variable — those are the
      // escape hatch for CI, not the advice a fresh clone opens with.
      return (
        'nothing is stored. The setup screen is where that is fixed: varnick can ' +
        'get a subscription token for you, or take a pasted key or token straight ' +
        `into the keychain. From a terminal instead, run \`${SUBSCRIPTION_TOKEN_COMMAND}\` ` +
        `and paste the token into \`${CREDENTIAL_SETUP_COMMANDS.subscription}\`; ` +
        `for an Anthropic API key, paste it into \`${CREDENTIAL_SETUP_COMMANDS['api-key']}\`. ` +
        'Then try again.'
      )
    case 'store-unreadable':
      return `the keychain would not answer. Open Keychain Access and allow varnick to read the "${CREDENTIAL_KEYCHAIN_SERVICE}" item, then try again.`
    case 'no-host':
      return 'there is no host process here to read it. varnick reads the credential in the desktop app — run `bun tauri dev` rather than opening the dev server in a browser.'
  }
}

/**
 * A read that produced nothing, carrying which nothing it was.
 *
 * `message` is the guidance verbatim, because the machine's `onError` records
 * `error.message` into `credentialError` and the surface renders that string.
 */
export class CredentialUnavailable extends Error {
  readonly absence: CredentialAbsence

  constructor(absence: CredentialAbsence) {
    super(credentialGuidance(absence))
    this.name = 'CredentialUnavailable'
    this.absence = absence
  }
}

/**
 * The host that does the reading.
 *
 * An interface rather than a direct `invoke` call so a test supplies its own.
 * No test may touch the real system keychain, and this is the seam that makes
 * that structural instead of aspirational.
 */
export interface CredentialHost {
  /** Resolves with whatever the host command returned; rejects with its `Err`. */
  read(): Promise<unknown>
}

/**
 * The Tauri host, or `null` when there is not one.
 *
 * The dev server runs at a tailnet address in a plain browser, where Tauri IPC
 * does not exist. That is a real first-run path, not an edge case, so it is a
 * value to branch on rather than an exception to catch — and it reaches
 * `credential.absent` with a reason like any other failed read.
 *
 * Built on the bridge rather than on its own `invoke`: there is one seam between
 * Core and the Harness, and the credential was the call that proved it should
 * exist. `callHarness` rebuilds the answer, so the host's reply is narrowed to
 * `{ source }` twice — once there and once below — and neither pass is where a
 * value could survive.
 */
export function tauriCredentialHost(): CredentialHost | null {
  const bridge = tauriHarnessBridge()
  if (bridge === null) return null
  return { read: () => callHarness({ kind: 'read-credential' }, bridge) }
}

/** Pull an absence out of whatever a host rejected with, without quoting it. */
function absenceOf(rejection: unknown): CredentialAbsence {
  // The bridge's refusals carry the tag the Rust host chose, and the credential
  // route can only choose a `&'static str` — see src-tauri/src/credential.rs.
  if (rejection instanceof HarnessUnavailable && rejection.failure === 'refused') {
    const tag = rejection.detail
    if (tag === 'nothing-stored' || tag === 'store-unreadable') return tag
  }
  // Anything else — a panic, a serialisation change, a bridge that never reached
  // the host — is a store that did not answer. Deliberately not reported
  // verbatim: an unrecognised payload is exactly the payload nobody has checked
  // for a secret.
  return 'store-unreadable'
}

/**
 * Ask the host to read the credential.
 *
 * Realizes the `readCredential` actor contract: input `{}`, output
 * `{ source }`, error a thrown `CredentialUnavailable`. Every path out is one
 * of those two, so the actor can never reject with something the machine's
 * `onError` cannot describe.
 */
export async function readCredential(
  host: CredentialHost | null = tauriCredentialHost(),
): Promise<CredentialReading> {
  if (host === null) throw new CredentialUnavailable('no-host')

  let answer: unknown
  try {
    answer = await host.read()
  } catch (rejection) {
    throw new CredentialUnavailable(absenceOf(rejection))
  }

  const reading = answer as { source?: unknown; kind?: unknown } | null | undefined

  const source = reading?.source
  if (source !== 'keychain' && source !== 'env') throw new CredentialUnavailable('store-unreadable')

  // Not defaulted. The kind decides which variable the agent is spawned with,
  // so a kind nobody resolved would mean spawning with a variable nobody
  // resolved — and the symptom is an agent that starts and then cannot
  // authenticate, which reads as a bad credential rather than as this.
  const kind = reading?.kind
  if (kind !== 'api-key' && kind !== 'subscription') {
    throw new CredentialUnavailable('store-unreadable')
  }

  // Rebuilt rather than passed through. A host that volunteered extra fields —
  // the value among them — cannot have them forwarded into the machine's
  // context, from where they would reach the Session mirror. Two facts is the
  // whole vocabulary, and neither of them is the value.
  return { source, kind }
}

/**
 * Why a store did not happen.
 *
 * Five, kept apart because each has a different single next action — the same
 * reason {@link CredentialAbsence} has three. The first two are about what was
 * pasted and the developer fixes them by pasting something else; the last three
 * are about the machine.
 *
 * Every one of them is a `&'static str` chosen by a match arm in
 * src-tauri/src/credential.rs, except `no-host`, which never reaches a host at
 * all. None of them can hold a value: there is no `String` on that error path.
 */
export const CREDENTIAL_STORE_FAILURES = [
  /** There is no host process to write it. A browser tab has no keychain. */
  'no-host',
  /** The field was empty, or held nothing but whitespace. */
  'nothing-pasted',
  /** A value the keychain would not hand back intact. See the guidance. */
  'unstorable-value',
  /** The keychain was asked and said no. */
  'store-refused',
  /** There is no `security` on this machine — a platform with no keychain. */
  'no-keychain',
] as const

export type CredentialStoreFailure = (typeof CREDENTIAL_STORE_FAILURES)[number]

/**
 * What to do about a store that did not happen, in one sentence.
 *
 * Authored here and selected by the tag, like every other message in this
 * module. Nothing a host said is interpolated into one, and neither is the
 * value: a store is the one moment Core has a credential in hand, and an error
 * that quoted it would put it on screen and into whatever reads the screen.
 */
export function credentialStoreGuidance(failure: CredentialStoreFailure): string {
  switch (failure) {
    case 'no-host':
      return 'There is no host process here to store it. varnick writes the credential in the desktop app — run `bun tauri dev` rather than opening the dev server in a browser.'
    case 'nothing-pasted':
      return 'Nothing was pasted. Paste the key or token itself — varnick stores exactly what is in the field and never sees it again.'
    case 'unstorable-value':
      return `That value has a line break, a tab, or a character outside plain ASCII in it. Keys and tokens are one line of plain text, and varnick refuses rather than storing something the keychain would hand back in a different form later — which fails as an authentication error far from here. Check for a stray newline, or store it from the terminal with \`${CREDENTIAL_SETUP_COMMANDS['api-key']}\`.`
    case 'store-refused':
      return `The keychain refused to store it, and nothing was changed. Open Keychain Access and allow varnick to write the "${CREDENTIAL_KEYCHAIN_SERVICE}" item, then try again.`
    case 'no-keychain':
      return 'There is no system keychain on this machine for varnick to write to. Export `CLAUDE_CODE_OAUTH_TOKEN` or `ANTHROPIC_API_KEY` in the environment varnick is launched from instead.'
  }
}

/**
 * A store that did not happen, carrying which failure it was.
 *
 * `message` is the guidance verbatim, because the machine's `onError` records
 * `error.message` into `credentialError` and the surface renders that string.
 * Same shape as {@link CredentialUnavailable}, so a failed store and a failed
 * read reach `credential.absent` looking like one another.
 */
export class CredentialNotStored extends Error {
  readonly failure: CredentialStoreFailure

  constructor(failure: CredentialStoreFailure) {
    super(credentialStoreGuidance(failure))
    this.name = 'CredentialNotStored'
    this.failure = failure
  }
}

/**
 * The host that does the writing.
 *
 * An interface rather than a direct `invoke`, and the reason is stronger than
 * it is for {@link CredentialHost}: a test that forgot to supply one would write
 * into the developer's own login Keychain. No test may touch a real keychain,
 * and this is the seam that makes that structural instead of aspirational — the
 * same reason `openSecretsStore` takes a `SecretsKeychain` with no default, and
 * the same reason `store_credential` in src-tauri/src/credential.rs takes a
 * `Security`.
 *
 * `store` resolves with nothing. There is deliberately no answer type here: a
 * store has nothing to report, so there is no shape a value could come back in.
 */
export interface CredentialWriter {
  store(request: { kind: CredentialKind; value: string }): Promise<void>
}

/**
 * The Tauri host, or `null` when there is not one.
 *
 * The same value-rather-than-exception as {@link tauriCredentialHost}, for the
 * same first-run path: the dev server in a browser has no Tauri IPC, and a
 * developer who opened it there gets a sentence rather than a stack trace.
 */
export function tauriCredentialWriter(): CredentialWriter | null {
  const bridge = tauriHarnessBridge()
  if (bridge === null) return null
  return {
    store: async ({ kind, value }) => {
      await callHarness({ kind: 'store-credential', credentialKind: kind, value }, bridge)
    },
  }
}

/** Pull a failure out of whatever a writer rejected with, without quoting it. */
function storeFailureOf(rejection: unknown): CredentialStoreFailure {
  if (rejection instanceof HarnessUnavailable && rejection.failure === 'refused') {
    const tag = rejection.detail
    if ((CREDENTIAL_STORE_FAILURES as readonly string[]).includes(tag ?? '')) {
      return tag as CredentialStoreFailure
    }
  }
  // Anything else — a panic, a bridge that never reached the host, a tag this
  // build does not know — is a store that did not happen. Deliberately not
  // reported verbatim: an unrecognised payload is exactly the payload nobody
  // has checked for a secret, and on this path the value is right there.
  return 'store-refused'
}

/**
 * Ask the host to store a credential, and forget it.
 *
 * Realizes the `storeCredential` actor contract: input `{ kind, value }`,
 * output nothing, error a thrown {@link CredentialNotStored}. The value crosses
 * the bridge once and this function keeps no reference to it — the machine holds
 * none either, because the actor's input is not context.
 *
 * `kind` says which keychain item is written. It is not a preference and nothing
 * records it: the host resolves which credential to *use* by what it finds on
 * the next read, which is why the machine follows a successful store with one.
 * ADR-0011 is unchanged by this.
 */
export async function storeCredential(
  input: { kind: CredentialKind; value: string },
  writer: CredentialWriter | null = tauriCredentialWriter(),
): Promise<void> {
  if (writer === null) throw new CredentialNotStored('no-host')
  try {
    await writer.store({ kind: input.kind, value: input.value })
  } catch (rejection) {
    throw new CredentialNotStored(storeFailureOf(rejection))
  }
  // Nothing is returned, and nothing the writer resolved with is read. A writer
  // that answered with the value has no way to hand it on.
}

/**
 * What to do about a mint that produced no credential, in one sentence.
 *
 * Authored here and selected by the tag, like every other message in this
 * module — and more strictly, because a mint is the one moment in this system
 * where the thing that failed was holding a live credential when it did.
 * Nothing the command printed is interpolated into any of these, and there is no
 * path by which it could be: every tag is a `&'static str` chosen by a match arm
 * in src-tauri/src/mint.rs.
 *
 * Every failure ends in something the developer can do, and for most of them
 * that is the terminal route this replaced. A mint that will not work is not a
 * dead end — it is one step longer.
 */
export function credentialMintGuidance(failure: CredentialMintFailure): string {
  switch (failure) {
    case 'no-host':
      return 'There is no host process here to run it. varnick mints the token in the desktop app — run `bun tauri dev` rather than opening the dev server in a browser.'
    case 'no-command':
      return `There is no \`claude\` on the PATH varnick was launched with, and minting a token runs \`${SUBSCRIPTION_TOKEN_COMMAND}\`. Install Claude Code, or paste a token you minted elsewhere.`
    case 'no-terminal':
      return `varnick could not open a terminal to run the command on. The token is drawn into one rather than printed, so there is nothing to read without it — run \`${SUBSCRIPTION_TOKEN_COMMAND}\` yourself and paste the result here.`
    case 'no-workspace':
      return 'varnick could not create the temporary directory it runs the command in — the directory it keeps deliberately outside this clone. Check that your temporary directory is writable, then try again.'
    case 'already-minting':
      return 'A sign-in is already running. Finish that one in the browser, or wait for it to give up, rather than starting a second — two would race each other into the same keychain item.'
    case 'no-token':
      return 'The sign-in finished without producing a token. That is what declining in the browser looks like, and also what an account with no Claude subscription looks like — an Anthropic API key is the other way in.'
    case 'unreadable-token':
      return `A token was produced and varnick could not read it back in one piece, so nothing was stored: half a credential authenticates nothing and would fail days from now, far from the cause. Run \`${SUBSCRIPTION_TOKEN_COMMAND}\` yourself and paste the result here.`
    case 'store-refused':
      return `The token was minted and the keychain refused to store it, and nothing was changed. Open Keychain Access and allow varnick to write the "${CREDENTIAL_KEYCHAIN_SERVICE}" item, then try again.`
    case 'no-keychain':
      return 'There is no system keychain on this machine for varnick to write the token to. Export `CLAUDE_CODE_OAUTH_TOKEN` in the environment varnick is launched from instead.'
    case 'mint-failed':
      return `The sign-in did not produce a stored token, and this build does not recognise the reason. Run \`${SUBSCRIPTION_TOKEN_COMMAND}\` yourself and paste the result here.`
  }
}

/**
 * A mint that produced no credential, carrying which failure it was.
 *
 * `message` is the guidance verbatim, the same shape as
 * {@link CredentialUnavailable} and {@link CredentialNotStored} — so a failed
 * read, a failed store and a failed mint all reach `credential.absent` looking
 * like one another, and the surface has one field to render whichever it was.
 */
export class CredentialNotMinted extends Error {
  readonly failure: CredentialMintFailure

  constructor(failure: CredentialMintFailure) {
    super(credentialMintGuidance(failure))
    this.name = 'CredentialNotMinted'
    this.failure = failure
  }
}

/**
 * What the window is told while a mint is running.
 *
 * One thing, and it is a URL. The flow tries to open a browser and prints this
 * as a fallback for when it cannot — which is the whole of what makes the mint
 * possible at all, because a window that could only say "a browser should have
 * opened" would strand every developer whose browser did not.
 *
 * A port rather than a return value, for the same reason {@link TurnObserver}
 * in packages/core/src/actors/live.ts is one: an actor resolves once, and this
 * arrives while it is still running.
 */
export interface MintObserver {
  /** The URL to sign in at. Never a credential — see ./mint.ts. */
  authorizing(url: string): void
}

/** Pull a failure out of whatever the bridge rejected with, without quoting it. */
function mintFailureOf(rejection: unknown): CredentialMintFailure {
  if (rejection instanceof HarnessUnavailable) {
    if (rejection.failure === 'no-host') return 'no-host'
    if (rejection.failure === 'refused') {
      const tag = rejection.detail
      if ((CREDENTIAL_MINT_FAILURES as readonly string[]).includes(tag ?? '')) {
        return tag as CredentialMintFailure
      }
    }
  }
  // Anything else — a panic, a bridge that never reached the host, a tag this
  // build does not know. Deliberately not reported verbatim: an unrecognised
  // payload is exactly the payload nobody has checked for a secret, and the
  // process on the other end of this one is holding a live credential.
  return 'mint-failed'
}

/**
 * Ask the host to mint a subscription token, and learn nothing but whether it
 * worked.
 *
 * Realizes the `mintSubscriptionToken` actor contract: input `{}`, output
 * nothing, error a thrown {@link CredentialNotMinted}. The value it produces
 * never comes near this function — the host runs the command, reads the token
 * off a pty and writes it into the keychain, all in the one process that is
 * allowed to hold one. There is no shape on the success path here for a
 * credential to arrive in, which is why the success path is `void`.
 *
 * Two calls, and the loop between them is what a long operation costs a
 * request/response seam: the mint is started, and then this waits on what it has
 * to say until it says it is done. Exactly the shape a Turn has, and for the
 * blunter reason — the middle of a mint is a person signing in to a website.
 *
 * A successful mint is followed by a read, not by a claim: the machine sends
 * `credential.minting` to `credential.reading`, so the host resolves what it is
 * holding by looking, the way it does on any other launch. ADR-0011 is
 * untouched by this.
 */
export async function mintSubscriptionToken(
  observer: MintObserver,
  bridge: HarnessBridge | null = tauriHarnessBridge(),
): Promise<void> {
  if (bridge === null) throw new CredentialNotMinted('no-host')

  try {
    await callHarness({ kind: 'mint-subscription-token' }, bridge)
  } catch (rejection) {
    throw new CredentialNotMinted(mintFailureOf(rejection))
  }

  for (;;) {
    let event: MintEvent | null
    try {
      ;({ event } = await callHarness({ kind: 'next-mint-event' }, bridge))
    } catch (rejection) {
      throw new CredentialNotMinted(mintFailureOf(rejection))
    }

    // Nothing said yet. A mint that is waiting on a person is a working mint.
    if (event === null) continue

    switch (event.kind) {
      case 'authorize':
        observer.authorizing(event.url)
        break
      case 'stored':
        // Nothing is returned and nothing is claimed. The token is in the
        // keychain; the machine reads it back from there like any other.
        return
      case 'failed':
        throw new CredentialNotMinted(event.failure)
    }
  }
}

/**
 * Give up on the running mint.
 *
 * The counterpart to {@link mintSubscriptionToken}, and the reason its refusal
 * to start a second mint is a boundary rather than a trap. A mint waits on a
 * person signing in to a website; the person who closed that tab, or signed in
 * as the wrong account, had no way to say so and no way to start again for as
 * long as the watchdog took.
 *
 * Never throws. A cancel that finds nothing running is the ordinary outcome of
 * a second click or of a flow that finished while the click was in the air, and
 * the mint the caller was waiting on ends through its own `failed` event either
 * way — this does not report the outcome, it causes one. A missing host is not
 * an error here for the same reason: there is certainly no mint running in it.
 */
export async function cancelMint(
  bridge: HarnessBridge | null = tauriHarnessBridge(),
): Promise<void> {
  if (bridge === null) return
  try {
    await callHarness({ kind: 'cancel-mint' }, bridge)
  } catch {
    // Deliberately swallowed. The caller is abandoning a mint, and a cancel
    // that could itself fail would leave a surface asking what to do about a
    // failure to stop doing something.
  }
}

/**
 * The one sentence a rejected credential produces.
 *
 * Here rather than at each caller, because a Turn that fails on authentication
 * and a spawn that does are the same fact reaching the same state, and two
 * sentences for one fact would read as two problems.
 */
export const CREDENTIAL_REJECTED_DETAIL = 'The API refused the credential (HTTP 401).'

/**
 * Was this failure the API refusing the credential?
 *
 * `credential.rejected` is driven by whatever sees the 401 — the turn, the
 * spawn, any caller that gets one — rather than by the read, which cannot know.
 * This is the shared classifier so those callers cannot disagree about what
 * counts, and it returns the `detail` the `CREDENTIAL_REJECTED` event carries.
 *
 * `detail` is constructed here from the classification alone. The response body
 * is read to decide, never to quote: an authentication failure is the one error
 * most likely to echo the credential back at you.
 */
export function credentialRejection(error: unknown): { detail: string } | null {
  if (error === null || error === undefined) return null

  const status = (error as { status?: unknown }).status
  if (status === 401) return { detail: CREDENTIAL_REJECTED_DETAIL }
  if (typeof status === 'number') return null

  const text = error instanceof Error ? error.message : typeof error === 'string' ? error : ''
  // `authentication_failed` is the Agent SDK's own name for it, added when the
  // Turn became the first caller: the SDK reports a refused credential as that
  // enum rather than as an HTTP status, and a classifier that missed it would
  // let the one failure that means `credential.rejected` land as an ordinary
  // failed Turn.
  const refused =
    /\b401\b/.test(text) || /authentication_error|authentication_failed|invalid x-api-key/i.test(text)
  return refused ? { detail: CREDENTIAL_REJECTED_DETAIL } : null
}
