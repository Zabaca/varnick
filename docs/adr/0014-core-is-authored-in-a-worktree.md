# Core is authored in a Worktree, not a Clone

**Status:** accepted. Supersedes [ADR-0005](./0005-two-profiles-live-userspace-cloned-core.md).

## Context

[ADR-0005](./0005-two-profiles-live-userspace-cloned-core.md) built a **Clone**, an
**Escalation** queue and a host-initiated **Collect** on one premise: *"a linked
worktree stores a `.git` file pointing back into the parent repository, which is
inside the path the Core Profile's sandbox denies."*

That premise was measured and it is scoped wrong. A linked worktree needs three
things:

```
worktree/.git                    a file: "gitdir: <main>/.git/worktrees/<name>"
<main>/.git/worktrees/<name>/    HEAD, index, logs, refs, ORIG_HEAD — written every operation
<main>/.git/                     objects, config, packed-refs — reached via commondir "../.."
```

Every one of those is inside `/Users/.../varnick`, which the Sandbox names in
both `allowRead` and `allowWrite`, and `.git` is not in `denyWrite`. **Worktrees
work today.** The sentence in ADR-0005 was only ever true of the *Core Profile's*
policy, which denies the project root — and the Core Profile is what the Clone
existed to serve. It was a fact about a proposed policy read as a fact about git.

A second measurement removes the reason for the Core Profile itself. `denyWrite`
names absolute live-tree paths:

```
/Users/.../varnick/packages/core/**
/Users/.../varnick/packages/harness/**
/Users/.../varnick/src-tauri/**
```

A worktree sits at a different absolute path, so its `packages/core/**` matches
nothing. The agent already authors Core in a worktree under its ordinary
Profile, with no second Profile, no queue, and no bespoke extraction step.

## Decision

**One Profile.** The agent edits Userspace in the live clone and Core in a git
worktree. `git merge` on the host is the gate. **Clone**, **Escalation** and
**Collect** retire as terms and as work.

The worktree base is `.claude/worktrees/` — Claude Code's own default, which is
already inside the clone, already in `.gitignore`, and outside Vite's root
(`packages/core`), so it needs no watcher exclusion. Nothing is configured;
`EnterWorktree` and subagent worktree isolation work unmodified, which was the
point.

A **Preview** is a second varnick launched from a worktree so a Core change can
be run before it is merged. The agent asks for one through a `launch_preview`
Custom Tool; the host spawns it with `VARNICK_CLONE_ROOT` pointing at the
worktree.

## Why the gate needs nothing built

Landing a Core change means `git merge` or `git checkout` writing
`packages/core/**` **in the live tree**, and `denyWrite` refuses that. The agent
is stopped by the filesystem, not by a permission system that had to be designed,
staffed with states, and kept honest.

This is what makes the boundary a default rather than a policy. A developer who
wants their agent to merge its own Core changes deletes those entries from
`sandbox-policy.json` — the file already says *"Edit this file freely"* — and it
works. varnick ships a fence, not a bureaucracy.

## Consequences

**A Preview runs unconfined, and that is a real escalation path.** It has to:
it reads the Keychain to resolve a Credential, and the Keychain is under the
denied `$HOME`. So the chain is three steps — the agent edits `sandbox.ts` in a
worktree, calls `launch_preview`, and the host spawns a varnick whose fence the
agent wrote, whose own agent then runs under it. Nested Seatbelt profiles
intersect, but a Preview is not nested inside anything; it is spawned by the
host.

`launch_preview` therefore **prompts** when the worktree touches Fence code —
`packages/harness/**`, `src-tauri/**`, `sandbox-policy.baseline.json` — and
launches everything else without asking. One condition, on the same line
`denyWrite` already draws, rather than a general approval system. `packages/core/**`,
`vite.config.*` and `package.json` are Core but do not build the fence, and they
launch silently: a dialog that appears on every Core preview is a dialog you stop
reading by the second week, which is worse than no dialog.

**The prompt is a native macOS dialog from the Rust host.** Userspace renders in
the same window and the agent writes Userspace, so a Surface could draw a
convincing fake and train the developer to click through. Userspace cannot draw
a native dialog at all, which removes the class rather than mitigating it.

**The prompt shows hunks, not a rationale.** ADR-0005 found this and it survives
its own supersession: approving a request means approving a sentence the agent
wrote, and that sentence is exactly what prompt injection produces. Approving
hunks means reading bytes.

**The diff view is Core, not a Surface.** `CONTEXT.md` defines a Surface as
something built in Userspace, and the agent writes Userspace freely — an
agent-writable diff renderer can hide its own hunks, which is the same spoofing
class as the fake dialog with a worse consequence. It ships in Core, which means
the agent cannot build it: the first one is hand-written, and every later change
to it goes through the flow it enables.

**Core is excluded from hot-swap.** A change under `packages/core/**` triggers a
full page reload, never a module swap. ADR-0005 required an explicit restart
after a Core merge because hot-swapping the module that owns the Session loses
the conversation that asked for the change; that was a rule someone had to
remember, and this makes it mechanical. A full reload is safe here because the
Session is durable host-side and resumes from the mirror
([ADR-0009](./0009-resume-reads-the-mirror.md)).

**The Preview's agent is git-blind, and that is accepted for now.** Its
`allowRead` is the worktree; the worktree's `.git` is a file pointing at
`<clone>/.git/worktrees/<name>`, outside it. So inside a Preview there is no
`git status`, `git diff` or commit — it can edit, run and test. A Preview exists
to prove a change runs, and the outer agent, which has full git, is the one
authoring. If it bites, the fix is to give that instance `allowRead` on the clone
root rather than the worktree: still inside one tree, no machine-specific path in
the baseline, and none of what ticket 28 refused.

**A Preview needs its own port.** `packages/core/vite.config.ts` pins `1420` with
`strictPort: true`, and `src-tauri/tauri.conf.json` hardcodes
`devUrl: http://localhost:1420`. A second instance collides on both, so the port
must become an input threaded to `devUrl`.

**A Preview needs `bun install`.** Git does not track `node_modules`, so a fresh
worktree has none. That runs `postinstall` from unmerged code — and
`packages/userspace/package.json` is deliberately writable
([ADR-0002](./0002-core-userspace-boundary.md)). This is not a new hole: launching
a Preview at all means executing the agent's application code unconfined in the
webview and the Tauri host, which is the same decision one step earlier. It is
recorded rather than ticketed.

**A Preview cannot be launched from inside the Sandbox**, which is why the
Custom Tool exists. srt gates mach lookups by service name and varnick's policy
exposes no such field, so `com.apple.windowserver.active` is unreachable and no
GUI window can open from a confined process. The agent can ask the host; it can
never do it itself.

**`launch_preview` must take a worktree name, never a command.** It is a
host-side process spawn driven by agent input, which is a shell out of the
Sandbox if it is shaped carelessly. The name is validated against the worktrees
git itself reports.

## What this does not license

**Fence code is still denied in the live tree.** The generator, the host, the
policy and its baseline stay on `denyWrite` for
[ADR-0002](./0002-core-userspace-boundary.md)'s reason, which supersession does
not touch: an agent that can write them widens its own boundary on the next
launch, and every other entry becomes advisory.

**Nested sandboxes intersect — and that is asserted, not assumed.** The claim
that a confined agent cannot grant a child more than it has is load-bearing for
`enableWeakerNestedSandbox: false`, and it is currently reasoning about Seatbelt
semantics rather than a measurement. It belongs with the containment probes.
