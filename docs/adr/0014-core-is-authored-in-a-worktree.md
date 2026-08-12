# Core is authored in a Worktree, not a Clone

**Status:** accepted. Supersedes [ADR-0005](./0005-two-profiles-live-userspace-cloned-core.md).
The three consequences below about the Preview dialog are superseded by
[ADR-0019](./0019-a-preview-is-confined-by-the-live-trees-policy.md) — a Preview
is confined by the live tree's policy, so there is nothing to approve and the
dialog is deleted. Everything else here stands, including the merge gate this
rests on — and [ADR-0023](./0023-a-second-door-rather-than-a-wider-one.md) is
what happens when the agent asks for that merge rather than performing it.
`denyWrite` is unchanged by it, which is why "the gate needs nothing built"
below is still the mechanism; the sentence that ADR revises is the one about
deleting entries from `sandbox-policy.json`, which is now the wrong way to get
what it offers.

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

*(Revised by [ADR-0023](./0023-a-second-door-rather-than-a-wider-one.md). That is
still a thing a developer may do and it is no longer the way to get what it
offers: varnick's own agent lands ordinary Core through `land_worktree`, where
the host performs the merge and the protected-path predicate decides. Deleting
the entries instead gives up the property this whole ADR rests on — that a Core
change exists as a branch and a diff before it exists as running code — because
a direct write to the live tree is on no branch and in no diff at all.)*

## Consequences

**A Preview runs unconfined, and that is a real escalation path.** *(Superseded
by [ADR-0019](./0019-a-preview-is-confined-by-the-live-trees-policy.md): a
Preview's agent is confined by the live tree's policy and its Credential is
injected by the parent host, so this chain no longer exists and the three
paragraphs below describe a dialog that has been deleted.)* It has to:
it reads the Keychain to resolve a Credential, and the Keychain is under the
denied `$HOME`. So the chain is three steps — the agent edits `sandbox.ts` in a
worktree, calls `launch_preview`, and the host spawns a varnick whose fence the
agent wrote, whose own agent then runs under it. A second profile established
from inside the Sandbox reaches nothing — measured, see *What this does not
license* — but a Preview is not nested inside anything; it is spawned by the
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

**The Preview's agent is git-blind, and that is accepted for now.** *(No longer
true, and by the route this paragraph names: under
[ADR-0019](./0019-a-preview-is-confined-by-the-live-trees-policy.md) a Preview's
`allowRead` is the live clone, so `<clone>/.git/worktrees/<name>` is inside it.)*
Its
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

**A confined agent cannot grant itself or a child more than it has — measured,
and not by intersection.** This said "nested sandboxes intersect" and marked
itself as reasoning about Seatbelt semantics rather than a result. Probe 11 in
`containment.probe.test.ts` is the result, and it keeps the conclusion while
replacing the reason. Darwin 25.5, srt 0.0.67, under the shipped policy, with a
second profile whose `(allow default)` grants the read under `$HOME` that the
outer policy denies:

```
                              no outer Sandbox (control)   inside the Sandbox
sandbox_compile_string        compiled                     compiled
sandbox_apply                 0                            -1, EPERM
read under $HOME              permitted                    denied
witness inside the clone      permitted -> denied          permitted -> permitted
/usr/bin/sandbox-exec         (n/a)                        exit 71, sandbox_apply: EPERM
```

**There is no intersection, because there is no second profile.** The kernel
refuses `sandbox_apply` outright inside any profile that restricts anything — a
narrower nested profile is refused exactly as a wider one is — so the outer
policy is not merged with a nested one, it is the only one there is.

The witness is what makes that readable rather than assumed. The nested profile
also denies a directory *inside the clone*, which the outer policy allows: it
stays permitted after the attempt, so nothing took effect, and the refused read
under `$HOME` is not a probe reporting a denial it never earned. The control is
the same call with no outer Sandbox, where `sandbox_apply` returns 0 and the
witness does change hands.

Both paths are measured, because ADR-0003 exists for the difference between
them: `libsandbox` linked into the agent's own process, and `/usr/bin/sandbox-exec`.
srt's own wrapping ends in that binary, so the second line is also the answer to
"what if the agent runs srt inside srt" — and it is where ADR-0003's `exit 71`
sentence comes from.

**One thing this does *not* support, which was believed on the way in.**
`enableWeakerNestedSandbox: false` is not held up by any of the above. srt passes
that option only in its `case 'linux'` branch, where it governs whether
bubblewrap mounts a fresh `/proc` under an unshared PID namespace in a Docker
container; the macOS branch never reads it. It stays `false` because every
weakening option is off, which is the reason `sandbox.test.ts` asserts, and not
because a nested profile would otherwise widen this one.
