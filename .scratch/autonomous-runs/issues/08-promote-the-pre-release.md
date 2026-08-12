# 08 — A band offers the pre-release, and promoting it restarts you onto it

**What to build:** the developer comes back to a window that says a pre-release
is waiting, what version it is, and what changed. One control promotes it:
varnick restarts onto the new build, the conversation resumes where it was, and
the announcement is posted into the transcript so the record says when the
ground moved.

The band is silent when nothing is pending, like the bands that already report
pending Worktrees and finished merges — a permanent slot for the state it is in
almost all the time is how something ends up below the fold. It sits where those
do, above the conversation, because it is the most consequential thing on the
screen and must not be scrollable away from.

Promotion is the developer's, always. The run cuts the pre-release; it never
switches the build under an open window.

**Realizes:** release.idle, release.pending, release.promoting, release.promoted, release.failed

**Blocked by:** 06 — Cut a pre-release from the command line.

**Status:** ready-for-review

- [x] A pending pre-release appears in the window with its version and its announcement
- [x] The band renders nothing when there is no pre-release pending
- [x] One control promotes it, and it is rendered only when the machine accepts the event
- [x] Promoting switches the served artifact and restarts varnick onto it
- [x] The conversation is intact afterwards, restored from the Session mirror
- [x] The announcement is posted into the transcript, attributed as varnick's own rather than as something the developer or the agent said
- [x] A promotion that fails leaves the developer on the build they were already running, with the reason on screen and a way to try again
- [x] The states are named in the machine, carry cards on the states page, and are driven headlessly — including the refusals

## Comments

Inherited from ticket 07, which built the artifact store's fallback. Recorded
here rather than left in a conversation, because the conversation will not
survive to the person who needs it.

**Use `switchServedArtifact`; never write `served` by hand.** It is what records
`previous`, and `previous` is what the whole fallback rests on. A promotion that
writes the marker directly silently destroys the fallback rather than failing.

**The read side changed after that hand-off was first written.** As of `d67bc31`:

```
readServedMarkers(cloneRoot).served   // MarkerReading, NOT string | null
readServedMarkers(cloneRoot).previous // string | null, unchanged
switchServedArtifact(cloneRoot, id)   // -> { served: string; previous: string | null }
```

`served` is now `{ state: 'absent' } | { state: 'named'; id } | { state: 'unusable' }`,
because an absent marker and an unreadable one are different situations and only
the first may cause a rebuild. Where a promotion needs the current id, that is
`state === 'named' ? id : null`. It fails typecheck rather than doing anything
silent, so it is a five-second fix rather than a trap.

**`served` and `previous` must move together.** `switchServedArtifact` is the
only writer of either, and that invariant is currently held by there being one
function rather than by an assertion. If this ticket adds a second writer, the
invariant needs a test before it needs anything else.

**A promotion must not prune.** Pruning happens at launch and already spares
`served`, `previous` and the artifact that failed. A promotion that also pruned
would be a second retention policy to keep in step with the first.

**Ordering, from ticket 06:** move `served` and `previous` in that order. A
`served` moved first leaves a fallback pointing at the build that just failed.

**The store is bounded** at `ARTIFACTS_KEPT = 4`, sized to leave room for an
unpromoted pre-release plus a spare. Do not assume an unbounded store.

## Notes from building it

Written into the ticket rather than left in a conversation, for the reason
ticket 07's comments give: the conversation will not survive to the person who
needs it. This ticket is **done** — the note is a record of what was decided and
why, not a handoff.

### The `Realizes:` line gained a fifth state, and the ticket was what was wrong

`release.promoted` — *accepted; the restart is owed*. The ticket named four
states because it was written before the restart ordering was understood.

The decisive reason is ordering, not naming. **The announcement has to reach the
Session mirror before the process is replaced.** `VARNICK_ANNOUNCED` is a Turn
boundary on the Session, so it raises `saveTranscript`; the restart is invoked by
the same state. A state whose entry posts and whose `invoke` restarts is the only
place that sequence can be expressed — in a four-state model it would live in a
comment or in luck, and the failure is that the developer is told the ground
moved by a message the move destroyed.

The naming reason is real but secondary: `failed` would say the promotion did not
happen when it did. And folding the restart into `promoting` would put two
invokes on one state, which ADR-0007 records as the bug that billed a Turn twice.

`worktreeMerge`'s `merging → merged → restarting` is the precedent that makes
this the house shape rather than an invention, and its reasoning is copied
deliberately: both ends of the restart return to `promoted`, because a resolve is
no better news than an error — the process is still here, the promotion still
stands, and the restart is still owed.

`release.idle` was **kept**. `worktreeMerge` avoids `idle` because `unmerged`
describes the *tree*, a fact independent of the window; that has no analogue
here, and `worktreeReap.idle` is direct precedent in the same machine.

### Why this branch needs a human merge, precisely

It is `packages/harness/src/session.ts`, and **criterion 6 forces it
independently of how promotion is plumbed**. The announcement must survive the
restart it announces, so it must reach the Session mirror — and the mirror
rejected any role but `user`/`agent` on the way back in. No amount of moving the
promotion around avoids that.

The rest of the Fence surface is thin and was kept that way on purpose:

- `packages/harness/src/bridge.ts` — two kinds, `read-pending-release` and
  `promote-release`. Neither carries a path, a version or an artifact: there is
  one pending pre-release per clone, so there is nothing for a request to select.
- `packages/harness/src/runtime.ts` — two capabilities and two cases. Both are
  file work, so both route to the runtime exactly as `read-commands` and
  `list-worktrees` do.
- `src-tauri/src/bridge.rs` — routing only, with `cargo test` asserting it rather
  than a comment claiming it.

**The logic stays in Core**: the runtime spawns `bun run promote`. The Harness
never imports `packages/core/**` and does not start now — reversing that
dependency would make the Fence depend on the code it fences. This is what keeps
the release machinery improvable without a human merge, which is the spec's
argument for putting it in Core at all.

### The store invariant held without a second writer

`switchServedArtifact` is still the only thing that writes `served` or
`previous`. A promotion *is* a switch, so no second writer was needed — and the
standing rule that a second writer appearing would signal a design fault rather
than something to make safe never had to fire.

**A repeated promotion is a safe no-op.** `servedSwitch` records `previous` only
when the id actually changes, so pressing the control twice cannot replace the
fallback with the build the developer is already on.

**`artifactStartFailureById` catches a broken pre-release before the switch.**
That is ticket 07's function asked one step earlier, and it is the one refusal a
retry cannot fix: promoting onto a build that will not start would hand the
developer a window that does not open, and the fallback would serve the old build
back on the next launch — which works, and still reads as a promotion that undid
itself.

### Two bugs written and caught before committing

Both silent in the good case, so both worth recording:

1. `pendingRelease` was cleared on the transition *into* `promoted` — which
   deletes the announcement one instant before the state that posts it. Every
   announcement would have been empty.
2. `sendTo(context.session!)` throws when no Session exists, and the band is
   drawn whatever the agent is doing. A developer promoting on a fresh clone
   would have crashed the machine on the way to a restart. It is now
   `enqueueActions` with a guard: a conversation that does not exist has nothing
   to record, and the changelog has the release either way.

### Machine and states-page notes worth not rediscovering

- Every region has a `routing` initial state driven by an `enterX` context field,
  and **`routing` is deliberately absent from `HARNESS_STATE_PATHS`** — the five
  release states are paths, the router is not one.
- **Five paths need five `covers:` entries** in `SCENARIOS`, or
  `uncoveredPaths()` regresses and `drive.ts` fails. They are the `The release`
  group.

### One thing narrowed rather than closed

The announcement's mirror write is *issued* before the restart — the entry action
runs before the `invoke` — but nothing waits on it completing. Closing it means
the region observing `persistence.saved`, which is a cross-region read ADR-0007
deliberately makes awkward. This is the same exposure `worktreeMerge` carries
today; named here rather than left to be found.

### For ticket 09

The band is `ReleaseBand`, in `packages/core/src/components/release-band.tsx`.
It is its own file rather than a third band in `worktree-review.tsx`, because
that file is about Worktrees and a release is what a night of them produced.
