# 50 — The diff view, with Fence hunks distinct

**What to build:** The developer opens a pending worktree in varnick and reads what changed, with Fence hunks visually distinct from everything else.

**Blocked by:** 49 — nothing to render until the worktrees and their changes arrive in Core.

**Status:** done

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

- [x] A pending worktree can be opened and its changes read
- [x] Fence hunks are visually distinct from ordinary ones
- [x] The view stays inside DESIGN.md — no new type sizes, no second font, no rounded panels
- [x] Long lines scroll horizontally rather than wrapping
- [x] `worktreeDiff.failed` carries a reason and offers a retry
- [x] Every state path has a card, and the coverage banner is green
- [x] Nothing in the view is loaded from Userspace

## Comments

**Implemented on `ticket/50-diff-view`.** Not merged; the gate is a human's
`git merge`, and `denyWrite` refuses the agent that merge by construction.

**Where the work landed**

- `packages/harness/src/worktrees.ts` — `readPendingWorktreeDiff`, one command
  more (`git diff --no-color HEAD...<ref>`), sharing `reviewable()` with the
  listing so a diff view cannot open a tree the list refuses to show. The one
  field on the review path is a **selector**: the path is compared with what
  `git worktree list` reported and the ref that reaches argv is the one git
  printed, so a path composed anywhere else produces no diff command at all.
- `packages/harness/src/bridge.ts`, `runtime.ts`, `src-tauri/src/bridge.rs` —
  `read-worktree-diff`, routed to the runtime like the listing beside it.
- `packages/core/src/machines/worktree-diff.ts` — a child machine per opened
  diff, like a Surface and for the same three reasons.
- `packages/core/src/diff.ts` — the parser, asking `isFencePath` from the
  Harness rather than writing a fourth glob list.
- `packages/core/src/components/worktree-review.tsx` — the list beside the
  conversation, and the diff taking the surface when one is opened.

**How a Fence hunk is told apart, and why it fits.** The diff spends **no**
colour on added and removed lines — marker and tone (`fg`, `fg-faint`,
`fg-dim`) carry those — which is The Three Greys Rule applied to the one screen
most likely to argue for an exception, and it leaves colour meaning exactly one
thing here. Fence is `warn`, DESIGN.md's *build admitting something about
itself*; not `bad` (nothing failed) and not `accent` (nothing to act on inside
a diff). It is carried at three distances, the last of which is the load-bearing
one: every hunk has the same geometry, a 1px left border, and only its colour
differs — so a Fence hunk read in isolation, scrolled far from anything naming
the file, still says what it is. The border sits on the scrolling element, so a
long line cannot scroll the marking away.

**Two judgements not spelled out in the ticket.**

*A diff takes the whole surface*, the way first-run setup already does in
`chat-surface.tsx`, rather than sitting in the 320px panel beside the chat. A
diff is what The Wide Measure Rule is written about, and a large diff is the
normal case. Nothing is lost: the Session, the agent and the listing are
machines this does not touch, so `close` brings the conversation back as it was.

*One diff open at a time.* Opening a second is refused by a guard rather than
by a hidden control, which is what keeps a replaced actor from being left
running with nothing pointing at it.
