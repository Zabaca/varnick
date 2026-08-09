# Two Profiles: Userspace edits live, Core works in a Clone

**Status:** superseded by [ADR-0014](./0014-core-is-authored-in-a-worktree.md).

> The premise below — that a linked worktree cannot work under the Sandbox —
> is true only of the Core Profile's own policy, which denies the project root.
> Under the Userspace policy the whole of a worktree's git surface is inside the
> clone, which is readable and writable, so worktrees have always worked. And
> because `denyWrite` names absolute live-tree paths, a worktree's
> `packages/core/**` matches nothing — the agent authors Core there under its
> ordinary Profile. The Clone, the Escalation queue and Collect are retired.
>
> Two findings here survive and are carried into ADR-0014: that the **diff** is
> the load-bearing gate rather than the request, and that a Core change requires
> an explicit restart.

Userspace and Core need opposite containment. Userspace work is the product's main loop — you ask for a Surface and it appears — which requires the agent to edit the running application, so a disposable checkout is impossible there. Core work is rare, privileged, and dangerous to apply to a running app, which is exactly what a disposable checkout is for. varnick therefore ships two Profiles in one harness: the **Userspace Profile** edits the live clone with Core paths denied, and the **Core Profile** works in a **Clone** under a temp root whose branch reaches the project only through a host-initiated **Collect**.

The Userspace agent reaches the Core Profile by **Escalation** — a Custom Tool that queues a request and returns immediately, so the conversation continues while a human decides.

## Consequences

- **A Clone, not a worktree.** A linked worktree stores a `.git` file pointing back into the parent repository, which is inside the path the Core Profile's sandbox denies. `zbc` established this by hitting it.
- **Escalation is privilege escalation, so it is gated twice.** The Core Profile can rewrite the sandbox policy that confines the Userspace agent, which means any path from Userspace to Core is a path from confined to unconfined — and prompt injection in anything the Userspace agent reads can travel it. A human approves the request, and a human approves the resulting diff. The diff gate is the load-bearing one: approving a request means approving a rationale the agent wrote, which is the thing that may be injected. Changes to the sandbox policy and credential paths render visually distinct in that diff.
- **Collect is never agent-initiated.** The Core Profile cannot push into the live clone.
- **A merged Core change requires an explicit restart.** Hot-reloading the module that owns the Session while it is running loses the conversation that requested the change. The restart is cheap because the Session is durable host-side.
- **The harness gets a second customer immediately**, which is the fastest way to find out whether the Profile abstraction is right.
