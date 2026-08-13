# 19 — A rename can fool the review band's Fence flag

**What to build:** the flag that tells a developer "this Worktree touches the
Fence, look closely" cannot be turned off by renaming a file.

`listPendingWorktrees` reads a branch's changed paths with `-z` but **without
`--no-renames`**. Git's rename detection then reports only the *destination* of a
rename, so a branch that moves `src-tauri/host.rs` to `notes/host.rs` shows one
changed path — `notes/host.rs` — and `touchesFence` answers `false`. The band
shows an ordinary Worktree.

This is the third appearance of one defect. Ticket 02 shipped the landing
predicate's CLI without `--no-renames` and review found it would let a branch
move `src-tauri/*` and `scripts/*` out of the protected tree unattended. Ticket
18 added the flag to the caller that merges, and its author noticed this third
site while working — a display flag rather than a gate, and out of that branch's
scope, so it is filed rather than folded in.

## Severity: lower than the other two, and not nothing

Nothing lands on this. `unattendedLanding` is what decides whether a branch may
merge without a human, and it has the flag. So a rename cannot land Fence.

What it can do is stop the flag appearing on the screen where a developer decides
how carefully to read a diff before merging it themselves. The flag exists
precisely because "this touches the code that decides what the agent may do" is
the one fact worth surfacing before a human merge — and a human merge is exactly
the path a Fence-touching branch is on. So the failure lands on the reader whose
attention the flag was built to direct.

`isFencePath`'s quoting gap (ticket 12) sits in the same module for the same
reason. Both are worth doing in one pass.

## The awkward part

`--no-renames` turns one rename into a delete plus an add, which is what makes
both sides visible. That is right for a gate. For a *listing*, it also changes
what a developer is shown — a branch that renamed forty files now reports eighty
changed paths, and the band's counts move.

So this is not purely "add the flag": decide whether the listing and the gate
want the same diff, or whether the flag should be computed from a
`--no-renames` diff while the counts stay as they are. The second is probably
right and is why this is a ticket rather than a one-line fix.

**Blocked by:** None. Best done with ticket 12, which is the same module and the
same class of defect.

**Status:** needs-triage

- [ ] A branch that renames a Fence path out of the Fence still raises the flag
- [ ] A branch that renames a file *into* a Fence path raises it too
- [ ] Whatever the listing shows a developer as changed-path counts is a deliberate decision, recorded
- [ ] A test covers the rename case for the flag, not only for the landing predicate

## Comments

Found by ticket 18's author while adding `--no-renames` to the landing gate, and
handed over rather than fixed in place — correctly, since the branch was already
a Fence change under review and this is a different module with a different
question in it.
