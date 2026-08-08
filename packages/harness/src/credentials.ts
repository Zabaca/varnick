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

import { HarnessUnavailable, callHarness, tauriHarnessBridge } from './bridge.ts'

/** Which store answered. Reportable — the value it held is not. */
export type CredentialSource = 'keychain' | 'env'

/**
 * What the credential turned out to be. Reportable, and not a setting.
 *
 * Decided by the host from what it resolved (ADR-0011), never declared by the
 * developer, and orthogonal to the source: either kind can come from either
 * store. It decides which variable the agent is spawned with, and whether there
 * is a plan for plan usage to be about.
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
 * Mirrored as `API_KEY_ENV_VAR`/`SUBSCRIPTION_ENV_VAR` in
 * src-tauri/src/credential.rs, and as `CREDENTIAL_ENV_VAR_NAMES` in ./agent.ts.
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
 * The one command that mints a subscription token.
 *
 * varnick does not read Claude Code's own credential store — ADR-0011 records
 * that as a boundary rather than a convenience, because the access token in it
 * expires in about an hour and consuming it would mean varnick implementing
 * OAuth refresh against an item another process is also writing. `claude
 * setup-token` mints a long-lived token for exactly this, and the developer
 * stores it beside the API key.
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
      // Both kinds, because a developer who pays for a subscription and is
      // told only about an API key is being asked to pay for the same work
      // twice. The subscription comes first for the same reason it wins in
      // `resolve()`. Neither line mentions an environment variable: those are
      // the escape hatch for CI, not the advice a fresh clone opens with.
      return (
        'nothing is stored. For a Claude subscription, run ' +
        `\`${SUBSCRIPTION_TOKEN_COMMAND}\` and paste the token into ` +
        `\`${CREDENTIAL_SETUP_COMMANDS.subscription}\`; for an Anthropic API key, ` +
        `paste it into \`${CREDENTIAL_SETUP_COMMANDS['api-key']}\`. Then try again.`
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
