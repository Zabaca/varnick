# 10 — Store secrets the agent cannot read

**What to build:** A developer stores an API key. The agent is told the key's **name** and never its value, so it can write code that references the secret while being unable to read one. Secrets can be added, renamed and removed without restarting varnick.

**Blocked by:** 01 (the sandbox policy is what keeps the agent out of the store).

**Status:** ready-for-agent

**Realizes:** no state path. The Secrets Store has no machine and no UI in v1 — it is a Harness capability the agent reaches through the code it writes. Named here so the states-page consistency check does not read its absence as missed work.

Resolution — the half where the host substitutes a real value at run time — is ticket 12, and it is blocked on a decision rather than on code.

[ADR-0006](../../../docs/adr/0006-agents-author-secret-use-never-hold-secrets.md). Egress substitution was considered and rejected: it requires owning a proxy, and clients that validate credential format locally break on a placeholder. Do not revisit without new evidence.

Storage mechanism is an open decision, carried from `PRODUCT.md`. It is the same open decision as ticket 06 — what persists on disk and how. Answer it once, for both.

- [ ] Secrets can be stored, listed, renamed and removed without a restart
- [ ] The agent is given the list of **names** and never a value
- [ ] The store is unreadable from inside the sandbox, proven rather than assumed — **attempted, and disproved.** The proof is in `sandbox.boundary.test.ts` as an inverted assertion. Ticket 16 owns the choice of what to do about it; it cannot be met by Keychain storage under the current policy
- [ ] Grepping the transcript and the Session mirror for a stored test value finds nothing

Covers stories 16, 17, 19, 20, 21.

## Comments

**Merged with three of four criteria met.** The store, the CLI (`bun run secret
add|remove|list|rename`), and the redaction wiring are done and tested: 34 tests
on the exported surface, plus one that stores a value, puts it through a real
Session mirror over a real temporary filesystem, and reads every byte back
looking for it. It finds `[redacted]` and the name, never the value.

Values are written through `security -i` on **stdin**, never argv, because
`/bin/ps` is not denied and a value on a command line is a value the agent can
read out of the process table. The keychain handle is a required option with no
default, so a test cannot reach the developer's real keychain by forgetting an
argument — it does not typecheck.

**The third criterion is unmet and that is the important result of this ticket.**
See ticket 16. The agent that built this went looking for the proof, found the
opposite, did not weaken the policy to make the test pass, and left the
measurement behind as an assertion that will go red when it stops being true.
That is the right handling of a disproved assumption.

**Re-wired on merge.** This ticket wired the Secrets Store into
`packages/core/src/actors/live.ts`, which was correct when it started and stale
by the time it landed — ticket 15 moved the Session mirror out of the renderer
and into the Harness runtime. The wiring now lives in
`packages/harness/src/runtime.ts`, in the one process that has both a filesystem
and a keychain. Behaviour is unchanged: the store is reloaded before every save,
a failed reload keeps the last good snapshot, and a store that will not open at
all makes the save reject so `persistence.saveFailed` says so.
