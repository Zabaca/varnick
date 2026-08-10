# 55 — The review list waits to be asked, and sits below the fold

**What to build:** Pending Core changes appear when they appear, without anybody clicking, and sit where they will be seen.

**Blocked by:** None — can start immediately.

**Status:** ready-for-agent

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

- [ ] Committing in a worktree during a Turn makes the entry appear without anybody clicking
- [ ] The panel sits above the conversation when it has entries
- [ ] `review.empty` occupies no vertical space
- [ ] *look again* still works, for changes made outside the window
- [ ] A refresh while a diff is open leaves the diff open
- [ ] A failed refresh does not discard a list that was good

Found by using it: the developer watched an agent commit and the panel stayed blank.
