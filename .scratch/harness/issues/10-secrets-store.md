# Secrets Store with host-side resolution

**Status:** ready-for-agent

**Blocked by:** 01

**Realizes:** no state path. The Secrets Store has no machine and no UI in v1 — it is a Harness capability the agent uses through the code it writes. Named here so the states-page consistency check does not read its absence as missed work.

The agent authors code that names a secret and never holds one. The host resolves names at the point it runs the built code, never inside the agent's process. [ADR-0006](../../../docs/adr/0006-agents-author-secret-use-never-hold-secrets.md).

Scope:

- store, list, rename and remove secrets without restarting varnick
- the agent is told which **names** exist and no values
- resolution happens host-side when built Userspace code runs
- storage mechanism is an open decision, carried from `PRODUCT.md`

Egress substitution was considered and rejected: it requires owning a proxy, and clients that validate credential format locally break on a placeholder. Do not revisit without new evidence.

**Refuses:** no secret value in the transcript, in a log, or in the Session mirror — see ticket 06.

**Done when** an integration written by the agent works while the agent that wrote it never saw a value, and grepping the transcript and the mirror for a stored test value finds nothing.

Covers stories 16, 17, 18, 19, 20, 21.
