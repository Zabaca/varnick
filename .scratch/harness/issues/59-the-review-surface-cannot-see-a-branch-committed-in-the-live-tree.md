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

## Watch for

- **Do not push the agent into a Worktree for everything to make this go away.**
  The Worktree exists because the kernel refuses the write, and requiring one for
  a `.scratch/` markdown edit is the DX cost this project has repeatedly declined
  to pay.
- A branch with zero commits ahead of `main` is not pending and must not be a
  row. Same filter as the worktree path, for the same reason.
- `main` itself is never a row.
- Squash means the ancestry check still lies here exactly as it does in 56 —
  compare content (`git diff main <branch>` empty), not `merge-base
  --is-ancestor`.
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
