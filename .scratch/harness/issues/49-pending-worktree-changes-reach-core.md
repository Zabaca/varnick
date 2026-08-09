# 49 — Pending worktree changes reach Core

**What to build:** varnick knows which worktrees hold Core changes that have not been merged, and what changed in each. Data only — the rendering is ticket 50.

**Blocked by:** None — can start immediately.

**Status:** done

**Realizes:** `review.listing`, `review.listed`, `review.empty`, `review.listFailed`.

## Where the data comes from, and why not from the agent

Host-side. The host runs git and Core reads the result over the bridge.

The agent must not be the source, for the same reason the renderer is not a Surface: this is the mechanism that shows what the agent changed, and a report the agent composes is a report the agent can shade. It costs nothing to take it from git directly, and taking it from the agent would quietly make the whole review advisory.

## What a worktree entry is

The branch, the worktree's path, whether it holds commits the live tree does not, and — the field the next ticket turns into colour — whether any changed path is **Fence**: `packages/harness/**`, `src-tauri/**`, `sandbox-policy.baseline.json`.

Fence classification belongs in the harness as a pure function over a path, tested at the unit seam, because three separate things key off it: this list, ticket 48's dialog, and ticket 50's highlighting. One definition, three callers — not three glob lists that drift.

## Watch for

- `review.empty` is a real state and it is not `listed` with a count of zero. Nothing pending and a listing that failed are different problems with different copy, and the repo's own rule is that a filtered-empty and an empty are distinct.
- A worktree whose branch has no commits yet is not pending. It is an agent that has started, not one that has finished.
- The diff can be large. Decide what this ticket carries and what ticket 50 fetches on demand, and say which — a list that eagerly loads every hunk of every branch is a list that hangs.
- New state names go in `CONTEXT.md` under **State names**, and every path here needs a card on `#/states` or the coverage banner fails. That is the gate, not an afterthought.

- [x] Worktrees holding unmerged commits are listed, with branch and path
- [x] Each entry says whether it touches Fence code
- [x] Fence classification is one pure function, asserted directly
- [x] Nothing pending reaches `review.empty`, not `review.listed`
- [x] A git failure reaches `review.listFailed` carrying why
- [x] The list is produced host-side; nothing in it is composed by the agent
- [x] Every new state path is named in `CONTEXT.md` and has a card

## Comments

**Implemented on `ticket/49-worktree-changes`.** Not merged; the gate is a human's
`git merge`, and `denyWrite` refuses the agent that merge by construction.

**The decision the ticket asked for: this ticket carries the summary, ticket 50
fetches the hunks.** An entry is a branch, a path, a commit count, the changed
path *names* and one Fence flag. Reasoning, recorded in the `review` region's own
comment in `packages/core/src/machines/harness.ts` and in `worktrees.ts`: a list
that read every diff of every branch before drawing a row would spend the whole
of a large branch to show a row saying which branch it is, and this list is what
a developer reads to *choose* the branch whose diff they want. Path names are
carried because they are cheap — one `--name-only` per worktree — and because
they are what makes the Fence flag auditable: a row claiming Fence with no path
that is one is a row nobody can check.

**Where the work landed**

- `packages/harness/src/fence.ts` — `FENCE_PATHS` and `isFencePath`, pure, no
  imports, so all three callers can reach it (this list, ticket 48's dialog,
  ticket 50's highlighting). `fence.test.ts` also asserts the list against the
  generated policy's `denyWrite`, so the two readings of ADR-0014 cannot drift.
- `packages/harness/src/worktrees.ts` — the porcelain parse and the three
  read-only commands, with `git` as an injected port so nothing in the module
  spawns a process.
- `packages/harness/src/runtime.ts` — the one implementation that does: `execFile`
  with argv (never a shell), `GIT_OPTIONAL_LOCKS=0` so a review cannot block the
  agent it is describing, and a bounded wait.
- `src-tauri/src/bridge.rs` — `list-worktrees` routes to the runtime. No
  credential, no worktree name in the request.
- `packages/core/src/machines/harness.ts` — a fourth region, `review`.

**One judgement not spelled out in the ticket:** the region has no resting state
before `listing`. The other three regions wait on something a person decides;
nothing decides to list, and a state meaning "not asked yet" would quietly defeat
"nothing the agent finished waits unnoticed". Recorded in `CONTEXT.md`.

**Verified against the real repository as well as the fakes:** run against this
clone, the listing excludes the main worktree and the tree varnick is running
from, and reports this ticket's own worktree with `touchesFence: true` — which is
correct, since it edits `packages/harness/**` and `src-tauri/**`.
