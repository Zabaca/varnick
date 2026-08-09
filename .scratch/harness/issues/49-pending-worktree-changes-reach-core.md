# 49 — Pending worktree changes reach Core

**What to build:** varnick knows which worktrees hold Core changes that have not been merged, and what changed in each. Data only — the rendering is ticket 50.

**Blocked by:** None — can start immediately.

**Status:** ready-for-agent

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

- [ ] Worktrees holding unmerged commits are listed, with branch and path
- [ ] Each entry says whether it touches Fence code
- [ ] Fence classification is one pure function, asserted directly
- [ ] Nothing pending reaches `review.empty`, not `review.listed`
- [ ] A git failure reaches `review.listFailed` carrying why
- [ ] The list is produced host-side; nothing in it is composed by the agent
- [ ] Every new state path is named in `CONTEXT.md` and has a card
