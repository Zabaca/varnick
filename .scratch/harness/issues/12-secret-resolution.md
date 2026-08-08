# 12 — Resolve secret names when the host runs built code

**What to build:** Code the agent wrote, referencing a secret by name, works when it runs — because the host substitutes the real value at the moment of execution, outside the agent's process. The agent that built the integration stayed blind to the value the whole time.

**Blocked by:** 10 (the store and the name list), 14 (something that runs Userspace code).

**Status:** ready-for-agent

**Realizes:** no state path.

**The seam, decided.** Resolution happens at the moment the host runs Userspace code. Splitting ticket 10 exposed that v1 had no such moment — rendering Surfaces had been cut — so a store would ship with no consumer and ADR-0006 would be a claim rather than a demonstrated property. Resolving instead when the host runs a plain script, with no Surface involved, was considered and rejected: the loader is already modelled, already proven by `drive.ts`, and already the thing the product is for. A minimal execution path came back into v1 as ticket 14, and this ticket hooks into it.

The open question in ticket 11 — whether the dev server can itself run inside the sandbox — touches the same seam and is worth answering alongside.

- [ ] Resolution happens host-side at the moment a Userspace module runs, never inside the agent's process
- [ ] An integration written by the agent works end to end
- [ ] No secret value reaches the transcript, a log, or the Session mirror

Covers story 18, and completes 17.
