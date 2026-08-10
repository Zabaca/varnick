# 64 — A tool call is prose, and what it returned is nowhere

**What to build:** Tool calls and subagents render as tool calls — brainless's `ClaudeToolCall`, with what the tool returned behind a disclosure — instead of as a line of text inside the answer.

**Blocked by:** None — shipped in the same pass that wrote this ticket.

**Status:** done

**Realizes:** no new state path. `TOOL_CALL` and `TOOL_RESULT` on the Session.

## The gap

varnick renders a Claude Code session with brainless components — `ClaudeHeader`,
`ClaudeMessage`, `ClaudeThinking`, `ClaudePrompt`. `ClaudeToolCall` was vendored
along with them and never imported, because there was nothing to give it.

A tool call reached Core as a string. `toolCallLine` composed `⚙ Read(src/a.ts)`
in the Harness and pushed it as a `delta`, so by the time anything in Core saw a
tool call it was prose in the middle of a Markdown document. Two consequences,
and the second is the larger one:

- The transcript could not tell a tool the agent **called** from a tool the
  agent **wrote about**. Both are `⚙ Read(src/a.ts)` in a text field.
- **What a tool returned existed nowhere in the product.** `beginTurn` read the
  runtime's `assistant` messages for the `tool_use` blocks they announced and
  dropped every `user` message, which is where the `tool_result` blocks live. Not
  in the window, not in the mirror, not in a log. A developer who wanted to know
  what a `Bash` call actually printed had to read the SDK's own transcripts off
  disk — the same answer ticket 62 was written about, one layer along.

`ClaudeToolCall` takes `tool`, `arg`, `result` and `status` as four separate
props. Three of the four did not exist.

## What was built

### The Turn reads the half of the stream it was discarding

`beginTurn` gained a `user` case. Every `tool_result` block becomes a
`tool-result` update carrying the text, whether it errored, and the
`tool_use_id` it answers.

**Paired by id, never by arrival order.** A Session runs tools concurrently, so
the n-th result is not the n-th call. `agent.ts` already pairs this way in the
containment probe and its comment records what getting it wrong cost; this is
the same rule on the path ordinary Turns take.

The result is split into a line and the rest — `result` is the first non-blank
line, `detail` is everything, capped at 4 000 characters. A `Read` of a large
file comes back as the whole file, and the mirror's whole virtue is that `cat`
and `jq` read it.

### A tool call ends the message above it

This is the part that changes an existing contract rather than adding to one.

A tool call used to *join* the run's accumulated text, which is what made a Turn
one message. It now ends that accumulation: the words before the call are one
entry, the call is the next, and the answer carries on underneath. Said, did,
said — which is what the rendering needs and what a reader expects.

Two consequences worth knowing before reading the code:

- **`done.text` is the tail of the answer, not the whole of it.** Everything
  before the last tool call is already in the transcript as its own entries.
- **`done` no longer falls back to the runtime's `result` field just because the
  accumulation is empty.** A Turn that ended on a tool call arrives with nothing
  accumulated and has said plenty; the fallback would have posted the entire
  answer a second time under the pieces already on screen. It is gated on a
  `produced` flag now, so the case the fallback exists for — a cached or instant
  answer that streamed nothing at all — still works.

`turn.answering.onDone` gained a guard for the same reason: a Turn whose last
act was a tool call has no trailing text, and appending it unconditionally wrote
a blank agent message to the mirror, where it reads as the agent answering with
silence.

### The transcript carries the call

`Message` gained `tool?: ToolCall`. Beside `text` rather than instead of it, and
that is what makes the change compatible in both directions: `text` still holds
the one-line form, so a mirror written now still reads as a conversation under
`cat`, and a mirror written before — where every tool call is text and nothing
carries the field — still loads and still renders exactly as it did.

`TOOL_RESULT` is the only event in the product that **changes** a transcript
entry instead of appending one. The argument for allowing it is on
`withToolResult`: a tool call is one fact that arrives in two pieces, and
writing them as two entries would put the answer to a tool a long way below the
tool with everything the agent said in between.

### Subagents are not a special case

`Task` is a tool. It arrives on the same path, is named by its description, and
is answered by the report the subagent returned — so it renders in the same
component as a `Read`, with no second mechanism.

The live panel (`RunningTasks`) and the timing line are unchanged and still
carry what a tool result has no field for: elapsed time, tokens, and a tool
count.

### A retry sent the tool line as the prompt

Caught by re-reading rather than by a failure, and it is the sharpest
consequence of tool calls becoming entries. The Turn's prompt was
`messages.at(-1)`, which was correct while a Turn appended nothing to the
transcript until it ended: on entry, the developer's message was always last.

Tool calls are appended as they happen now. So a Turn that called a tool and
then failed leaves `⚙ Read(src/a.ts)` at the end of the transcript, and
`RETRY_TURN` re-enters the invoke and reads it — sending the tool line to the
agent as the prompt. It is the last user message now, and `drive.ts` asserts
both attempts send what was typed.

## Found on the way

`persist` in the Session mirror rebuilt every message as `{id, role, text}` and
nothing else, so **`attachments` reached the type and the serialiser and never
reached the disk**: every mirrored message said no pictures went with it. The
new field would have been lost the same way, in the same line of code. Both are
carried through now, and a tool call's argument, result and detail are redacted
against the secrets list on the same pass the message text is — a tool result is
the likeliest place in a transcript for a secret to appear, and it arrives from
the runtime rather than from anything anybody typed.

## Three defects a review found, and one lesson

All three were in the first version of this work and are fixed. They are
recorded rather than quietly corrected, because two of them are the same
mistake in different places and the pattern is the point.

**The read path dropped everything the write path had just learned to keep.**
`transcriptAnswer` in `bridge.ts` rebuilt each message as `{id, role, text}`, so
a restored transcript came back with every tool call flattened to the one-line
form and rendered as Markdown prose — a relaunch undid the feature. This is the
identical defect found in `persist` and written up above as "found on the way":
the write path was fixed and the read path one layer along was never looked at.
`attachments` was lost there too, which means the fix reported above was half a
fix. Both doors into the mirror now use the store's own `parseStoredTool`, so
they cannot disagree about what a stored tool call is.

**The unprompted path kept a preference that had silently become wrong.**
`pumpUnprompted` posted `event.text || text`, under a comment stating that
`event.text` was the run's whole accumulation, tool calls included. Making a
tool call end that accumulation falsified the comment and the code under it: an
unprompted answer that used a tool half way through was posted as its final
paragraph. It hid well, because an answer ending *on* a tool call leaves
`event.text` empty and the fallback produced the right result — the broken case
was the ordinary one and the working case was the edge.

**The redaction banner could not see the fields the redaction now covers.**
`restoredTranscript` asked `message.text.includes(REDACTED)`. A transcript whose
only redacted value sat in a tool result restored with no warning, telling the
developer the record was complete while they read one that was not.

The lesson is one line: **a field added to a record has to be followed through
every door the record travels through**, and this change had four — write,
read, redact, and the flag that describes the redaction.

## Boxes

- [x] A tool call renders as a tool call, not as a line of Markdown
- [x] What the tool returned is in the transcript, one line of it visible
- [x] The rest of the result is behind a keyboard-operable disclosure
- [x] A tool that has not answered yet says it is running
- [x] A tool that failed says so, rather than leaving a reader to infer it
- [x] Results are matched to calls by id, with concurrent tools proved in a test
- [x] A subagent renders as a tool call
- [x] The call and its result survive into the Session mirror, readable by `jq`
- [x] And survive the *round trip* — a relaunch restores them as calls, not as
      the one-line form rendered as prose
- [x] A mirror written by a build that predates the field still loads
- [x] A secret printed by a tool does not reach the mirror, and a transcript
      redacted only inside a tool call still raises the banner
- [x] An unprompted answer that used a tool arrives whole
- [ ] The `⚙ … started` timing line and the `Task` tool call are both shown, and
      say overlapping things. Folding the timing figures into the tool result
      needs a correlation between `task_id` and `tool_use_id` that the stream
      may not offer; left alone rather than guessed at.
- [ ] A subagent's *own* tool calls are not nested under it. Nothing filters
      `parent_tool_use_id`, so they arrive as siblings of the `Task` that
      spawned them and interleave beneath it while it still reads `running…`.
      "`Task` is a tool" gives the parent entry and does not give nesting.
- [ ] A result arriving after its Turn ended never reaches the mirror.
      `TOOL_RESULT` has no `saveTranscript` — deliberately, because a save per
      result means a full-file rewrite per result — so those calls stay
      `"status":"pending"` on disk. Results that arrive *during* a Turn are
      covered by the boundary save, which is almost all of them.

## Verified

- `bun test packages` — 738 pass, 2 fail (the containment probes, which need to
  write under `$HOME` and are denied to a confined agent; they fail the same way
  on a clean tree).
- `bun packages/core/scripts/drive.ts` — 728 assertions.
- `tsc --noEmit` on both packages, and `eslint .`, clean.
- Launched as a Preview from this worktree, which is what compiles the Rust.
