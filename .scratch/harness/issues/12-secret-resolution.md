# 12 — Resolve secret names when the host runs built code

**What to build:** Code the agent wrote, referencing a secret by name, works when it runs — because the host substitutes the real value at the moment of execution, outside the agent's process. The agent that built the integration stayed blind to the value the whole time.

**Blocked by:** 10 (there must be a store and a name list first) — **and one open decision, below.**

**Status:** needs-info

**Realizes:** no state path.

**Why this is `needs-info` and not `ready-for-agent`.** Resolution happens at the moment the host runs Userspace code. In v1 nothing runs Userspace code: rendering Surfaces is deliberately out of scope (`PRODUCT.md` → v1 scope, and the spec's Out of Scope). So this ticket currently has no execution moment to hook into — the seam it needs does not exist yet, and building the resolver against a hypothetical one is how a seam gets designed wrong.

This was found by splitting ticket 10 in two: the store half is buildable today, the resolution half is not, and they had been hiding each other.

Three ways out, all yours to choose:

1. **Defer past v1.** Ship the store and the name list; resolution arrives with the first thing that runs Userspace code. Honest, and it leaves stories 18 partially unmet in v1.
2. **Bring a minimal execution path into v1** — enough of the Surface loader to run one Userspace module. That re-opens a scope decision already made deliberately, so it should be made deliberately again rather than drifted into.
3. **Resolve at a different moment** — for example when the host runs a script the agent wrote, with no Surface involved. This may be the honest v1 shape and is worth a sentence of thought before either of the others.

The related question in ticket 11 — whether the dev server can itself run inside the sandbox — touches the same seam and is worth answering alongside.

- [ ] The decision above is made and recorded before any code
- [ ] Resolution happens host-side at execution, never inside the agent's process
- [ ] An integration written by the agent works end to end
- [ ] No secret value reaches the transcript, a log, or the Session mirror

Covers story 18, and completes 17.
