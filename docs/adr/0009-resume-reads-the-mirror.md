# Resume reads the mirror, and a Turn in flight at the crash comes back idle

A Session is persisted twice. On launch, varnick reads the **mirror** — the
host-side copy — and spawns the Session from it.

The Agent SDK's own store keeps its job and is not touched by this. The two
answer different questions: the SDK's copy is what the *agent* resumes from, its
context and its continuity; the mirror is what varnick *displays*.

> **Amended by ticket 33.** The sentence above described an intention, not the
> code. Nothing passed `resume`, so for seven launches the SDK's store accrued a
> new conversation each time and none was ever reopened: the window showed the
> whole history and the agent behind it had never seen a word of it. The agent
> host now records the SDK's session id in `.varnick/claude/last-session.json`
> as soon as the runtime reports it, and passes `resume` on the next launch —
> used only when that transcript still exists, because `resume` against a
> forgotten id fails the entire session. Which of the two happened is carried on
> the runtime report and shown in the window, so a restored transcript over a
> fresh agent always says so. The deciding
case is the one the mirror was built for — the agent writes code that does not
compile, and the transcript has to still be readable. A conversation displayed
out of a store that lives inside the thing that just broke is a conversation
that breaks with it.

## The consequence, faced rather than worked around

The mirror is redacted on the write path (ticket 06), so **a restored message
can read `[redacted]` where a secret value was**. That is correct and is not
undone. Reading a secret back onto the screen after deliberately keeping it off
disk would defeat the redaction, and keeping a second unredacted copy so that a
resume looks prettier would be a durable plaintext secret store created for
cosmetic reasons — the exact thing [ADR-0006](./0006-agents-author-secret-use-never-hold-secrets.md)
exists to prevent.

What the surface owes instead is honesty. `restoredTranscript` reports whether
the transcript it is handing back contains a redaction, and the chat surface
says so once, above the transcript, in the same shape as everything else it
admits about itself: *restored from the Session mirror — secret values are kept
off disk, so `[redacted]` stands where one was*. A developer looking at their
own words can tell they are reading the record rather than what they typed.

## A Turn in flight at the moment of the crash resumes as `turn.idle`

Not `turn.failed`: nothing observed a failure. The process died. Inventing a
failure reason would be a state that lies as surely as `sending` would. Not
`sending`: nothing is in flight. A killed Turn and an interrupted Turn are the
same event from the transcript's point of view — an answer that stopped early —
and an interrupt already resolves to `idle` with its partial folded in.

**The decision cost nothing, and the reason is worth writing down.** The mirror
is written at Turn *boundaries* and `persist` accepts only complete messages;
`partial` is not one of them until a boundary folds it in. A Turn that was still
streaming when the process was killed therefore left **nothing on disk at all** —
there is no partial to fold, and no half-finished answer for any other state to
be about. The transcript simply ends at the last completed boundary, and the
honest implementation is the one that says so.

Two things follow, and neither is fixed here:

- **The prompt of the Turn in flight is lost too.** `sending` adds the user's
  message to the transcript but does not raise `SAVE` — only the boundary does.
  A process killed between `SEND` and the answer loses the question as well as
  the answer. The [ADR-0007](./0007-state-decomposition-for-the-harness.md)
  amendment covers the *failed* Turn, where a boundary is reached and the user's
  message is saved; a killed one reaches no boundary. Making `sending` a save
  point would close it, and that is a machine change with its own trade-off
  (a save per prompt, and `persistence.saved` becoming a claim about a Turn that
  has not happened), not a detail of this ticket.
- **No state was added.** A Session restored from the mirror is `turn.idle` with
  messages, which the `#/states → idle-empty` card already renders. Resume needed
  no new state precisely because the decision was to reuse one that already
  meant the right thing.

## Which Session, when the store holds several

The store holds one file per Session and the root accumulates: the `#/states`
cards write under their own ids, and an id that has since changed leaves its
transcript behind. None of them is a candidate. **Resume asks for the Session it
is about to run, by name — `LIVE_SESSION_ID` — and never searches.**

`list()` exists and is deliberately not the selector. Choosing "the most
recently written" would invent a way to pick between conversations, and varnick
has no such concept: `CONTEXT.md` defines a **Session** as *one* durable
conversation and has no term for a set of them, because the product does not
have one. When it grows a way to hold several, choosing between them is that
feature's decision, not a rule left behind by this one.

## A read that failed is not an empty transcript

Start-up does not fall through to an empty conversation when the read fails. It
stops, says why, and offers a retry.

This is not caution for its own sake. An empty transcript is exactly what a
first run looks like, and the mirror cannot tell the two apart: on the next save
the transcript on disk is not a prefix of one that starts from nothing, so the
store takes it for a rewritten history — Compaction, or `/clear` — and
**replaces** the file. A failed read followed by one message would destroy the
transcript. Losing a day's work to a read that failed is precisely the loss the
mirror exists to prevent, so nothing starts until the read succeeds.

## Where the read happens

In start-up, not in an actor. The Harness holds `sessionInput` in context and
spawns the Session from it on entry to `agent.running`, so the transcript has to
be in hand before the machine is created. `pages/DesignedPage.tsx` owns start-up
and therefore owns this, the same way it owns reading the credential — and the
entry point it fills is the one the states page already uses to park a
conversation mid-flight. This ticket fills it from disk instead of from a
literal.

The read crosses the same seam as everything else the Harness does: one bridge
call, `read-session`, answered by the runtime, which is the process with a
filesystem ([ADR-0008](./0008-the-harness-runs-as-one-long-lived-host-process.md)).
It is the first call on that wire to answer with a payload rather than `ok: {}`,
and the answer is rebuilt message by message on the way in like every other one.

## Not decided here

The bare page runs the same machine with the same default Session id and does
not resume, so in live mode it would write over a transcript it never read. It
is the design-free behavioural surface rather than the app, and giving it a
resume or an id of its own is a change worth making deliberately rather than as
a side effect of this one.
