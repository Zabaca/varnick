# 24 — Store a credential from inside the window

**What to build:** A developer who launches varnick with nothing stored is shown a field, pastes a key or a subscription token, and is authenticated — without opening a terminal. Today the window tells them to run a `security` command somewhere else, which means a fresh clone cannot be made to work from inside the product it ships as.

**Blocked by:** 22.

**Realizes:** `credential.storing` — a new state, so it needs a card at `#/states` and a line in `CONTEXT.md`, both of which the build checks.

**Status:** ready-for-agent

## What changes

`credential.absent` accepts `STORE_CREDENTIAL { kind, value }`, which enters `credential.storing`. The host writes the Keychain item for that kind and answers whether it worked; a success re-reads through the existing path and lands in `credential.present`, a failure returns to `absent` carrying the reason. The re-read matters: it means one code path establishes the credential whether it was stored a minute ago or a year ago, and a write that somehow produced an unreadable item is caught immediately rather than at the next launch.

The developer chooses which kind they are pasting. That is not a contradiction of ADR-0011 — the host still *resolves* the kind by what it finds, and this is only which item is being written.

## Watch for

- **The value goes in one direction and is never echoed.** The renderer sends it once; the host writes it and answers with a tag. Nothing returns the value, nothing logs it, nothing puts it in an error, and it does not reach the Session mirror. The existing structure — `Secret` with no `Serialize`, `&'static str` error tags, messages selected by enum — is the pattern to extend rather than work around.
- **Do not put the value in argv.** `security add-generic-password -w <value>` is visible to `ps` for every user on the machine. `packages/harness/src/secrets.ts` already solved this: hex-encode and drive `security` in interactive mode over stdin. Reuse that, do not reinvent it.
- **`security add-generic-password`'s keychain argument is positional.** A `-w VALUE` placed before it has twice caused an accidental write to the wrong keychain in this project's history. Pass `-w` with no value and write over stdin, and never name a keychain positionally.
- **No test may touch the developer's real Keychain.** The write needs the same seam the read has — a host interface a test supplies — so this stays structural rather than remembered.
- **Clear the value from renderer memory once it is sent**, and never bind it into a component's persisted state. It is the one string in Core that must not survive the interaction.
- The field is a control like any other: it exists because `snapshot.can({ type: 'STORE_CREDENTIAL', … })` says so, not because `credentialState === 'absent'`.

- [ ] A fresh clone with an empty Keychain reaches `credential.present` without the developer leaving the window, for both kinds
- [ ] A write that fails returns to `absent` with a reason that names what to do, and never quotes what `security` said
- [ ] The value appears in no log, no error, no transcript, no mirror — asserted, not asserted-by-inspection
- [ ] `credential.storing` has a card at `#/states`, a line in `CONTEXT.md`, and an entry in `HARNESS_STATE_PATHS`
- [ ] The terminal instructions stay in `README.md` — the window is the easy path, not the only one, and CI has neither a window nor a Keychain

Relates to stories 11–15, and to ticket 02, which chose the credential path before there was a window to type into.
