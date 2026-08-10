# 59 — The review surface cannot see a branch committed in the live tree

**What to build:** A branch the agent committed without a Worktree appears in the review list beside the ones that used one.

**Blocked by:** 55 — the list has to refresh itself before adding a second source of rows to it.

**Status:** ready-for-agent

**Realizes:** no new state path. The existing `review.listed` gains a second kind of entry.

## The gap

`listPendingWorktrees` reads `git worktree list --porcelain`
(`packages/harness/src/worktrees.ts:149`) and derives every row from a worktree
block. A branch with commits on it and no worktree attached produces no block,
so it produces no row.

That is not a rare case. It is what the agent does by default for anything
outside the deny list.

Measured, on the change that found this: asked to remove the caveman plugin, the
agent ran `git checkout -b remove-caveman-plugin` in the **live tree**, deleted
`.claude/plugins/caveman`, and committed. It was entitled to — `.claude/**` is
not denied, so no Worktree was needed and asking for one would have been
ceremony. The commit was correct, the message was good, and the window showed
nothing at all. The developer found out by running `git branch --show-current`
in a different terminal.

## Why this is the common path, not the exception

[ADR-0014](../../../docs/adr/0014-core-is-authored-in-a-worktree.md) sends the
agent to a Worktree because `denyWrite` names absolute live-tree paths and Core
cannot be written where it is. Everything the deny list does *not* name — every
Surface, every skill, every doc, every ticket in `.scratch/` — the agent writes
in place. That is the Userspace half of ADR-0002 working exactly as designed.

So the review surface was built against the smaller half. **Core changes are
visible; Userspace changes are not**, which is the wrong way round for how often
each happens.

## The live tree's own HEAD moves, and nothing says so

A second, sharper consequence of the same measurement: after that commit the
developer's checkout was on `remove-caveman-plugin` rather than `main`, and
neither the window nor the shell prompt said so. The next thing anyone runs —
a build, a test, another agent — runs against a branch nobody chose to be on.

This is ticket 57's family of problem (varnick not knowing what it is running)
but it is not the same fact, and 57's launch-commit comparison will not catch
it: the launch commit and `HEAD` can agree perfectly while the *branch* has
changed underneath. Whichever ticket lands second should reuse the other's
trigger rather than adding a third git read.

## The shape of the answer

The list's question is currently "which worktrees have commits". The question it
should answer is **"what has the agent committed that is not on `main` yet"**,
and a worktree is one way for that to be true rather than the definition of it.

`git for-each-ref refs/heads` with the same `rev-list --count main..<ref>` filter
already used at `:269` finds both kinds. A row then carries whether a worktree is
attached, because the two need different things at merge time:

- **worktree attached** — ticket 56's cleanup applies in full: stop the Preview,
  get the agent out, remove the directory, delete the branch.
- **no worktree** — there is nothing to stop and nothing to remove, but there is
  something 56 never has to think about: **the live tree may be checked out on
  the branch being merged.** Merging `main` into itself from that position is not
  a merge, and the sequence has to switch to `main` first.

The diff and the Fence-hunk rendering (ticket 50) need no change — both already
work off two refs, not off a directory.

## The filter is deletion, because no content predicate survives a squash

`rev-list --count main..<ref>` alone is not enough, and this repository already
proves it. Measured on the clone: **sixteen `ticket/NN-*` branches** are ahead of
`main` — between 1 and 46 commits each — and every one of them was landed months
of commits ago. `/ship` reaped their worktrees and left their branches. A naive
list would open with sixteen rows claiming pending work, above the one row that
is real.

Three candidate predicates, all of which fail on those sixteen:

- `merge-base --is-ancestor` — fails by construction after a squash. Ticket 56
  already records this.
- `git diff main <branch>` empty — 56's content check, and it is right *there*,
  in the window just after a merge when `main` has not moved. Run it later and
  the diff is dominated by everything `main` gained since; the three sampled
  branches show 330-odd changed lines each, none of it theirs.
- `git cherry main <branch>` — marks patch-equivalent commits `-`. A squash is
  one commit that equals none of the originals, so `ticket/02-credential` reports
  `+` for work that is unambiguously in `main`.

So the answer is not a better query. **The branch being deleted at merge is what
makes the list correct**, and 56's cleanup already deletes it — that step stops
being hygiene and becomes the invariant this ticket depends on. Any branch ahead
of `main` that still exists is pending, because merging is the only thing that
removes one.

That inverts the order of work: 56 must delete branches before 59 can list them
honestly, which is a second reason 59 sits behind it rather than beside it. And
the sixteen existing branches are debris predating the rule — they need reaping
once, by hand, with the developer's say-so, before the list is switched on.

## Watch for

- **Do not push the agent into a Worktree for everything to make this go away.**
  The Worktree exists because the kernel refuses the write, and requiring one for
  a `.scratch/` markdown edit is the DX cost this project has repeatedly declined
  to pay.
- A branch with zero commits ahead of `main` is not pending and must not be a
  row. Same filter as the worktree path, for the same reason.
- `main` itself is never a row.
- **The sixteen `ticket/NN-*` branches must be gone before this ships**, or the
  list's first impression is sixteen lies. Reaping them is a separate, developer-
  approved step and not something this ticket's code should do at runtime.
- Nothing composed by the agent. Git's answer, host-side, same as the list and
  the diff.

- [ ] A branch committed in the live tree, with no worktree, appears in the list
- [ ] Each row says whether a worktree is attached
- [ ] A branch with no commits ahead of `main` produces no row
- [ ] Merging a row whose branch is the live tree's current HEAD switches to `main` first
- [ ] A row with no worktree skips the Preview-stop and directory-removal cleanup
- [ ] The developer is told when the live tree's branch has changed under them

Found by merging the agent's caveman-plugin removal by hand: it was committed,
correct and complete, and the review surface it was built for showed no sign of
it.

## What ticket 56 changed under this

56 landed the merge and the cleanup, and both are written against a *worktree*:
`MERGE_WORKTREE` carries `entry.path`, and the cleanup runs `git worktree remove`
on it. A row with no worktree — which is the whole of this ticket — has no path
to carry and nothing to remove.

The fifth criterion above already anticipated the cleanup half. The selector is
the part that is new: the event, the guard and `findPendingWorktree` all assume a
row is addressed by a directory, and a branch row is addressed by a ref. Ticket
64's cleanup work touches the same seam and should be read alongside this.

Worth doing in this ticket rather than deferring: a row that cannot be addressed
is a row whose merge control silently does nothing, and that is the failure mode
this surface has already had once.

