# ADR-0017 — The host performs the merge; a human still decides it

**Status:** accepted

**Context:** [ADR-0014](./0014-core-is-authored-in-a-worktree.md) makes the merge
the gate. [ADR-0002](./0002-core-userspace-boundary.md) is what the gate is made
of. [ADR-0003](./0003-containment-wraps-the-process-tree.md) bounds what may
replace this process image.

## The decision

**varnick merges a pending Worktree into the live tree, from a control in the
window, when a human clicks it.** Before this, the developer left the
application, found the branch, read the diff again in a terminal, and merged by
hand.

And **the renderer may ask this process to restart itself** — `restart-varnick`,
routed to the host, which tears down and replaces the image.

## Why this does not weaken ADR-0014

ADR-0014 rests on one sentence: *a Core change becomes running code only when a
human merges it and restarts.* It is worth being precise about which word is
load-bearing, because it is easy to read as *manually*.

It is **a human**. The gate is a person deciding, having seen the change. The
gate is not the terminal, and it was never the awkwardness.

What actually prevents the agent from merging is not that merging is hard. It is
that `git merge` writes `packages/core/**` in the live tree and the kernel
refuses — the deny list, ADR-0002. That is unchanged here and cannot be changed
from inside: the fence, the policy and the baseline are all on the deny list for
the same reason the code is.

So the question this ADR has to answer is narrower than "may varnick merge": it
is **can anything the agent says cause this call**. Three things say no, and they
are independent:

- **The control lives in Core.** It is `packages/core/**`, which the agent cannot
  write in the live tree. A Surface cannot draw it — a Surface is Userspace, and
  Userspace has no route to a Harness event.
- **The agent has no way to send an event to the renderer at all.** The control
  channel carries requests the agent makes of the host, and every kind on it is
  enumerated. There is no "dispatch" kind and adding one would be a Core edit.
- **The path is checked where git runs.** `mergeWorktree` compares the path
  against git's own listing in the runtime, so a merge cannot be pointed at a
  tree by anything that merely composed a name.

**And the diff is on screen.** The control sits under the hunks, and the machine
refuses a merge unless the open diff is *this* Worktree's — not merely that some
diff is open, which is a distinction that was wrong once and is now a guard with
an assertion behind it. Approving hunks means reading bytes; that is ADR-0014's
own rule about the Preview dialog, applied to the other end of the same flow.

**A gate a developer has to leave the application to pass is a gate they will
pass carelessly**, in a terminal, without the diff in front of them. Moving the
act into the window is not a relaxation of the gate. It is the first time the
gate has had the evidence beside it.

## Why the restart is here rather than in the runtime

`restart-varnick` is not a question, which is what makes it unlike every other
request on the bridge. It replaces *this* process image, so it can only be
answered by the process being replaced.

It matters for containment rather than for tidiness. The runtime and the agent
are this process's children; anything still alive when the image goes is
orphaned by it, which is precisely the process tree ADR-0003 exists to prevent.
So the teardown runs here, in order, before `app.restart()`.

The agent cannot ask for it either, by the same three arguments above.

## What was considered and rejected

**Let the agent merge, under an escalation.** This is ADR-0005's retired shape
and it stays retired. An escalation is a sentence the agent wrote asking for
permission, and a sentence the agent wrote is exactly what prompt injection
produces. ADR-0014 replaced it with a boundary that needs nothing built: landing
a change means writing the live tree, and the kernel refuses.

**A merge commit rather than a squash.** Rejected. A Worktree's history is a
working record — a first attempt, the fix, the message rewritten — worth having
while the branch exists and worth nothing afterwards. What the live branch should
carry is what changed and why, once.

The squash has a consequence worth recording because it caught us: **afterwards
the branch is not an ancestor of the live tree**, so `merge-base --is-ancestor`
answers *no* for every branch this ever merges, and it is not the check for "did
this land". Neither is `diff <live HEAD> <branch>`, which is empty only for a
fast-forward — for a clean merge the live tree carries both sides and the branch
carries one. What is asked is whether merging again would change anything.

**Reap the worktree on the lock.** Rejected, measured twice. A lock naming a dead
pid outlives the session that took it, and reaping on that killed a live agent. A
worktree with no lock is not empty either — a session that ended in a restart
leaves none behind while its agent is still standing in the directory. **The lock
is unreliable in both directions.** What decides is whether any process has the
directory as its working directory, which is a fact about the machine rather than
a file git happened to leave behind.

**Merge onto a dirty live tree.** Refused, always, with the paths named. A merge
over uncommitted work is how a change nobody knew about is lost, and varnick
cannot know what that work was.

## Consequences

**The window can now write the developer's repository.** That is new, and it is
the thing to be careful about: every future addition here should be read as
"could the agent cause this", and the answer has to come from the three arguments
above rather than from how the control looks.

**The review list must only list Worktrees.** It listed any linked worktree once,
which cost nothing while it was read-only — the worst case was a row nobody
wanted. A merge control beside every row made it expensive: squashing somebody's
own branch and deleting their directory is not a surprising row, it is losing
their work. The list is filtered by the same rule the provisioner uses.

**A restart is owed after every merge, and the agent has to be told.** Until it
happens the running varnick is the build from before the change, which is exactly
what an agent reasons itself out of: *it merged, therefore it is live.* So the
merge sends a Briefing — see `CONTEXT.md` — and because the next thing varnick
recommends is the restart that would swallow it, the Briefing is kept on disk
until it is delivered.
