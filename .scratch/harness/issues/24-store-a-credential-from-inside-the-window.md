# 24 — Store a credential from inside the window

**What to build:** A developer who launches varnick with nothing stored is shown a field, pastes a key or a subscription token, and is authenticated — without opening a terminal. Today the window tells them to run a `security` command somewhere else, which means a fresh clone cannot be made to work from inside the product it ships as.

**Blocked by:** 22.

**Realizes:** `credential.storing` — a new state, so it needs a card at `#/states` and a line in `CONTEXT.md`, both of which the build checks.

`CONTEXT.md` briefly documented that state, and `STORE_CREDENTIAL` beside it, before any of this existed — written while ADR-0011 was being recorded and caught during ticket 22's review. Both are out again. This ticket adds them, and the order matters for the reason CLAUDE.md gives: a state is named in exactly one place, the machines, and a domain doc that runs ahead of them is the same defect as one that lags.

**Status:** ready-for-human — built and green on all seven commands. The one
thing left is the same kind of measurement ticket 22 left: a human pasting a
real token into a real window and watching a real keychain item appear. See
"The measurement, and how to take it" at the foot of this file.

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

- [x] A fresh clone with an empty Keychain reaches `credential.present` without the developer leaving the window, for both kinds — `drive.ts`, "a pasted ${kind} enters storing" through "the kind that lands in context is the one the read resolved", run over both kinds
- [x] A write that fails returns to `absent` with a reason that names what to do, and never quotes what `security` said — `drive.ts` for the state, `credentials.test.ts` for the sentence, and `credential.rs` for the tag it is authored from
- [x] The value appears in no log, no error, no transcript, no mirror — asserted, not asserted-by-inspection
- [x] `credential.storing` has a card at `#/states`, a line in `CONTEXT.md`, and an entry in `HARNESS_STATE_PATHS`
- [x] The terminal instructions stay in `README.md` — the window is the easy path, not the only one, and CI has neither a window nor a Keychain

Relates to stories 11–15, and to ticket 02, which chose the credential path before there was a window to type into.

## Comments

### What was built, and where the seams are

`credential.absent` stopped being one red line telling a stranger to go and run
two `security` commands. It is the setup screen now: what varnick needs and why,
the two kinds as a deliberate choice with a sentence each about what the
difference costs the developer, a paste field, and — quieter, at the bottom —
a pointer to the terminal route that still works.

Four seams, and the shape of each was chosen so a test could not reach a real
keychain by forgetting something:

- **`store_credential(security, kind, value)` in `src-tauri/src/credential.rs`**
  takes a `Security` port with no default, the way `openSecretsStore` takes a
  `SecretsKeychain`. The read half's seam is `resolve`, which is pure because the
  precedence rule has no keychain in it; a write is nothing *but* the keychain,
  so the seam has to be the runner. Twelve `cargo test` cases run against a
  recorder.
- **`store_script` is pure**, so the command shape is asserted rather than
  trusted: eight tokens whatever the value was, ending at `-U`, with the only
  varying token being hex. That is what "no positional keychain" means as an
  assertion. The mechanism is `packages/harness/src/secrets.ts`'s, reused rather
  than reinvented — hex, `-X`, `-U`, driven into `security -i` over stdin, so
  nothing is ever in argv for `/bin/ps` to read.
- **`route_of("store-credential") == Some(Route::Host)`** is a unit test, for a
  reason sharper than the read's: forwarding a store to the Harness runtime
  would put a credential on a pipe to a second process.
- **`storeCredential(input, writer)` in `packages/harness/src/credentials.ts`**
  returns `Promise<void>`. There is no answer type, so there is no shape on the
  success path a value could come back in.

### Two things worth arguing with

**The bridge's module comment used to say "nothing secret, in either
direction", and that sentence is now false.** It has been rewritten rather than
quietly left: one request carries a value inbound, once, and what makes it
acceptable is not that it never happens but that it is one-way, answered in
Rust, and refused by `route_of` anywhere else. Anyone reviewing this should read
that paragraph and decide whether they agree, because it is the only claim in
the codebase this ticket weakened.

**`CHOOSE_CREDENTIAL_KIND` is a new event the ticket did not ask for.** The
setup screen offers the two kinds as a choice, and ADR-0001 makes the view a
pure function of `(snapshot, send)` — a radio selection living in a component's
`useState` would be part of this surface the states page could not park in. So
the selection is `context.storingKind`, changed by an event, and both controls
come from `can()`. The pasted *value* is the opposite and stays in component
state, cleared on send: it is the one string that must not survive the
interaction, and the machine holds no field for it.

### What is out of scope and still true

`credential.rejected` has no way to replace the credential from the window. A
developer whose stored key was refused can only "try again", which re-reads the
same bad key. The fix is the same field, offered from a second state, and it is
ticket 23's neighbour rather than this one's business — but it is a real gap and
naming it is better than leaving it to be discovered.

`claude setup-token` is named in the setup screen and never spawned. ADR-0003's
last consequence forbids a second Claude Code process, and whether varnick should
ever trigger it is a question for the developer rather than a thing to decide
here.

### The measurement, and how to take it

Not taken. It needs a real credential and a real keychain, and nothing an agent
can run substitutes for it — every test here runs against a supplied port
precisely so that no test can write to the developer's own store.

What a human runs, once, on a machine with **no** `varnick` keychain items:

```
security delete-generic-password -s varnick -a anthropic-api-key   # if present
security delete-generic-password -s varnick -a claude-oauth-token  # if present
bun tauri dev
```

What to look for, in order:

1. The window opens on the setup screen rather than on a red line. It names both
   kinds, with a subscription selected.
2. Paste an API key, press *store and continue*. The screen says it is storing,
   then the agent starts. `security find-generic-password -s varnick -a
   anthropic-api-key -w` prints the key back **verbatim, not as hex** — which is
   what `-X` buys, and the thing to check, because a value that came back hex
   would authenticate as nonsense.
3. `ps aux | grep add-generic-password` during the write shows nothing with the
   value in it. This is the assertion that has no unit-test equivalent.
4. Repeat with `claude setup-token` and the subscription choice. The item is
   `claude-oauth-token`, and the harness state's `credentialKind` reads
   `subscription`.
5. Deny the keychain prompt, or store into a locked keychain, and confirm the
   screen comes back with "The keychain refused to store it, and nothing was
   changed" — and that nothing anywhere on screen holds what was pasted.
