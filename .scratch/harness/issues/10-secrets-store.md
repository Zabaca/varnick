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
- [ ] The store is unreadable from inside the sandbox, proven rather than assumed
- [ ] Grepping the transcript and the Session mirror for a stored test value finds nothing

Covers stories 16, 17, 19, 20, 21.
