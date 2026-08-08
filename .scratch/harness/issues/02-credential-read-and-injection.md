# 02 — Read the credential host-side and inject it

**What to build:** A developer launches varnick and the agent authenticates without them exporting anything. The credential is read by the Tauri host — which is outside the sandbox by construction — and injected into the agent subprocess as an environment variable, so the agent can authenticate while being unable to reach the keychain that holds it. A fresh clone with nothing stored says what to do instead of failing obscurely.

**Blocked by:** None — can start immediately.

**Status:** ready-for-agent

**Realizes:** `credential.reading`, `credential.present`, `credential.absent`, `credential.rejected`

Three outcomes the machine already distinguishes, which the implementation must keep distinct rather than collapse.

- [x] A successful read reaches `credential.present`
- [x] A failed read reaches `credential.absent` **with the reason recorded** — without it "no credential" and "never tried" are the same state and the surface has nothing to say. This was fixed once in the view; it must not come back in the actor
- [ ] A credential that exists and is refused by the API reaches `credential.rejected`, driven by whatever sees the 401
- [x] A machine with nothing stored produces one legible first-run message naming the single thing to do
- [x] `#/states → no-credential` and `→ credential-rejected` render unchanged against the real actor
- [x] The credential never enters the transcript, a log line, or the Session mirror

Covers stories 11, 12, 13, 14, 15.

## Comments

**Implemented.** `packages/harness/src/credentials.ts` (the half Core can see),
`src-tauri/src/credential.rs` (the half that holds the value),
`readCredential` in `packages/core/src/actors/live.ts` is real and off
`LIVE_NOT_IMPLEMENTED`.

**The one criterion left open: `credential.rejected` has a classifier and no
caller.** `credentialRejection()` is the shared definition of what counts as a
refusal, tested, so the callers that will see a 401 cannot disagree about it.
Nothing in v1 calls the API yet — `runTurn` and `spawnAgent` are tickets 05 and
03 — so nothing emits `CREDENTIAL_REJECTED` outside the bare page's button.

There is also no route from a Session turn failure to the parent's
`CREDENTIAL_REJECTED`: the Session is a spawned child and does not send to its
parent, and adding that is a machine change, which belongs in stage 3 rather
than in an integration ticket. Ticket 05 will hit this. Left as a finding rather
than fixed here.

**Not compiled.** `cargo` is not installed in the agent environment, so
`cargo check` and `cargo test` were not run against `src-tauri/src/credential.rs`.
Its pure `resolve()` carries seven `cargo test` cases that have never been
executed.
