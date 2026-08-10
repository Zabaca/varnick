# 56 — Merge from the window, and say whether it will go cleanly

**What to build:** A pending Worktree says whether it merges cleanly, and a developer who has read it can land it without leaving varnick.

**Blocked by:** 55 — a merge control on a panel that does not refresh itself would show a stale answer about a branch that has moved.

**Status:** ready-for-agent

**Realizes:** `worktreeMerge.merging`, `worktreeMerge.merged`, `worktreeMerge.mergeFailed`.

## Why this belongs in Core rather than in the agent

The merge is the gate. [ADR-0014](../../../docs/adr/0014-core-is-authored-in-a-worktree.md)
rests on it: a Core change becomes running code only when a human merges it, and
the reason the agent cannot is that `git merge` writes `packages/core/**` in the
live tree and the kernel refuses.

A button in Core does not weaken that. The **host** performs the merge, because
a human clicked, in a surface the agent cannot write. What it removes is the
context switch, not the decision — and a gate a developer has to leave the
application to pass is a gate they will pass carelessly, in a terminal, without
the diff in front of them.

## Mergeability is a fact, not a state

Compute it host-side with the listing and carry it on the entry, the way
`touchesFence` already is:

```
git merge-tree --write-tree <live HEAD> <branch>      exit 0 → clean
```

Three answers worth distinguishing, because they mean different things to a
developer:

- **fast-forward** — the branch already contains the live tree. Nothing is
  decided by merging; this is the case the skill tells the agent to produce.
- **clean merge** — no conflict, but a merge commit will be written.
- **conflicts** — with the file names, which are what makes it actionable.

## A conflict is not a merge to offer badly

**Do not offer to merge a conflicted branch, and do not build a conflict
resolver.** `.claude/skills/change-core/SKILL.md` already says whose job this
is: the agent merges `main` *down* into its worktree, where it may write and
where it has the context, and hands back a fast-forward.

So the conflicted state's copy is the instruction — name the files and say to
ask the agent to merge `main` down. The surface teaches the loop rather than
inviting the developer to hand-resolve someone else's branch.

## Watch for

- **Refuse to merge onto a dirty live tree.** A merge over uncommitted work is
  how a developer loses something varnick never knew about.
- **A merged Core change needs a restart**, and this is the moment to say so —
  Restart varnick is already on the View menu. A merge that silently leaves the
  running app on the old code is the ADR-0005 trap with a button on it.
- **Fence hunks are already rendered distinctly** (ticket 50). A merge control
  must not become a way to land them without having looked; put it with the
  diff, not on the summary row.
- The mergeability answer goes stale the moment either side moves. That is why
  this is blocked by 55.
- Nothing here may be composed by the agent. Same rule as the list and the
  diff: git's answer, host-side.

- [ ] Each entry says fast-forward, clean, or conflicted
- [ ] A conflicted entry names the files and offers no merge
- [ ] A conflicted entry says to ask the agent to merge `main` down
- [ ] A clean entry can be merged from the window, by the host
- [ ] A merge is refused when the live tree is dirty, with a reason
- [ ] After a merge, varnick says a restart is needed and offers it
- [ ] `worktreeMerge.mergeFailed` carries git's reason and offers a retry
- [ ] Every new state path is named in `CONTEXT.md` and has a card

Asked for while looking at the first real pending Worktree: *"could we introduce a merge button here? it should also check if it's cleanly mergeable and show that there is a conflict when there is, like github would."*
