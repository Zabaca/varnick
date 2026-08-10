# 69 — A Worktree that has landed never leaves the list

**What to build:** A Worktree whose work is already in the live tree says so, and
a control beside it clears the directory away.

**Blocked by:** None — can start immediately. Adjacent to ticket 64, which is
about a merge that clears up after itself; this is about the row that is left
when it could not.

**Status:** done

**Realizes:** at least one new state on the review region — a reap that is
running, and a reap that was refused because something is standing in the
directory. The exact paths are for whoever takes it.

## Measured

Four rows, on a window that has just merged one of them:

```
Pending Core changes   4 branches waiting for a human
worktree-agent-a369d835c0d52b1e9  ⚠ fence  1 commit · 6 files   merges cleanly
worktree-agent-a608573a378dbe096           1 commit · 5 files   merges cleanly
worktree-agent-a939af72237d83514           1 commit · 3 files   merges cleanly
worktree-the-window-a-developer-sits-in  ⚠ fence  6 commits · 10 files  merges cleanly
```

Every one of those four is already in `main`. `git diff main <branch>` is empty
for all of them. The merge worked; the list does not know.

**The listing asks the wrong question.** `commitsAhead` is
`rev-list --count HEAD..<ref>` — pure ancestry — and varnick merges by
squashing. A squash lands the content and creates a commit the branch has never
seen, so those commits are ancestors of nothing and the count stays where it
was. The row will sit there through every *look again* and every restart, for
the rest of the repository's life.

The right question is already in the codebase and is asked one module over.
`squashCarried` in `packages/harness/src/merge.ts` verifies a merge landed by
computing `merge-tree --write-tree HEAD <ref>` and comparing the tree it
produces against `HEAD^{tree}`: identical means merging again would change
nothing. Run by hand against the merge above:

```
produced tree  05a3879…
HEAD tree      05a3879…
```

`listPendingWorktrees` never asks it.

## Why a button and not just a filter

Dropping landed rows from the list would make the screen honest and leave four
directories on disk with nothing that mentions them. They are not free — each is
a full checkout — and nothing in the product would ever name them again.

So a landed Worktree stays on the list and changes what it offers: **not merge,
which would find nothing to commit, but reap.**

## Why the merge could not do it itself

Not the agent being stubborn. Measured on the merge above:

```
15516  claude (SDK)      cwd = the worktree
15515  bun agent.ts
94574  target/debug/varnick
```

The process standing in the directory is **varnick's own child**, and the merge
is requested from inside a Turn — so the agent host is alive *by definition* at
the moment the cwd probe runs. A merge asked mid-Turn is structurally
guaranteed to be refused its own cleanup. The host exits at the end of the Turn
and the directory frees itself, but by then nothing is asking again.

That makes a reap that can be asked *later* the missing half, whether a
developer presses it or the runtime does when the host exits.

## Why it must not force

Deleting a directory that is a live process's working directory is permitted by
the OS and is not survivable in the way it looks. Measured:

```
cwd at start:          …/victim
cwd after rm:          …/victim        ← still reports the deleted path
relative write threw:  ENOENT: no such file or directory, open 'relative.txt'
```

The process keeps a vnode reference, so it does not die and it does not notice.
`process.cwd()` goes on naming a directory that is gone while every relative
file operation fails with an error naming the *file* and never the cause. A
forced reap would not crash the agent; it would leave it running and lying about
where it is. And whatever was uncommitted in the checkout is gone — the branch
survives, the working copy does not.

So the refusal stays, and what is added is a way to come back to it.

## Watch for

- **Never reap what has not landed.** The content check is the whole safety
  argument for `worktree remove` plus `branch -D`, exactly as it already is for
  the merge's own cleanup. A reap offered on a branch holding unmerged work is
  the one bug in this ticket that costs somebody their work.
- The existing `cleanUp` in `merge.ts` already probes, removes, deletes the
  branch and reports holders by name. This should be that code reached a second
  way, not a second copy of it.
- `merge.ts` currently tells the developer *"nothing will clear it up on its
  own"* in its left-over sentence. That stops being true here, and a sentence
  that outlives its own truth is worse than one that was never written.
- A row that offers merge and a row that offers reap are different rows. The
  band's heading counts *branches waiting for a human*, and a landed directory
  is waiting for a different thing.
- Ticket 64 is the same territory approached from the merge side. Whoever takes
  either should read both; the reap wants to be one mechanism.

- [x] A Worktree whose content is in the live tree is listed as landed, not as
      mergeable — `landed` on the entry, and `mergeable` refuses one
- [x] A control on that row removes the directory and deletes the branch
- [x] A reap is refused, by name, when anything is standing in the directory
- [x] A reap is refused when the content has not landed, whatever the row says
- [x] The row leaves the list once the directory is gone — `reaped` re-lists
- [x] Nothing is killed and nothing is forced

Shipped in `e126423`. `worktreeReap` is a sixth region rather than states inside
`worktreeMerge`, because a developer is usually looking at both: the merge's
*you are running old code* is still true while the reap that clears up after it
happens a Turn later.

**Not verified in the running window.** varnick has not restarted onto this
build, so every claim above is from the test suite and `drive.ts` rather than
from a press. The four rows that prompted it are still on screen under the old
code.

One thing found on the way and fixed here rather than ticketed: the actor-wiring
check looped over a hand-kept `ACTOR_NAMES`, so a new actor could be declared,
wired and invisible to it — the same shape as the merge button that called a
default. It reads the machine's declared actors now, and caught this ticket's
own omission on its first run.

Found merging three agent branches from the window: the merge landed, the row
stayed, and pressing it again would have squashed a branch with nothing in it.
