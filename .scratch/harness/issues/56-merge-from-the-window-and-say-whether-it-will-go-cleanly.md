# 56 — Merge from the window, and say whether it will go cleanly

**What to build:** A pending Worktree says whether it merges cleanly, and a developer who has read it can land it without leaving varnick.

**Blocked by:** 55 — a merge control on a panel that does not refresh itself would show a stale answer about a branch that has moved.

**Status:** done — merged as `a315d18`. The unbuilt half is ticket 64.

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

## Squash, always

**One commit on `main` per branch.** `git merge --squash` then commit — never a
merge commit, never the branch's own history.

A worktree's history is a working record: an agent's first attempt, the fix, the
rebase, the commit message it rewrote when it dropped a duplicate. That is worth
having while the branch exists and worth nothing afterwards. What `main` should
carry is *what changed and why*, once, in a message a human approved.

**The squash has a consequence the cleanup step must know about.** After a
squash, the branch is **not** an ancestor of `main` — git has no record that the
content landed, because the commit is new. So the "is it safe to remove this
worktree" check cannot be `git merge-base --is-ancestor`, which is the obvious
one and which will answer *no* for every branch this feature ever merges.

Check the **content** instead: `git diff <main> <branch>` empty means the squash
carried everything. Found by doing it by hand — the ancestry check said the work
was unmerged seconds after it had been merged.

## Cleanup is part of the merge, not a chore afterwards

A merged branch that leaves a worktree behind is a row that stays in the list
saying something is pending when nothing is.

**Remove the worktree, delete the branch, and stop anything running out of it.**
A Preview launched from that worktree is a second varnick holding a port, a
webview and its own sandboxed agent, running code from a directory about to be
deleted. Stop it before removing, not after.

Two things measured while doing this by hand:

- **A stale lock blocks removal.** `git worktree list` showed `locked, lock
  reason: claude session … (pid 52236)` for a process that had been dead for an
  hour, and `worktree remove` refused. The cleanup must unlock a lock whose
  process is gone — and must **not** force past one whose process is alive,
  because that lock is the only signal that an agent is still working in there.
- **Stop the Preview the way varnick's own teardown expects.** SIGTERM to the
  app process runs ticket 35's teardown and takes the harness runtime and the
  sandboxed agent with it. SIGTERM to the launcher kills the CLI and orphans all
  three. Killing the wrong one leaves exactly the process tree ADR-0003 exists
  to prevent.

### Get the agent out before removing the directory

**Order matters, and it is the opposite of the obvious one.** `EnterWorktree` is
*session* state in Claude Code, not process state, and it survives a restart with
the resumed conversation. Remove the directory first and the session is left
naming a worktree that does not exist.

Measured, immediately after doing exactly this by hand: the directory was gone,
`git worktree list` showed only the live tree, and **both the runtime and the
agent process had the clone root as their cwd** — so commands still worked and
`git log main` still answered. What was wrong was only the agent's belief about
where it was standing, which it reported as *"every command I run here now
operates on dead state"*. That conclusion was wrong; the confusion behind it was
not.

Nothing broke, because the agent stopped and asked before acting. That is luck
and good manners, not a property of the design.

So the sequence is: stop any Preview, **tell the agent to leave the worktree**,
confirm it has, then remove. The notification below is not only courtesy — it is
load-bearing, and it has to arrive before the directory goes rather than after.

#### It is fatal, not confusing — measured the second time

The paragraph above understated this, and the correction is the reason to trust
the sequence rather than treat it as tidiness. Doing the same thing again, on a
worktree whose lock named a dead pid, **killed the agent outright**:

```
error: Claude Code returned an error result:
  Path ".../.claude/worktrees/plugin-hooks-can-run" does not exist
    at readMessages (…/@anthropic-ai/claude-agent-sdk/sdk.mjs)
```

The host exited. `target/debug/varnick` and the Node runtime stayed up and the
runtime went on writing the Session mirror, so a message typed afterwards was
recorded with nothing alive to answer it. From the window there was no agent and
no error — the same silence ticket 58 was about, one layer out.

Two things follow that the earlier measurement could not show:

- **A dead lock pid does not mean the session is finished with the worktree.**
  The lock is held by the `claude` process; the *host* outlives it and resumes.
  Reaping on "lock pid is dead" is the check that caused this, and it is not
  sufficient on its own.
- **And an absent lock does not mean the worktree is empty.** Measured on the
  next merge: `git worktree list` reported **no lock at all** — the session that
  took it had ended in a restart — while `lsof +D` showed a live `claude` whose
  **cwd was that directory**, parented to the running agent host. Removing it on
  the strength of "no lock" would have killed the agent exactly as the dead-pid
  check did.

  So the lock is unreliable in *both* directions: stale when the agent is gone,
  absent when the agent is there. **It is not the signal.** What is: whether any
  process has the directory as its working directory. `lsof +D <path>` answers
  it, and the answer is a fact about the machine rather than a file git happens
  to have left behind.
- **Removing the directory is not recoverable by the agent.** It cannot report
  the problem, ask, or step back to the clone root — the SDK treats the missing
  cwd as a terminal error before any of that. So "tell the agent to leave, then
  confirm" is not politeness, it is the only ordering that works, and the
  confirmation has to be a real acknowledgement rather than a message sent.

## The agent is told, because it is the author

When a merge lands, **send the agent a system message saying so.** It wrote the
branch; it is the only party in the conversation that does not otherwise find
out, and it will go on offering to preview a worktree that no longer exists.

Say what landed and in what shape: the branch name, that it was squashed, the
commit on `main`, that the worktree and branch are gone, and whether a restart
is still owed. That last one matters — until the restart, the agent is running
the code from *before* its own change, and an agent reasoning about a fix it
believes is live is worse off than one that knows it is not.

This is a report, not a command, and it belongs on the same footing as
`COMMANDS_REPORTED` and the compaction report: something the world did, which
the machine accepts wherever it is rather than declining.

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

- [x] Each entry says fast-forward, clean, or conflicted
- [x] A conflicted entry names the files and offers no merge
- [x] A conflicted entry says to ask the agent to merge `main` down
- [x] A clean entry can be merged from the window, by the host
- [x] A merge is refused when the live tree is dirty, with a reason
- [x] After a merge, varnick says a restart is needed and offers it
- [x] `worktreeMerge.mergeFailed` carries git's reason and offers a retry
- [ ] The agent acknowledges leaving the Worktree before the directory is removed
- [x] A worktree whose lock pid is dead is still not removed on that basis alone
- [x] A worktree with no lock is still not removed while a process has it as its cwd
- [x] An agent host that exits is reported in the window rather than leaving a
      live runtime accepting messages nothing will answer
- [x] Every new state path is named in `CONTEXT.md` and has a card

## What was built, and the one box left open

**The acknowledgement is not built, and what replaced it is stronger in one
direction and weaker in another.** The sequence this ticket asked for — tell the
agent to leave, confirm it has, then remove — was overtaken by the measurement
two sections up: the lock is not the signal, and *whether any process has the
directory as its cwd* is. That check is in, and it makes the dangerous half
impossible: a Worktree somebody is standing in is never removed, so the agent's
cwd is never pulled out from under it.

What is not in is the part that makes the directory actually go away in that
case. Today the merge lands, the worktree stays, and the report names the
processes holding it — a success with something left over, which the window says
and the agent is told. Reaping it still needs a human, or a second attempt after
they have stopped whatever was in there.

Doing it properly needs two things this ticket did not scope: a message *to* the
agent asking it to leave and a way to know that it has (the briefing channel
built here is one-way and deliberately carries reports rather than
instructions), and a "reap this merged worktree" action separate from the merge,
because by then the branch has landed and there is nothing left to merge. Both
are worth a ticket of their own rather than a corner of this one.

**They are ticket 64**, together with the second thing this ticket asked for and
did not build: *"stop anything running out of it"*. A Preview launched from the
Worktree holds it as a cwd, so a merge of a previewed Worktree always ends in the
left-over path. That omission was not written down here when it happened, which
is the part worth noticing — the section above named the acknowledgement gap and
was silent about this one, and a reader would have taken the silence for
completeness.

## Reviewed, and what the review found

Two rounds of two-axis review after the branch was written. Six findings, all
fixed on the branch; the two that matter are recorded here because both are the
same shape and it is a shape that will recur.

**A check that passed for the case somebody tried by hand.** The cleanup was
gated on `diff --quiet HEAD <ref>`, which is empty only for a *fast-forward* — a
`clean` merge is by definition one the live tree holds commits ahead of, so
afterwards HEAD carries both sides, the branch carries one, and the diff is never
empty. Every clean merge reported itself as not having landed and **nothing was
ever cleaned up.** The comment above it stated the opposite as a measurement, and
it was one: of a fast-forward, promoted to a rule. The fake git answered that
diff `ok()` and only ever drove the fast-forward path, so nothing failed.

**A crate that never compiled.** `packages/core/**` inside a Rust block comment
opens a nested comment — Rust nests them — and the closing marker shut that one
instead of the outer. It reported `unterminated block comment` about a comment
that is plainly terminated.

And one the review got wrong, worth recording so it is not re-raised: the claim
that the cwd probe cannot see an agent between Turns. It can, and this ticket's
own second measurement says so — `lsof +D` catching a live `claude` whose cwd was
the directory is the finding the probe was chosen from.

The rest: the review list listed any linked worktree rather than only Worktrees,
which was free while it was read-only and expensive beside a merge control; the
Briefing was queued in memory and the restart this feature recommends would
swallow it; `leftOver` promised a reap nothing performs; `merged` and
`mergeFailed` did not re-list; the merge guard accepted any open diff rather than
this Worktree's; and the failure band carried no retry.

ADR-0017 records why a host-performed merge is not a hole in ADR-0014's gate.

**Box 11 was met from the other end than expected.** The exit *is* reported —
`await-agent-exit` and `agent.crashed` already did that, and the banner offers a
restart. What was missing was the second half of the sentence: the window went
on accepting messages, and each one was appended to the transcript and written
to the mirror with no process that had ever received it. `agentCanAnswer` is the
rule now, in `domain.ts` where `drive.ts` can reach it.

One thing found while building, worth carrying: `git merge-tree --write-tree`
**writes** — it puts the tree it computed into the object store as an
unreferenced object. No ref moves, no index is taken and no working tree
changes, so the merge a row describes still has not happened; but
`worktrees.ts` no longer claims that nothing it runs writes, and the claim it
makes instead is the narrower true one.

The Rust half is **unverified**: `cargo` is denied by the Sandbox, so the route
table, the `restart-varnick` arm and `report_merge` have not been compiled.

Asked for while looking at the first real pending Worktree: *"could we introduce a merge button here? it should also check if it's cleanly mergeable and show that there is a conflict when there is, like github would."*
