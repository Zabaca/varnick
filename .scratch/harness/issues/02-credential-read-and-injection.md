# 02 — Read the credential host-side and inject it

**What to build:** A developer launches varnick and the agent authenticates without them exporting anything. The credential is read by the Tauri host — which is outside the sandbox by construction — and injected into the agent subprocess as an environment variable, so the agent can authenticate while being unable to reach the keychain that holds it. A fresh clone with nothing stored says what to do instead of failing obscurely.

**Blocked by:** None — can start immediately.

**Status:** ready-for-agent

**Realizes:** `credential.reading`, `credential.present`, `credential.absent`, `credential.rejected`

Three outcomes the machine already distinguishes, which the implementation must keep distinct rather than collapse.

- [ ] A successful read reaches `credential.present`
- [ ] A failed read reaches `credential.absent` **with the reason recorded** — without it "no credential" and "never tried" are the same state and the surface has nothing to say. This was fixed once in the view; it must not come back in the actor
- [ ] A credential that exists and is refused by the API reaches `credential.rejected`, driven by whatever sees the 401
- [ ] A machine with nothing stored produces one legible first-run message naming the single thing to do
- [ ] `#/states → no-credential` and `→ credential-rejected` render unchanged against the real actor
- [ ] The credential never enters the transcript, a log line, or the Session mirror

Covers stories 11, 12, 13, 14, 15.
