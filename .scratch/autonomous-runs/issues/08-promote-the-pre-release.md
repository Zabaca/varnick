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

**Realizes:** release.idle, release.pending, release.promoting, release.failed

**Blocked by:** 06 — Cut a pre-release from the command line.

**Status:** ready-for-agent

- [ ] A pending pre-release appears in the window with its version and its announcement
- [ ] The band renders nothing when there is no pre-release pending
- [ ] One control promotes it, and it is rendered only when the machine accepts the event
- [ ] Promoting switches the served artifact and restarts varnick onto it
- [ ] The conversation is intact afterwards, restored from the Session mirror
- [ ] The announcement is posted into the transcript, attributed as varnick's own rather than as something the developer or the agent said
- [ ] A promotion that fails leaves the developer on the build they were already running, with the reason on screen and a way to try again
- [ ] The states are named in the machine, carry cards on the states page, and are driven headlessly — including the refusals

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
