# 52 — The review list and the Preview dialog disagree about what is pending

**What to build:** One answer to "what has this Worktree changed", used by both the review list and the Preview dialog.

**Blocked by:** None — can start immediately.

**Status:** ready-for-agent

**Realizes:** no new state path. `review.listed` and `review.empty` change meaning.

## The disagreement, measured

Tickets 48 and 49 were written the same afternoon in different worktrees, and each chose a defensible base for "what changed". Nothing forced them to agree, and they do not.

- `listPendingWorktrees` (ticket 49) filters on `git rev-list --count HEAD..<ref>`. **Commits only.** A worktree with uncommitted work counts zero and is not listed at all.
- `fenceDiffOf` (ticket 48) takes `git diff <live HEAD>` inside the worktree, plus `ls-files --others`. **Committed, uncommitted and untracked.**

Measured against this repository while an agent was working in `.claude/worktrees/caveman-voice`, before it committed:

```
listPendingWorktrees(...)   → 0 entries
isFencePath over the diff   → 4 files under packages/harness/**
```

The agent had written four **Fence** files. The review list showed nothing. A Preview of the same worktree would have stopped and raised the dialog for work the list said did not exist.

## Which one is right

**The list.** "Invisible until someone types `git commit`" is exactly the failure the review surface exists to prevent — the developer asks what is waiting and is told nothing is, while four files that decide what the agent may do sit on disk. An agent that stops mid-task, or one that finishes and forgets, produces a worktree that is pending in every sense except the one being measured.

The Preview's base is the honest one and the list should adopt it: a Worktree with *any* difference from the live tree is pending.

## Watch for

- `review.empty` currently means "no worktree has commits". After this it means "no worktree differs", which is a wider claim and the copy should say the wider thing.
- Commits are still worth carrying as a *field* — "3 commits" and "uncommitted changes" are different sentences to a developer even when both are pending. Do not simply drop the count.
- A worktree that is pending only because of untracked files is the case most likely to be got wrong, and it is exactly the case ticket 48 called out: a fresh `packages/harness/src/widen.ts` that no `git diff` would show.
- One helper, two callers. A third reading of "what changed" is how this ticket happens again.

- [ ] A worktree with uncommitted changes and no commits appears in the review list
- [ ] A worktree with untracked files and nothing else appears in the review list
- [ ] An entry says whether it is pending by commits, by working-tree changes, or both
- [ ] The list and the Preview dialog are computed from one function, asserted directly
- [ ] `review.empty`'s copy claims what it now measures

Found by driving the loop rather than by a test: an agent wrote four Fence files and the surface built to show that showed nothing.
