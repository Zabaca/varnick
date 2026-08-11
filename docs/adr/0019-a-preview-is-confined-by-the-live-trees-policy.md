# ADR-0019 — A Preview is confined by the live tree's policy, and the approval dialog is deleted

**Status:** accepted. Supersedes the Preview dialog introduced by
[ADR-0014](./0014-core-is-authored-in-a-worktree.md); the rest of ADR-0014
stands.

**Context:** [ADR-0003](./0003-containment-wraps-the-process-tree.md) is what
confinement is made of. [ADR-0002](./0002-core-userspace-boundary.md) is the
write boundary. [ADR-0014](./0014-core-is-authored-in-a-worktree.md) is why a
**Preview** exists at all. [ADR-0012](./0012-the-clone-root-is-an-input.md) is
why the clone root travels as an argument, which is the shape this reuses.

## The problem

ADR-0014 recorded a real escalation and gated it:

> **A Preview runs unconfined, and that is a real escalation path.** […] the
> agent edits `sandbox.ts` in a worktree, calls `launch_preview`, and the host
> spawns a varnick whose fence the agent wrote, whose own agent then runs under
> it.

So `launch_preview` raised a native `NSAlert` for a **Worktree** touching
`packages/harness/**`, `src-tauri/**` or `sandbox-policy.baseline.json`, showing
the hunks, and launched only if the developer said so.

The gate is correct and its cost lands in exactly the wrong place. An unattended
run is a night of tickets authored in worktrees and proved by running them, and
the dialog fires precisely on the tickets that most need proving — the ones that
change confinement. A run that stops on those has stopped on its hardest work
while the developer is asleep.

The dialog is also expensive in a way that gets worse rather than better. It is
the only modal thing varnick draws, and everything behind it — `fenceHunks`, a
`read-fence-diff` call on the runtime channel, `HarnessRuntime::fence_diff`, an
AppKit accessory view, three `objc2` dependencies — existed to render a diff
nobody could act on except by saying yes or no.

## The decision

**A Preview is confined by the policy in force in the live tree, always.** The
parent host spawns it with two things in its environment:

- **`VARNICK_POLICY_ROOT`**, naming the parent's own clone. The Preview works in
  its Worktree — `VARNICK_CLONE_ROOT` is unchanged — and `establishSandbox`
  reads `<live>/sandbox-policy.json` rather than generating one from the
  Worktree's generator.
- **the Credential**, injected from what the parent already holds. That is the
  arrangement the primary agent has, so no new process comes to hold a secret,
  and `read_credential` does not open the Keychain in a varnick that was given
  one.

**The dialog is deleted rather than made skippable**, along with the decision
that raised it and the sentences the agent read back when a launch was declined.
A dialog that fires on nothing is worse than no dialog, because it teaches
everyone to dismiss the next one.

`launch_preview`'s input is unchanged: one Worktree name, checked against
`git worktree list`.

## Why the live tree's policy is the usable answer and not merely the strict one

A Worktree lives at `<live>/.claude/worktrees/<name>`, which is *inside* the live
clone. The live tree's policy names that clone in `allowRead` and `allowWrite`,
and its `denyWrite` entries are absolute live-tree paths — `<live>/packages/core/**`
and the rest — which a worktree's copies do not match. So the same policy that
fences the primary agent gives a Preview's agent exactly what it needs: write its
Worktree freely, including that Worktree's Core, and never write the live tree's.

`requirePolicyRoot` is what holds the containment true rather than assuming it: a
policy root that does not hold the clone root refuses, because its policy would
confine the agent to a tree it does not work in.

It also fixes something ADR-0014 accepted and did not like:

> **The Preview's agent is git-blind, and that is accepted for now.** Its
> `allowRead` is the worktree; the worktree's `.git` is a file pointing at
> `<clone>/.git/worktrees/<name>`, outside it.

Under the live tree's policy that indirection is inside the readable tree. The
fix ADR-0014 sketched — "give that instance `allowRead` on the clone root rather
than the worktree" — is what this decision produces as a consequence rather than
as a special case.

## What is measured, and what the measurement says

`containment.probe.test.ts` probe 11b runs three operations twice on the same
machine, in two real Sandboxes: once under the live tree's policy with the
Worktree as the clone root, which is what a Preview gets, and once under the
Worktree's own policy widened the way an agent that rewrote the generator would
widen it.

The second is a control for a *permission*, which is the unusual kind and the
necessary one here: without it, three refusals are equally consistent with a
probe that cannot write anything anywhere, and the whole claim is that the two
policies disagree.

| | live tree's policy | worktree's widened policy |
| --- | --- | --- |
| write inside the Worktree | permitted | permitted |
| write the live tree's `packages/harness` | refused | permitted |
| read a file under `$HOME`, outside both | refused | permitted |

Probe 11c covers the branch that would quietly hand the fence back: a policy root
with no policy raises rather than generating one, and writes nothing on the way
past. `ensureSandboxPolicy` generates what it cannot find, and the obvious
reading of "no policy there" is "make one" — from the generator in the tree being
previewed.

## What this does not close

**A Preview's host process is unconfined code the agent wrote**, and that is
unchanged. It is the Tauri host, the Vite dev server and the Harness runtime, all
running from the Worktree, and a confined process cannot open a window — `srt`
gates mach lookups by service name and varnick's policy names none, so
`com.apple.windowserver.active` is unreachable. That is why the host spawns a
Preview in the first place, and it is why the process tree cannot simply be
wrapped.

So the guarantee above is precisely this: **the parent host decides what the
Preview's environment says, and the parent host is running the code a human
merged.** The Preview's own `sandbox.ts` could disregard `VARNICK_POLICY_ROOT`,
because it is the code being previewed.

Recording that plainly matters more than the dialog did, because the dialog did
not close it either. The `NSAlert` fired on a *diff of Fence paths*; a Worktree
that changed only `packages/core/**` launched silently and its unconfined host
ran anyway. The dialog narrowed which unconfined code a developer saw before it
ran. It never made a Preview's host confined, and it was never the thing standing
between the agent and the machine — `denyWrite` is, and a Worktree becomes
running code only when a human merges it.

What this changes is the thing the dialog was actually about: whether the
*agent* inside a Preview — the thing with a model behind it and hours to spend —
gets a fence its predecessor wrote. It does not.

## What would have to become true to need a dialog again

One of these, and none of them is true today:

- **A Preview's process tree becomes confinable and is not confined.** If `srt`
  gains a mach-service allowlist, or varnick's window stops needing one, then
  wrapping the whole Preview in the live tree's policy becomes possible — and
  the moment it is possible, not doing it needs an argument. That is the fix,
  not a dialog.
- **Something other than the parent host decides a Preview's policy root.** A
  flag, a config file inside the clone, a field on the `launch_preview` request:
  any of those puts the answer somewhere the agent can write, and the fence is
  back inside the fence. The variable is set by the spawning process and read
  once, in `bridge.rs`, for this reason.
- **A Preview is spawned by something other than an agent varnick already
  trusts.** Today the request arrives on the agent host's stdout, from inside the
  Sandbox. If the renderer could ask — a Surface is Userspace and the agent
  writes it — then windows could be opened with nothing in the conversation to
  show for it. `route_of` has no entry for `launch-preview` and a test says so.
- **The Credential injected into a Preview stops being the same one the parent
  is using.** It is the parent's, unchanged, so a Preview can do nothing to an
  account that the agent that asked for it could not already do. A Preview
  minting or resolving its own would be a second holder of a secret and a
  different question.

## Consequences

**Previewing a Fence change proves less than previewing anything else, and says
so.** The `sandbox.ts` in the Worktree is not what confines the window it opened;
the tool description tells the agent this outright, so the observation "my change
had no effect here" is expected rather than a bug hunt. What a Preview proves
about a Fence change is that it builds, starts, and does not break the app.
Whether the policy it generates is *right* is `sandbox.test.ts`,
`fence.test.ts` and the containment probes, none of which need a window.

**`Fence` has two mechanisms keying off it now, not three.** The list in
`packages/harness/src/fence.ts` is unchanged and still lives once; the
pending-worktree list's flag and the diff view's highlighting still ask it. The
dialog was the third. Both survivors are about *reading* a change before a human
merges it, which is where the attention belongs.

**A Preview stops being a step in an escalation chain and becomes ordinary.** It
has no failure mode that needs a person, so `answer_preview` no longer consults
the Harness runtime at all — the fence diff was the one call it made, and it
failed closed because a broken git used to be able to open a hole. There is no
such step now.

**One deletion is not reversible by reflex.** `fenceHunks` filtered a patch to
Fence hunks without summarising it, and the argument for showing bytes rather
than a sentence — ADR-0005's, surviving its own supersession — is still right
wherever a person approves a change the agent authored. That argument now lives
in the diff view, which is Core, and which a human reads before merging.
