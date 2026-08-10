# 61 — An answer nobody asked for never reaches the window

**What to build:** Everything the agent says reaches the transcript, including what it says without being prompted.

**Blocked by:** None — can start immediately.

**Status:** done

**Realizes:** no new state path, unless the answer turns out to need one.

## The defect

**Two complete agent answers were produced, recorded by the SDK, and never
appeared in the Session mirror or the window.** Measured from both sides of the
same conversation:

```
04:32:23  assistant  "Ticket 55 — the review list waits…"          → mirror m101 ✓
04:42:22  user       <task-notification> subagent completed
04:42:32  assistant  "Agent reports done. Verifying rather than…"    ✗ lost
04:43:03  assistant  "Verified, and it corrected me on something…"   ✗ lost
04:46:34  user       "the agent did complete. did you not get one?"  → mirror m102 ✓
04:46:43  assistant  "I did get it…"                                 → mirror m103 ✓
```

The two that vanished are the two the developer did not prompt. A subagent
finished, its completion arrived as a task notification, the agent answered it
twice — and the window showed nothing between one typed message and the next.

## Why it happens

Every mirror write is a Turn boundary raised by the Session machine:
`saveTranscript` at `packages/core/src/machines/session.ts:154`, reached at
`:266`, `:400`, `:413` and `:462`. Each of those sits on a Turn that **Core
started**, from a `SEND`.

An agent turn begun by an event has no `SEND`. There is no Turn in Core, so no
boundary, so no save — and nothing renders it either. The answer exists only in
the SDK's own transcript, which nothing in varnick reads back during a session.

This is not a mirror bug narrowly. The window is equally blind: the machinery
that displays an answer and the machinery that persists it are the same
machinery, and both are keyed to a prompt.

## Why it is worse than a missing message

**The developer is told a lie by omission, and then argues with the agent about
it.** That is exactly what happened: the developer asked *"did you not get a
completion?"*, the agent correctly answered that it had and had already
reported, and from the window the agent looked wrong. An observer reading the
mirror — including a future varnick reading its own history — would conclude
the agent hallucinated a report it never made.

**And the content is not filler.** The second lost answer carried a correction
that had been wrong all session:

> *"I was wrong about the 87 failures. Setting `TMPDIR` to a directory inside
> the clone makes them go away: the live tree gives 614 pass / 2 fail, not 87.
> The failures were the Sandbox denying `/tmp`."*

That is ticket 53's answer, produced and discarded.

## What else arrives this way

Task notifications are the case that was caught, and they are not the only
prompt-free thing in the system. Anything that reaches the agent without the
developer typing has the same shape, and each should be checked rather than
assumed:

- a subagent completing (measured — this ticket)
- a background `Bash` command finishing
- ticket 56's merge report, which is *designed* to arrive unprompted
- ticket 57's staleness report, likewise

**Tickets 56 and 57 both plan to tell the agent things this way.** If this is
not fixed first, both will land features whose entire user-visible half is
silently dropped, and they will look like they work because the agent will
receive the report and act on it.

## The shape of the answer

An agent answer is a Turn regardless of what started it. What is missing is a
way for one to *begin* other than `SEND` — the machine needs a boundary it can
raise for a Turn the world started, and the transcript needs to hold a message
whose prompt was not a user's.

Two constraints worth stating before anyone designs it:

- **Do not fabricate a user message to carry the trigger.** A task notification
  rendered as something the developer said is a transcript that lies in a
  second way. It is the same rule the compaction report and `COMMANDS_REPORTED`
  already follow: something the world did, accepted where the machine is,
  attributed to the world.
- **The window must show it arriving.** A message that appears in the scrollback
  with no visible cause reads as the agent talking to itself. Whatever renders
  it should say what prompted it — *"subagent finished"* — because the developer
  needs to know why the agent started talking.

## Watch for

- The SDK transcript is the ground truth here and varnick already has it on
  disk. Reading it back to recover lost answers is a repair, not a fix — the
  answer must reach the window as it happens.
- A prompt-free Turn must still be interruptible, and must still count toward
  the context meter.
- Check whether the *runtime report* and hook failures (ticket 58) reach the
  window, since they arrive by a similar path.

- [x] An agent answer triggered by a subagent completion appears in the window
- [x] It is written to the Session mirror
- [x] It survives a restart and resume like any other message
- [x] The transcript does not attribute the trigger to the developer
- [x] The window says what prompted an unprompted answer
- [x] **It appears when it happens, rather than at the start of the next Turn**
- [ ] A prompt-free Turn can be interrupted

## How it arrives when it happens

A first pass shipped the answer arriving at the *start of the next Turn* — not
lost, but useless to the person it is for: **a developer who is waiting is
precisely the one who types nothing.** "It appears when you next speak" is not a
fix for waiting.

So there is a pump, invoked on `agent.running`, alive for exactly as long as
there is an agent to hear from and stopped however that state is left.

**It reads its own queue.** The host sorts events on the way in by whether the
`turnId` carries the unprompted stamp, so a Turn and the pump can never hold an
event the other is waiting for. That is not tidiness: a wait lasts up to
`EVENT_WAIT` — fifteen seconds — in the host, so one already in flight when a
Turn starts could otherwise swallow that Turn's first event. Splitting the queue
means the window does not exist rather than being small enough to argue about.

`is_unprompted` in `src-tauri/src/agent.rs` is where the sorting happens, and it
duplicates the prefix across the language boundary like every other constant
that crosses it.

Found by comparing the SDK's own transcript against the Session mirror after the
developer asked why the agent had not reported a completion it had, in fact,
reported twice.
