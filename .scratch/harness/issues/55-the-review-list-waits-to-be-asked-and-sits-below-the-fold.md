# 55 — The review list waits to be asked, and sits below the fold

**What to build:** Pending Core changes appear when they appear, without anybody clicking, and sit where they will be seen.

**Blocked by:** None — can start immediately.

**Status:** ready-for-human — built on `worktree-agent-af359d189b94453e7`, a
fast-forward onto `main`, awaiting a merge and a restart. Five of the six boxes
are closed headlessly; the sixth is closed in the machines and wants a pair of
eyes on the band. See Comments.

**Realizes:** no new state path. `review.listing` gains a trigger.

## What happens

The `review` region lists **once**, on entry, and then waits: `listed`, `empty`
and `listFailed` each accept `LIST_WORKTREES` and nothing sends it except the
*look again* control.

So the first real use went like this. varnick launched while the agent's
worktree had no commits, the region listed, found nothing, and settled in
`empty`. The agent then wrote three files and committed. The panel stayed blank
until the developer pressed *look again*, at which point the entry appeared.

Nothing was broken. The region did exactly what it was built to do, and what it
was built to do is wrong: **the pending list is a fact about a filesystem that
changes while varnick runs, and the thing that changes it is the agent in the
window beside it.**

## The trigger

**The end of a Turn.** The agent is what creates worktrees, writes in them and
commits them, so a Turn ending is precisely when the answer may have changed —
and it is a signal varnick already has, with no polling, no watcher and no
timer. A developer who has just watched an agent say "committed" should not then
have to ask varnick to go and look.

The cross-machine wiring is the design question, not the trigger. `review` is a
region on the Harness and a Turn belongs to the Session; the two already meet in
Core, and neither should learn about the other's internals to make this work.

Keep *look again*. An agent is not the only thing that can commit — the
developer has a terminal — and an explicit re-ask is the honest answer to "I did
something outside this window".

## Where it sits

**Above the conversation when it has something, and out of the way when it does
not.** A pending Core change is the most consequential thing on the screen: it
is code that will decide what the agent may do, waiting for a human. It should
not be reachable only by scrolling.

`empty` should take no vertical space at all. The panel earning a permanent slot
for the state it is in almost all the time is how it ends up below the fold.

## Watch for

- Re-listing while a diff is open must not disturb it. `CLOSE_WORKTREE` is the
  parent's for a reason and a refresh is not a close — the existing rule that a
  re-listing does not shut what someone is reading has to survive this.
- A refresh that fails should not replace a good list with an error. `listFailed`
  already drops the stale list on purpose; that is right for a first listing and
  wrong for a refresh, and the two are now different cases.
- Do not add a timer. If the end of a Turn turns out not to cover it, the next
  answer is a filesystem watch, not a poll.

- [x] Committing in a worktree during a Turn makes the entry appear without anybody clicking
- [x] The panel sits above the conversation when it has entries
- [x] `review.empty` occupies no vertical space
- [x] *look again* still works, for changes made outside the window
- [x] A refresh while a diff is open leaves the diff open
- [x] A failed refresh does not discard a list that was good

Found by using it: the developer watched an agent commit and the panel stayed blank.

## Comments

### The wiring, which was the actual ticket

`review` is a region on the Harness and a Turn belongs to the Session, and the
constraint was that neither learn the other's internals. Three candidate joins
were considered and two were rejected for reasons worth keeping:

- **`sendParent({ type: 'LIST_WORKTREES' })`** from the Session. Rejected twice
  over. It puts the Harness's vocabulary in the Session — the child deciding
  what the parent should *do* rather than reporting what happened — and
  hooks.ts already states the rule outright, beside `CREDENTIAL_REJECTED`: *a
  child does not send to its parent*. It also throws wherever a Session has no
  parent, which is most of `drive.ts` and every card on `#/states`.
- **The owning hook**, where `STREAM_DELTA` and `CREDENTIAL_REJECTED` are
  routed. Rejected because it is one join per rendering: hooks.ts, frozen.ts and
  drive.ts each build the Session with their own `.provide()`, so a join written
  at one of them is a join the other two silently do not have — and it would sit
  in a React effect, where `drive.ts` cannot reach it (ADR-0013).

What shipped: the Session **emits** `TURN_ENDED` — a fact about itself,
addressed to nobody, naming no worktree and no event of the Harness's — and the
Harness subscribes to its own child at the spawn in `agent.running` and sends
*itself* the `LIST_WORKTREES` it already had. `.on` is parent-to-child plumbing,
the same category as the `spawn` on the line above it, so nothing about ADR-0001
moves; the ref is the one thing every rendering shares, so nothing can be built
that has the Session and not the trigger.

No new state, and no new Harness event: `LIST_WORKTREES` has two askers now.

### Three judgement calls beyond the six boxes

**A `/pending` command.** Boxes three and four pull against each other:
`review.empty` occupying no vertical space means the band is absent in exactly
the state a developer who has just committed from a terminal is looking at, so
*look again* has nowhere to live at the moment it is most wanted. The event is
in the command menu, gated by `can()` like varnick's other two. The alternative
was to leave a control that is unreachable in the common case, which reads as
half of box four.

**A listing in flight with no rows behind it also draws nothing.** Not asked
for, and the band is unusable without it: every Turn ends in `listing`, so a
band keyed on state alone would appear and vanish on every Turn — motion the
machines did not make, on the busiest surface in the product.

**`OPEN_WORKTREE` is accepted in `review.listFailed`.** Once a failed refresh
keeps its rows, rows appear in a second state, and a list you can see and cannot
open is a list half-thrown-away. The existing `openable` guard already requires
the path to be one the machine is holding, so a first listing that failed still
offers nothing.

### One thing the ticket asks for that the machine cannot give

A Turn that ends *while a listing is in flight* is dropped, not queued: the
region refuses `LIST_WORKTREES` in `listing`, which is the rule that stops a
second click restarting the actor answering the first. So a commit made in a
Turn that ends inside the ~100ms of a listing started before it can wait for the
next Turn. Queueing it would let a fast conversation restart a listing for ever;
a re-entrant `listing` would cancel the answer already coming. Asserted as
written rather than papered over — see `a Turn ending during a listing does not
restart it` in drive.ts.
