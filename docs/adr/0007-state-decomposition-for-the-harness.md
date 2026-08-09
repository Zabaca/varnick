# State decomposition for the Harness

Three machines. `harness` is the parent and owns the facts that decide whether an agent may run at all; `session` is one child, spawned when the agent first starts and outliving every restart; `surface` is one child per discovered Surface. Both the Harness and the Session are parallel: the Harness across `credential`, `sandbox`, and `agent`, the Session across `turn`, `persistence`, and `composer`. The Harness had a fourth region, `subscription`, cut in ticket 31 — it could only ever sit in `unread`, because no credential varnick can hold reports plan usage.

The alternative was one status enum per machine, and it fails on the cases that matter. A credential can be rejected while the sandbox is fine; the sandbox can be unavailable while a credential is present; the agent process can crash without changing either. Collapsing those into one enum makes every combination a new member and every transition a lie. On the Session it is worse: a save can fail while a turn is streaming, and a flat status would make "the transcript survives a broken build" untrue in exactly the case the product exists for.

Spawning the Session from `agent.running` rather than owning it in the parent state is what makes durability structural. The agent process is restartable; the conversation is not attached to it.

## Consequences

- **Regions publish their state into context.** An XState v5 guard receives only `{ context, event }` — it cannot read a sibling region's value. Each region assigns its own state to `credentialState` / `sandboxState` on entry and the start guard reads those. The UI reads the same two fields, so the affordance and the rule cannot drift apart.

- **Nothing at the root may carry a target.** A root-level `on` transition with a target is external in a parallel machine: it exits and re-enters every region, destroying spawned children. `READ_SUBSCRIPTION` written that way tore down the Session — and the whole conversation — on first load. That event no longer exists (ticket 31 cut the `subscription` region), and the rule it taught is kept deliberately: the bug was a property of root-level targets in a parallel machine, not of the event that happened to be written first. Events handled at the root are limited to actions (`EDIT_DRAFT`, `SET_MODEL`, `SET_EFFORT`, `SET_COMMANDS`, Surface discovery); anything with a target lives inside its region.

- **A refused start is a state, not a disabled button.** `START` is a guarded transition with an unguarded fallback into `startRefused`, so a refusal explains itself rather than swallowing the click. The consequence is that `can({type:'START'})` is permanently true and nothing may bind a `disabled` attribute to it — readiness comes from `canStartAgent()`. The one time `startRefused` handled `START` differently from `down`, a start that had since become valid was silently dropped.

- **Menu state is derived, never toggled.** The composer region computes whether the menu is open from the draft and the command names it has been told about, so it cannot drift from what is actually typed. The single exception is `menuDismissed`, which exists because Escape must close the menu while leaving a draft that still starts with `/`.

- **Every state is addressable.** Each machine exports its state paths (`HARNESS_STATE_PATHS`, `SESSION_STATE_PATHS`, `SURFACE_STATE_PATHS`) and each takes entry-point inputs. That is what lets `#/states` park the real component in a named state, what lets a ticket say `#/states → turn.failed` instead of restating a design, and what makes the coverage banner able to go amber when a state gains no card. Adding a state without a scenario is a visible regression rather than a silent one.

- **Delays are named, never numeric literals.** `interruptGrace` and `refusalTimeout` are overridden by the frozen build; a literal in `after` cannot be, and an explorer card that expires while it is being read is not showing the state it claims.

- **Pairs with [ADR-0001](./0001-pure-view-layer.md).** The machines declare actor contracts and never import an implementation, so the live app, the bare page, and the states page differ only in which implementations are provided and who owns start-up.

## Amended while building the mirror

`persistence` had no trigger. The region was complete and nothing ever sent it
`SAVE` — only the bare page's buttons did, which meant the transcript was
mirrored exactly when a developer clicked. Ticket 06 added a `saveTranscript`
action, raised at each Turn boundary: turn done, turn failed, an interrupt
folding its partial in, and a Compaction rewriting history. `saving` now also
accepts `SAVE` and re-enters, so a boundary reached while a save is in flight
restarts it rather than being dropped — otherwise `persistence.saved` would mean
"some earlier transcript is on disk", which is not what the state says.

This is a machine change made during stage 6, which the stage contract says
should not happen. It is recorded rather than waived: no state was added or
removed, `SESSION_STATE_PATHS` and the states-page cards are untouched, and the
model was not wrong — the wire was simply never run, because until the mirror
existed there was nothing to save to. A failed Turn saving is the case worth
keeping in mind: the user's message is in the transcript whether or not an
answer ever arrived, and that is the loss the mirror exists to prevent.

## Amended again while building Compaction (since reversed — see below)

**`compactSession` is handed a copy of the transcript.** One line, in the
actor's `input`, and it is what turns "a failed compaction leaves the
conversation unchanged" from a rule an implementation has to remember into
something the machine enforces. `readonly Message[]` is a compile-time claim and
nothing at run time: an implementation that assembled the replacement in the
array it was handed and then threw would leave a half-rewritten conversation
behind a `turn.idle` saying nothing happened, and every count-based assertion
would pass. With a copy, the replacement can only arrive as the actor's result,
so the only way to change the transcript is to finish. `drive.ts` runs exactly
that hostile implementation and asserts the conversation survives it.

**And `compacting.onError` still raises no `SAVE`, deliberately.** It is the one
Turn boundary missing from the list above, and the omission is the point:
Compaction is also the only boundary that takes the store's *replace* path
rather than its append path, so a failure that raised `SAVE` would put the
mirror one atomic rewrite away from a conversation nobody rewrote. `drive.ts`
asserts the mirror is not written at all when a compaction fails.

Recorded for the same reason as the amendment above: no state was added or
removed, `SESSION_STATE_PATHS` and the states-page cards are untouched, and the
`#/states` cards for `compacting` and the failure after it render exactly as
they did.

## Amended again: a Turn is one state because it is one actor

`sending` and `streaming` were siblings, and each carried `invoke: { src: 'runTurn' }`. An invoke is bound to the state node it sits on, so the transition between them stopped the first actor and started a second — meaning the first streamed token aborted the developer's Turn, told the host to interrupt it, and posted the same prompt again. Billed twice, answered once.

They are now children of an `answering` state that holds the invoke. The state paths changed with them, because the machines are where a state is named: `turn.answering.sending` and `turn.answering.streaming`.

Two things worth keeping from how this was missed. The two blocks were byte-identical — the fingerprint of a bad conflict resolution, and this run produced four of those. And `drive.ts` had a census asserting that `sending` and `streaming` accept the same events, which passed *because* they were duplicates: it compared them to each other rather than to the model. The assertion that catches it counts actor invocations across a streamed Turn, and fails the moment a second invoke reappears.

The same change moved the prompt-append out of the state's entry and onto `SEND`. `RETRY_TURN` re-enters `answering`, and by then the draft has been consumed — an entry action appended an empty user message and retried with an empty prompt, writing the empty message to the mirror on the way.

## Amended again: Compaction is not a state, because varnick does not perform one

Both amendments about Compaction above are now history rather than rules. They
were careful answers to a real hazard — a summarisation that half-rewrites the
transcript, and a failed one that writes the mirror — and the hazard was created
by varnick doing the summarising. It no longer does.

`turn.compacting` covered the compactions varnick was asked for and none of the
others. Claude Code has its own `/compact`, and an **auto-compaction has no
command at all** — it fires because the window filled, with nothing on screen to
notice. Every one of those rewrote the agent's context while the transcript kept
the messages it had replaced, which is the same disagreement `/clear` had, with
nobody able to see it happen.

So the state, its actor, its control request and its two failure tags are gone,
and what replaced them is a report at the machine's root: `COMPACTED`, carrying
the summary the Session produced and what its context now measures. Three
consequences, each of which was an argument in the sections above:

- **The half-rewrite hazard is structural rather than guarded.** There is no
  actor holding the transcript, so there is nothing to rewrite in place. The
  event carries a summary and the machine builds the replacement from it.
- **The `SAVE` that was deliberately absent is now deliberately present.** A
  compaction that reaches varnick is one that already happened, so the mirror
  must take the replace path or a restart hands the window back a conversation
  the agent gave up. The old omission was about a compaction that *failed*, and
  varnick can no longer see one — a compaction that did not happen is a
  transcript that did not change.
- **The meter is still a reading or nothing.** `tokensUsed` is measured after
  the rewrite and may be `null`, which leaves the meter where it was. The old
  code failed the whole Compaction rather than show a figure nobody took; there
  is nothing to fail now, and `0` would be the worst available lie.

`SESSION_STATE_PATHS` lost a path and the states page lost two cards, which is
the change the two amendments above were each careful to say they had *not*
made. One card replaced them: a transcript after a compaction, which is what a
developer actually sees.
