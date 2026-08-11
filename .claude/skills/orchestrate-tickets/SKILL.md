---
name: orchestrate-tickets
description: Work a whole ticket list unattended — author each ticket in its own worktree with a subagent, review it, fix what review finds, merge it, and cut a pre-release when the queue is empty. Use when asked to run a ticket list, work through a feature's issues, or do a night's work while the developer is away.
---

# Orchestrating a ticket list

You are the orchestrator. You do not write the tickets' code yourself — a
subagent does, one per ticket, each in its own Worktree. What you own is the
order the tickets run in, whether the work is good enough to land, resolving
what conflicts when it lands, and the report the developer reads in the morning.

Read [CONTEXT.md](../../../CONTEXT.md) before using any domain term.
[change-core](../change-core/SKILL.md) is the procedure for authoring Core, and
it applies to every ticket here — this file is what wraps around it when there
are twenty of them and nobody is watching.

## The two rules that make this safe to leave alone

**Authoring is parallel; merging is serial.** Several subagents may be writing
at once. Only one branch lands at a time, and before it lands it merges `main`
down and re-runs the full check suite against the tree it is actually landing
on. A branch that went green against a `main` from four hours ago has been
checked against a tree that no longer exists.

**Anything Fence stops.** `packages/harness/**`, `src-tauri/**`,
`sandbox-policy.baseline.json`, `sandbox-policy.json`, `scripts/**` and
`.githooks/**` are never merged unattended, and neither is a `package.json` diff
that touches `postinstall`, `preinstall` or `prepare`. A ticket that needs one is
**authored in full**, checked, and left pending for the developer — the work is
the expensive part and you can do all of it. What you cannot do is land it.

## The loop

### 1. Read the queue

Tickets live at `.scratch/<feature-slug>/issues/NN-<slug>.md`. Take the ones
whose `Status:` is `ready-for-agent`. Read every one before starting any of
them: a ticket that renames something six tickets later depend on changes the
order, and that is cheaper to learn now than at the merge.

Build the order from the `Blocked by:` lines. A ticket is runnable when every
ticket it names has merged — not when they have been *written*, because a branch
that has not landed is not something the next ticket can build on.

### 2. Author, in parallel, one Worktree each

For each runnable ticket, spawn a subagent with its own Worktree under
`.claude/worktrees/`, named for the ticket rather than its number.

Give the subagent the ticket file, and tell it: the Worktree is where it works,
`bun run drive` has to pass before anything is considered done, and it must
**commit as it goes** — work that is not committed is invisible to the review
band and to you, so a subagent that stops mid-task with a dirty tree has
produced nothing you can act on.

> The engine for the implementation step is unresolved. `mattpocock-skills:implement`
> is marked `disable-model-invocation`, so neither you nor a subagent may invoke
> it. Until that is settled, brief the subagent directly from the ticket and from
> the repository's own documents: CLAUDE.md, CONTEXT.md, the relevant ADRs, and
> DESIGN.md when the ticket touches the surface.

### 3. Review, and fix what review finds

When a subagent reports done, run `mattpocock-skills:code-review` against its
branch. Hand the findings back to *the same subagent* — it holds the context for
why it wrote what it wrote, and a fresh one will re-derive it wrongly.

Three rounds, maximum. Park the ticket if the third does not come back clean, or
if the same finding appears twice — a finding that survives a fix aimed at it is
a disagreement, not a defect, and it needs the developer rather than a fourth
attempt.

### 4. Merge, one at a time

Inside the Worktree, merge `main` down. Resolve conflicts yourself — you have
read both branches and the developer has read neither. `mattpocock-skills:resolving-merge-conflicts`
is available and may be invoked.

Re-run the full suite: typecheck, lint, `bun run drive`, build. Then land it.

If the merge changes anything that matters, review again before landing. A
conflict resolution is code nobody has reviewed.

### 5. When the queue is empty

Run the pre-release skill. Then write the report.

## Parking a ticket

Parking is a real outcome, not a failure to report quietly. Set `Status:` to
`needs-triage`, append what happened under `## Comments`, and **leave the branch
and the Worktree on disk** — the diff is the most useful thing you can hand
over, and it is worth more than any description of it.

Then take the next runnable ticket. One ticket that cannot land does not end the
night; a ticket that *blocks* others parks them too, and the report says so.

## The report

Write it to `.scratch/<feature-slug>/run-report.md`. Per ticket: merged, parked
or blocked; which checks ran; what review found and what was done about it; the
branch name if there is one left to look at.

Say what you did not do, and why, in the same detail as what you did. A report
that reads as a clean sweep when three tickets were parked is worse than no
report, because it is the one the developer will believe.
