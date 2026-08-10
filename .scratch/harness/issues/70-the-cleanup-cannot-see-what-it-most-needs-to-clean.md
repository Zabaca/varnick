# 70 — The cleanup cannot see what it most needs to clean

**What to build:** Every Worktree and every branch varnick left behind is visible
to the thing that clears them away, including the ones that are invisible today.

**Blocked by:** None. Ticket 69 shipped the button; this is the set of things the
button cannot reach.

**Status:** ready-for-agent

**Realizes:** no new state, most likely. The listing decides what a row is; this
is about which rows exist at all.

## Two blind spots, measured

### A Worktree merged by ancestry is invisible

Ticket 69 fixed rows whose ancestry *lies about having work* — a squash is
nobody's ancestor, so the count never falls. This is the same fault from the
other side: rows whose ancestry correctly says zero, and are dropped for it.

```
$ git merge --ff-only feature
after a fast-forward merge:
  commitsAhead (rev-list --count HEAD..feature) = 0
  worktree still on disk: yes
  git worktree list still shows it: 1
```

`listPendingWorktrees` does `if (commits === null) continue`, and `commitsAhead`
returns `null` at zero. So the directory is on disk, git knows about it, and the
review band will never draw a row for it — which means the reap can never be
asked for it either, because the reap resolves its path against the same
listing.

varnick always squashes, so this is not reachable through varnick's own merge.
It is reachable through the two things that actually happen: a developer merging
in a terminal, and an agent that merged `main` down and handed back a
fast-forward somebody then took.

**The rule the listing follows is wrong, not its arithmetic.** "Zero commits
ahead" currently means *an agent that has started rather than one that has
finished* — a real case worth excluding, and the reason the check is there. But
it now also swallows *an agent that finished and whose work went in*. Those are
opposite situations sharing one number, and telling them apart is what
`contentLanded` already does.

### 36 branch refs with no worktree

```
stale branch refs with no worktree: 36
  already in main, nothing to lose:  35
  still holding work:                 1
```

Every one is a `worktree-agent-*` from a session before ticket 69, when removing
a directory left its branch behind. They are cheap — a ref is a file with a hash
in it — but the count only goes up, and one of them is not cheap at all:

```
worktree-agent-aa0dc40e31d28d88c
  e781934 Give the agent a node, so a plugin's hooks can spawn
  packages/harness/src/agent.ts, packages/harness/src/agent.test.ts
  2026-08-09
```

That is real work that never landed, and nothing in the product mentions it. It
is indistinguishable from the other 35 without asking `merge-tree` about each,
which nothing does.

## What to build

**One question, asked of everything git knows about**, rather than of the subset
that passes an ancestry test:

- a Worktree whose content is in the live tree is a row offering a reap,
  *whether ancestry agrees or not*;
- a Worktree with commits the live tree does not have is a row offering a merge;
- a Worktree with nothing committed at all is an agent that has started, and is
  still left off — that case is real and is the reason the current check exists.

**And branches with no worktree are the same fact one step further along.** They
are not rows in a review band — there is nothing to review — but they are the
tail of the same leak, and the one holding unlanded work is the only thing in
this ticket that could cost somebody something.

## Watch for

- **Do not delete a ref because it is old.** The safety check is `contentLanded`
  and nothing else; 35 of the 36 pass it and one does not, and the one that does
  not is the interesting one.
- A branch that is *not* a Worktree's is a developer's own. `worktree-agent-*`
  is a name varnick chose, but matching on it is a heuristic — prefer what git
  reports about worktrees over what a ref is called.
- The band's heading already counts two things (`waiting for a human`, `already
  in, still on disk`). A third kind of row is a third count, or it is not a row.
- ADR-0014's gate applies to merging and not to this. Nothing here changes what
  the live tree contains.

- [ ] A Worktree merged by ancestry appears, and can be cleared away
- [ ] A Worktree with no commits at all is still left off the list
- [ ] Branches with no worktree are accounted for somewhere a developer sees
- [ ] The one holding unlanded work is distinguishable from the ones that are not
- [ ] Nothing is deleted on the strength of a name or an age

Found reviewing ticket 69 after clearing four Worktrees from the window: the
button worked, and then the question was what it still cannot reach.
