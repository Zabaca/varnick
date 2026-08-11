/**
 * Minting a subscription token — the vocabulary, and nothing that runs.
 *
 * The mint itself happens entirely in the Rust host: it spawns
 * `claude setup-token` on a pty, reads the token out of what that renders, and
 * writes it into the keychain through the same path a pasted credential takes.
 * See src-tauri/src/mint.rs, and docs/adr/0003-containment-wraps-the-process-tree.md
 * for why that command runs on the host rather than inside `srt`.
 *
 * **Two things come back from it and neither is the token.** An authorize URL,
 * which is the OAuth request the developer's browser is about to make and is
 * shown as a fallback for a browser that did not open; and an outcome, which is
 * either "stored" or a tag. There is no shape in this module a credential could
 * travel in, and that is the whole reason the vocabulary lives here rather than
 * being read out of whatever the host said.
 *
 * Every sentence a developer reads about a mint is authored in ./credentials.ts
 * and selected by one of the tags below, exactly as the read and the store
 * failures are. Nothing the command printed is ever interpolated into one — a
 * mint is the one moment in this system where the thing that failed was holding
 * a credential when it did.
 *
 * Nothing here imports ./bridge.ts, which is what keeps this importable *from*
 * it. The call that runs a mint is `mintSubscriptionToken` in ./credentials.ts,
 * beside `storeCredential`, because a mint and a paste are two ways to fill the
 * same keychain item.
 */

/**
 * Why a mint produced no credential.
 *
 * Ten, kept apart because each has a different single next action — the same
 * reason `CredentialAbsence` has three and `CredentialStoreFailure` has five.
 * The first four are about this machine, the middle three about the flow, and
 * the last three about the keychain at the end of it.
 *
 * Every one except `no-host` and `mint-failed` is a `&'static str` chosen by a
 * match arm in the Rust host. None of them can hold a value: there is no
 * `String` on that error path for one to be formatted into.
 */
export const CREDENTIAL_MINT_FAILURES = [
  /** There is no host process to run it. A browser tab cannot spawn a command. */
  'no-host',
  /** There is no `claude` on the PATH varnick was launched with. */
  'no-command',
  /** The host could not allocate a terminal, and a pipe produces nothing. */
  'no-terminal',
  /** The host could not make the directory it runs the command in. */
  'no-workspace',
  /** One mint is already running. A second would race it into the same item. */
  'already-minting',
  /** The flow ended having printed no token — declined, or no subscription. */
  'no-token',
  /**
   * A token was printed and could not be read back whole.
   *
   * The loud failure this path is built around. What the command renders is a
   * terminal UI, so a change to how it draws that UI breaks the parse — and the
   * alternative to failing here is storing a truncated credential, which fails
   * as an authentication error days later with nothing pointing back at this.
   */
  'unreadable-token',
  /**
   * The same, and the token was left in a file for the developer to fetch.
   *
   * A separate tag rather than a field, because the two situations need
   * different sentences and a surface must never point at a file varnick failed
   * to write. See `leave_setup_key` in src-tauri/src/mint.rs for why the file is
   * under `$HOME` — the one place on the machine the confined agent cannot read
   * — and `store_credential` for when it is deleted.
   */
  'unreadable-token-saved',
  /** The keychain was asked to store it and said no. */
  'store-refused',
  /** There is no `security` on this machine — a platform with no keychain. */
  'no-keychain',
  /** It did not work, and the reason is not one this build knows. */
  'mint-failed',
] as const

export type CredentialMintFailure = (typeof CREDENTIAL_MINT_FAILURES)[number]

/**
 * Something the mint said while it was still running, or how it ended.
 *
 * A closed union, so there is no shape here a value could arrive in. `authorize`
 * is the only one that carries a string, and it is a URL: the parse that
 * produces it stops at whitespace and requires an OAuth authorize endpoint, and
 * `the_url_is_never_the_token` in src-tauri/src/mint.rs is what holds those two
 * apart at the place they are read out of the same buffer.
 */
export type MintEvent =
  | { readonly kind: 'authorize'; readonly url: string }
  | { readonly kind: 'stored' }
  | { readonly kind: 'failed'; readonly failure: CredentialMintFailure }

/**
 * Read one thing the mint said, or answer that it said nothing this build can
 * read.
 *
 * Rebuilt field by field like every other answer on the bridge. A host that
 * volunteered extra fields — the token among them — cannot have them forwarded
 * into a machine's context, from where they would reach the surface and the
 * Session mirror.
 *
 * A failure tag this build does not know becomes `mint-failed` rather than
 * being reported verbatim: an unrecognised payload is exactly the payload
 * nobody has checked for a secret, and on this path there is one in the room.
 */
export function parseMintEvent(value: unknown): MintEvent | null {
  const event = value as { kind?: unknown; url?: unknown; failure?: unknown } | null | undefined
  switch (event?.kind) {
    case 'authorize': {
      const url = event.url
      // `https://` and nothing else. A URL is the one string this event carries,
      // and a scheme the window would hand to a browser is not open to
      // negotiation — `file://` or a bare string would be a link to somewhere
      // varnick never meant to send anybody.
      if (typeof url !== 'string' || !url.startsWith('https://')) return null
      return { kind: 'authorize', url }
    }
    case 'stored':
      return { kind: 'stored' }
    case 'failed': {
      const failure = event.failure
      const known = (CREDENTIAL_MINT_FAILURES as readonly string[]).includes(
        typeof failure === 'string' ? failure : '',
      )
      return { kind: 'failed', failure: known ? (failure as CredentialMintFailure) : 'mint-failed' }
    }
    default:
      return null
  }
}
