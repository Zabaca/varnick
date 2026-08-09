# 50 — The diff view, with Fence hunks distinct

**What to build:** The developer opens a pending worktree in varnick and reads what changed, with Fence hunks visually distinct from everything else.

**Blocked by:** 49 — nothing to render until the worktrees and their changes arrive in Core.

**Status:** ready-for-agent

**Realizes:** `worktreeDiff.loading`, `worktreeDiff.loaded`, `worktreeDiff.failed`.

## In Core, not as a Surface

`CONTEXT.md` defines a **Surface** as one built thing in Userspace, and the agent writes Userspace freely. A diff renderer the agent can rewrite is a diff renderer that can hide its own hunks — the same spoofing class as a forged dialog, with a worse consequence, because a forged dialog asks once and a shaded diff is the only thing standing between a widening and a merge.

So it ships in Core. Two things follow and both are the point: the agent cannot build this, and every later change to it goes through the flow it enables. The first one is hand-written.

## What it is not

Not a git client. It shows pending worktree changes and nothing else — no staging, no history, no blame, no commit. The developer merges with the tools they already have open. varnick's job here is to make one thing impossible to miss, not to compete in a category it cannot win.

## The one visual requirement

A Fence hunk must not read like a CSS change. `packages/harness/**`, `src-tauri/**` and `sandbox-policy.baseline.json` are the paths that decide what the agent may do, and a widening buried in four hundred lines is exactly what this exists to catch.

DESIGN.md is strict and this is where a diff viewer breaks it by habit — a second font, rounded panels, a green/red palette borrowed from a terminal. The elevation vocabulary is `ground-raised` with a 1px `rule` border and square corners; a heading is a heading by weight and colour, never by size. Distinguishing a Fence hunk is a design problem inside that system, not a licence to leave it.

## Watch for

- Reuse what exists. `packages/core/src/markdown.tsx` already renders code blocks inside the system, with horizontal scroll rather than wrapping — a diff has the same requirement and the same reason.
- `worktreeDiff.failed` needs a retry, and the retry must exist because the state has a handler, not because a button was left enabled.
- Every state here needs a card on `#/states` with a scenario that reaches it, including `failed` with a real message. A `failed` card with no message is not an honest rendering of that state.
- A large diff is the normal case, not the edge case.

- [ ] A pending worktree can be opened and its changes read
- [ ] Fence hunks are visually distinct from ordinary ones
- [ ] The view stays inside DESIGN.md — no new type sizes, no second font, no rounded panels
- [ ] Long lines scroll horizontally rather than wrapping
- [ ] `worktreeDiff.failed` carries a reason and offers a retry
- [ ] Every state path has a card, and the coverage banner is green
- [ ] Nothing in the view is loaded from Userspace
