# 40 — A compaction is heard, not asked for

**What to build:** The transcript follows a compaction whichever way it happened — the developer asking, the CLI's own `/compact`, or the window filling up with nobody watching.

**Blocked by:** 37, 39.

**Status:** done.

**Realizes:** removes `turn.compacting`; no state path added.

## Why this exists

Ticket 39 left four commands that were varnick's copies of things the CLI also
does, and named the better answer: listen rather than duplicate. `/clear` went
first (`b9ba77b`, `af5c2ad`). This is `/compact`, and it turned out to be the
one with a live bug behind it rather than a tidiness argument.

**An auto-compaction has no command at all.** It fires because the context
window filled, mid-answer, with nothing on screen that says so. It rewrites the
*agent's* context whether or not varnick joins in — so varnick kept showing a
conversation the agent had already replaced. Same disagreement `/clear` had,
with nobody to blame and no way to notice. The CLI's own `/compact` is the
second way in, and varnick's menu could not hear that one either.

## What it does now

- **`PostCompact` reports every compaction**, not only the one varnick asked
  for. It was `trigger === 'manual'`, on the reasoning that rewriting the
  transcript because the window filled would be a rewrite nobody requested. The
  opposite was true: it had already happened.
- **`COMPACTED` is a report at the machine's root**, beside `CLEAR` and for the
  same reason. It arrives *during* a Turn by construction — a context fills
  while an answer is being written, and the CLI's `/compact` is itself a Turn —
  so a state that could refuse it would refuse it in the only circumstance it
  occurs in.
- **The meter is a reading or it is nothing.** `tokensUsed` is measured after
  the rewrite and may be `null`, which leaves the meter alone. `0` was the first
  implementation and is the worst available figure: it says the conversation
  costs nothing.
- **The summary does not end the Turn it arrived during.** The agent carries on,
  on a context it has just rewritten, and what it says next belongs after the
  summary rather than instead of it.

## What was removed

`COMPACT`, `turn.compacting`, the `compactSession` actor, the `compact-session`
control request, its Rust arm, its bridge route, `COMPACT_COMMAND`, the
`compaction` and `compaction-unmeasured` failure tags, `compactionFailureMessage`,
`beginCompaction` and the two-halved `CompactionRun`, `compactError`, and the
`failCompact` seed control.

Three suites went with them — fifteen tests in `agent.test.ts`, a Compaction
suite in `turn.test.ts`, and three blocks in `drive.ts`, including the hostile
implementation that rewrote the transcript in place and then threw. That last
one is worth naming: it was a good test of a hazard that **no longer exists**,
because there is no actor holding the transcript to rewrite. The property it
defended is now structural rather than asserted.

`#/states` lost the `compacting` and `compact-failed` cards and gained one:
a transcript after a compaction, which is what a developer actually sees.

## What survived, deliberately

- **ADR-0003's argument, without its instance.** A summary produced by a session
  that is not *this* session frees no context at all. That is why Compaction was
  a control request; it is still why nothing here opens a session. The ADR is
  amended rather than contradicted.
- **`contextTokens()` on the Session port.** Added for Compaction, kept because
  the alternative is a meter showing a figure nobody measured.
- **The mirror's replace path.** A compaction rewrites history rather than
  extending it, so `COMPACTED` raises `SAVE`. ADR-0007's amendment said the
  opposite — that a compaction must *not* save — and it was right about a
  compaction that **failed**, which varnick can no longer see.

## Watch for

- **`/model` and `/effort` are the two duplicates left**, and they are a product
  decision rather than a cleanup. Deleting them removes varnick's ability to
  choose either: the footer's model becomes a report of what the last Turn ran
  on, and effort leaves the footer entirely because nothing announces it. That
  is measured, not assumed — `initializationResult()` carries no current model
  and no effort, and the settings resolver reads the file cascade rather than
  the live flag layer `/effort` writes to. **varnick's footer can already lie
  today**, because the CLI's `/effort` is in the menu.
- **A compaction with no Turn to stamp is dropped**, like every other message
  with no Turn. That case does not happen — nothing fills a context when nothing
  is running — but it is asserted rather than assumed.

- [x] An auto-compaction reaches the window and the transcript follows
- [x] The CLI's own `/compact` does the same, through the same path
- [x] A compaction is accepted mid-Turn and does not end the Turn
- [x] An unmeasured compaction leaves the meter alone rather than reading zero
- [x] varnick can no longer ask for one, at the machine, the bridge and the host
- [x] `bun test packages`, `bun run drive`, typecheck, lint and `cargo test` green

Asked for by the developer: *"why are we not doing compact model efffort? i
think these are clear."*
