# 16 — The announcement races the restart it announces

**What to build:** the announcement varnick posts when a promotion lands is in
the Session mirror before the process is replaced, rather than probably in it.

Today `release.promoted` posts `VARNICK_ANNOUNCED`, which raises `SAVE` and
issues `persistSession`, and invokes `restartVarnick` in the same instant.
Nothing waits on the mirror write completing. The write is *issued* first, so it
usually wins — but a process teardown beating a file write is not a narrow
window.

If it loses, the failure is silent and it destroys exactly the thing it exists
for: the developer restarts onto the promoted build and the record of **why the
ground moved** is missing from the restored transcript. The changelog still
carries the entry, so nothing is unrecoverable — but the conversation, which is
where the developer was actually looking, does not say what happened.

## Why this is not simply "await the save"

The obvious fix is worse than the exposure, and the reasoning is worth keeping:

**Waiting on the save means waiting on something that can fail.** A persistence
that never confirms is a restart that never happens — trading a probable silent
loss for a possible permanent hang. Bounding the wait with a delay means picking
a number, and ADR-0007 already says a number in an `after` is luck written down.
The delay has to be *named* and its value *argued*, which is the whole reason
this is a ticket rather than a line.

Note also that this exposure is **new and unique to the release region**, not
inherited. `worktreeMerge.merged`'s entry raises `LIST_WORKTREES` and nothing
else — it posts nothing to the transcript, so it has no persistence to race, and
its restart is a second deliberate press taken after the developer has read the
report. An earlier claim that the two were equivalent was wrong and was retracted
in ticket 08's record.

## Design notes from the attempt that was reverted

Ticket 08's author started this, hit the point where it stopped being small, and
reverted cleanly rather than commit a half-finished region onto `main`. What they
established, so this is a short job rather than a rediscovery:

- **The plumbing exists.** `session.on('TURN_ENDED', …)` at the spawn is the
  precedent; a second join is one line beside it. `SessionEmitted` gains
  `{ type: 'TRANSCRIPT_SAVED' }`, emitted from `persistence.saving`'s `onDone`
  — **on the transition, not on `saved`'s entry**, because a re-entry from a
  later `SAVE` is a different transcript landing and is worth saying again.
- **It is one new sibling state, not nesting.** `release.restarting`, exactly as
  `worktreeMerge` has `restarting` beside `merged`. `promoted` then means
  *announced, waiting for the mirror*; `restarting` invokes `restartVarnick`;
  both its ends return to `promoted` with the reason, as `worktreeMerge` does.
- **The trap:** returning to `promoted` re-arms whatever moved it on, so an
  `after` would loop restarts for ever. It must be guarded on
  `promotionError === null` — auto-advance only while nothing has failed, manual
  press thereafter.
- **The delay must be named** (`announcementGrace` or similar) per ADR-0007, and
  its value is the part that needs arguing.
- Remaining cost: one `HARNESS_STATE_PATHS` entry, one card, ticket 08's
  `Realizes:` line to six, one drive assertion, one CONTEXT.md line.

## An observation that came out of it

**No drive check enforces that machine nodes are a subset of
`HARNESS_STATE_PATHS`.** A state can exist in the machine and be named nowhere.
`SURFACE_UNCARDED_STATE_PATHS` is the precedent for a named-but-uncarded state if
that is ever wanted. Worth its own ticket if anybody agrees it should be checked.

This is a Fence change and lands through a human merge.

**Blocked by:** None. Ticket 08 landed the region this sits in.

**Status:** needs-triage

- [ ] The announcement is in the Session mirror before the restart is invoked, or the wait gives up in a bounded and named way
- [ ] A wait that never confirms cannot become a restart that never happens
- [ ] The delay is named and its value is argued where it is defined
- [ ] Returning to the waiting state cannot re-arm the restart into a loop
- [ ] The new state is in `HARNESS_STATE_PATHS`, carries a card, and is driven — including its refusal
- [ ] Ticket 08's `Realizes:` line names it

## Comments

Named by ticket 08's author rather than left to be found, then attempted and
reverted when it grew. The orchestrator instructed them to close it on that
branch; they declined with the argument above and the orchestrator accepted —
the instruction was wrong.
