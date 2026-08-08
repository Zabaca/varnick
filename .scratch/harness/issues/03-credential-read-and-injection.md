# Read the credential host-side and inject it

**Status:** ready-for-agent

**Realizes:** `credential.reading`, `credential.present`, `credential.absent`, `credential.rejected`

`readCredential` is a stub that returns `{ source: 'keychain' }`. This slice has Tauri read the credential in the host process — which is outside the sandbox by construction — and inject it into the agent subprocess as an environment variable. The agent authenticates and can never reach the keychain that holds it.

Three outcomes the machine already distinguishes and the implementation must keep distinct:

- read succeeded → `credential.present`
- read failed → `credential.absent` **with `credentialError` set**. "No credential" and "never tried" look the same without it, and the surface then has nothing to say. This was already fixed once in the UI; do not reintroduce it in the actor.
- the API refused a credential that exists → `credential.rejected`, reached by `CREDENTIAL_REJECTED` from whatever sees the 401

**Done when** a machine with nothing stored produces a legible first-run message naming what to do, and `#/states → no-credential` and `→ credential-rejected` render against the real actor unchanged.

**Refuses:** the credential never enters the transcript, a log line, or the Session mirror.

Covers stories 11, 12, 13, 14, 15.
