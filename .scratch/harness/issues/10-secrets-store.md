# 10 — Secrets Store with host-side resolution

**What to build:** A developer stores an API key the agent can never read. The agent writes code that references the secret by name, the host resolves names when it runs that code, and the integration works while the agent that built it stayed blind. Secrets can be added, renamed and removed without restarting varnick.

**Blocked by:** 01 (the policy is what keeps the agent out of the store).

**Status:** ready-for-agent

**Realizes:** no state path. The Secrets Store has no machine and no UI in v1 — it is a Harness capability the agent uses through the code it writes. Named here so the states-page consistency check does not read its absence as missed work.

[ADR-0006](../../../docs/adr/0006-agents-author-secret-use-never-hold-secrets.md). Egress substitution was considered and rejected: it requires owning a proxy, and clients that validate credential format locally break on a placeholder. Do not revisit without new evidence.

Storage mechanism is an open decision, carried from `PRODUCT.md`.

- [ ] Secrets can be stored, listed, renamed and removed without a restart
- [ ] The agent is told which **names** exist and never a value
- [ ] Resolution happens host-side at the moment built Userspace code runs, never inside the agent's process
- [ ] An integration written by the agent works end to end
- [ ] Grepping the transcript and the Session mirror for a stored test value finds nothing

Covers stories 16, 17, 18, 19, 20, 21.
