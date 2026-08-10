# 64 — A merge that clears up after a Worktree somebody is using

**What to build:** Merging a Worktree that something is running out of removes it anyway, having asked the things using it to stop first.

**Blocked by:** None — can start immediately. Ticket 56 shipped the safe half.

**Status:** ready-for-agent

**Realizes:** likely one new state on `worktreeMerge`; to be decided by whoever
takes it, not assumed here.

## What ticket 56 left

Ticket 56 built the merge and the cleanup, and deliberately stopped short in two
places. Both are the same shape — **varnick knows something is standing in the
directory and has no way to ask it to move** — so they are one ticket rather than
two.

Today, when a merge lands and something holds the worktree, the branch is
squashed and committed and the directory is left alone, with a sentence naming
the processes. That is the safe outcome and it should stay the fallback. It is
not the finished feature: the row cannot clear itself, and the developer is left
with two commands to run by hand.

### The agent is not asked to leave

Ticket 56's own measurement, twice over:

> **Removing the directory is not recoverable by the agent.** It cannot report
> the problem, ask, or step back to the clone root — the SDK treats the missing
> cwd as a terminal error before any of that. So "tell the agent to leave, then
> confirm" is not politeness, it is the only ordering that works, and the
> confirmation has to be a real acknowledgement rather than a message sent.

What shipped instead is the cwd probe: if any process has the directory as its
working directory, nothing is removed. **That is stronger than it sounds** — it
catches the agent whether or not a lock exists, and the lock was measured
unreliable in both directions. It is why the dangerous half is safe today.

What it cannot do is *resolve* the situation. The agent is usually the process
holding the directory, and it would move if asked.

### A Preview is not stopped

> Remove the worktree, delete the branch, **and stop anything running out of
> it** … SIGTERM to the app process runs ticket 35's teardown.

Not built. A Preview launched from the Worktree is a window, a port and its own
sandboxed agent, and it holds the directory as its cwd — so **a merge of a
worktree that has ever been previewed always ends in the left-over path.**

The reason it was not done blind: killing the wrong process is worse than not
killing one. A Preview is three processes and signalling the launcher orphans the
other two, which is exactly the tree ADR-0003 exists to prevent. varnick spawned
the Preview and knows which pid is the app, and that knowledge is host-side —
`preview.rs` — while the cleanup runs in the runtime. The two have never had to
talk about this.

## What to build

**Ask, then confirm, then remove.** Not "send a message and hope": the
acknowledgement has to be a fact varnick observes. The cwd probe is that fact and
it already exists — the agent leaving *is* the probe going quiet — so the shape
is likely: tell the agent to leave, wait for the directory to be free, then
remove. A wait that expires leaves the worktree standing, which is where the
product already is.

**Stop a Preview varnick launched, by pid, and only one it launched.** The host
holds that. A process that merely happens to have the directory as its cwd is
still named and left alone.

## Watch for

- **The fallback must survive.** Every path that cannot finish must still leave a
  landed merge and an untouched directory. A cleanup that half-works and removes
  something anyway is worse than the current honest sentence.
- **Do not reach for the lock.** Measured unreliable in both directions in ticket
  56, and the check that killed a live agent.
- The Briefing already tells the agent its branch landed. Asking it to leave is a
  second thing varnick says to it unprompted, and the two should not become two
  mechanisms — see **Briefing** in `CONTEXT.md`.
- A worktree removed while its Preview's Vite server is serving from it is a
  second failure mode with its own error, unrelated to the agent.

- [ ] A merge of a Worktree the agent is standing in removes it
- [ ] The agent is asked to leave and observed leaving, not merely told
- [ ] A merge of a previewed Worktree stops the Preview and removes it
- [ ] A process varnick did not launch is named and left alone
- [ ] Every failure still leaves the merge landed and the directory intact
- [ ] The row leaves the review list once the worktree is gone

Split out of ticket 56, which shipped the merge and the safe half of the cleanup.
