# 30 — A second root cannot actually run an agent

**What to build:** `VARNICK_CLONE_ROOT` pointing at a second clone produces a working agent. Today it produces a validated root, a correct Sandbox policy, a correct write boundary, its own Session mirror — and an agent that cannot start.

**Blocked by:** None.

**Status:** ready-for-agent

**Realizes:** no state path.

## What ticket 28 delivered, and where it stops

[ADR-0012](../../../docs/adr/0012-the-clone-root-is-an-input.md) made the root an input. Four subsystems name it correctly and the default is unchanged, so `bun tauri dev` in a checkout behaves exactly as before. What does not work is the case the change exists for.

**The agent cannot open the Agent SDK from a second root.** `agentSdkEntry()` resolves the SDK out of *the runtime's own installation*, which is the build root, and hands that absolute path to the confined process. But the policy reads back exactly the chosen clone out of the denied `$HOME` — so a second root under a home directory is handed a path it is not allowed to read, and fails with `Cannot find module` for a file that exists.

The implementer found this and deliberately did not paper over it. Adding the SDK's package store to `allowRead` would widen the boundary outside the clone *and* put an untokenized machine-specific path into the recorded baseline, producing false "you changed this" reports on every machine move. That refusal was right; it left the gap open rather than trading the boundary for it.

**The likely fix is to resolve the SDK from the chosen root rather than the runtime's.** The launch gate already refuses a root with no `packages/harness/src/agent.ts`, so a valid root is a varnick clone and has its own `node_modules`. Resolving from there means the path is inside the tree `allowRead` already names, and nothing about the boundary moves. Check this before building it: the resolution happens in the unsandboxed runtime, and `agentSdkEntry`'s own doc records that a *bare specifier* import from inside the Sandbox fails while an absolute path works — so the fix is about which absolute path, not about how it is imported.

## The second half, which is harder

**Surface discovery follows the build root, not the chosen one.** `import.meta.glob` is a Vite transform-time scan and cannot take a variable, so the window lists the build root's Surfaces while the agent writes into the chosen root's. For a second root that directly undercuts `CONTEXT.md`'s **Workspace** — "the environment a person builds around themselves inside their clone" — because what the agent builds is not what the window shows.

Closing it means a run-time Userspace loader, constrained by [ADR-0004](../../../docs/adr/0004-core-never-statically-imports-userspace.md): Core never statically imports Userspace, and a broken module must be a failed Surface rather than a dead app. That is a design question, not an edit, and it may deserve its own ticket once the SDK half is fixed.

## Watch for

- **Do not widen `allowRead` outside the clone to solve this.** That is the trade ticket 28 refused, and the baseline-drift consequence is the reason.
- The default root must stay exactly as it is. A fresh `bun tauri dev` in a checkout is the path everyone uses and it works today.
- Whatever ships, the measurement is a real agent answering a Turn from a second root — not a unit test on a resolved path.

- [ ] An agent starts and answers a Turn under a second `VARNICK_CLONE_ROOT`
- [ ] The Sandbox policy for that root is unchanged in shape, and `allowRead` still names only the clone
- [ ] The recorded baseline carries no machine-specific absolute path
- [ ] Surface discovery's limitation is either fixed or written where a developer using a second root will read it before being surprised by it

Found by ticket 28, which reported it rather than working around it.
