/**
 * Credentials — the half that runs where Core can see it.
 *
 * The credential is read by the Tauri host, which is outside the Sandbox by
 * construction, and injected into the agent subprocess as an environment
 * variable. The agent authenticates while being unable to reach the keychain
 * that holds the value: `/usr/bin/security` is denied to it by denying read.
 * See docs/adr/0003-containment-wraps-the-process-tree.md.
 *
 * **The value is not representable here.** Nothing in this module has a field
 * that could hold it, and no function returns one. A read answers with which
 * store replied — `keychain` or `env` — and that is the whole vocabulary. The
 * value never crosses the IPC boundary into the webview, so it can never reach
 * the transcript, a log line, or the Session mirror. That is a property of the
 * types rather than a rule someone has to remember; see src-tauri/src/credential.rs
 * for the other half, where the value does exist and cannot be printed.
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

/** Everything Core is allowed to learn from a successful read. */
export interface CredentialReading {
  readonly source: CredentialSource
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

/** The variable the agent subprocess is spawned with. What the Agent SDK reads. */
export const CREDENTIAL_ENV_VAR = 'ANTHROPIC_API_KEY'

/** The keychain item the host looks for first. */
export const CREDENTIAL_KEYCHAIN_SERVICE = 'varnick'
export const CREDENTIAL_KEYCHAIN_ACCOUNT = 'anthropic-api-key'

/** The one command a fresh clone is told to run. */
export const CREDENTIAL_SETUP_COMMAND = `security add-generic-password -s ${CREDENTIAL_KEYCHAIN_SERVICE} -a ${CREDENTIAL_KEYCHAIN_ACCOUNT} -w`

/**
 * What to do about an absence, in one sentence.
 *
 * Phrased to continue the surface's own lead-in ("Could not read a credential —
 * …"), so the two do not each restate the problem.
 */
export function credentialGuidance(absence: CredentialAbsence): string {
  switch (absence) {
    case 'nothing-stored':
      return `nothing is stored. Run \`${CREDENTIAL_SETUP_COMMAND}\` and paste your key, then try again.`
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

  const source = (answer as { source?: unknown } | null | undefined)?.source
  if (source !== 'keychain' && source !== 'env') throw new CredentialUnavailable('store-unreadable')

  // Rebuilt rather than passed through. A host that volunteered extra fields —
  // the value among them — cannot have them forwarded into the machine's
  // context, from where they would reach the Session mirror.
  return { source }
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
