# 33 — The agent never resumed the conversation the window was showing

**What to build:** A relaunched varnick hands the agent the conversation it was in, so what the developer reads and what the agent remembers are the same conversation.

**Blocked by:** None.

**Status:** done.

**Realizes:** no new state path. Resuming is something that happens on the way into `agent.running`, and the two facts it produces are context.

## The defect

A Session is persisted twice and only one of the copies was ever read back. The mirror gave varnick the transcript to *display*; the Agent SDK's own store is what the agent *remembers* — and **nothing anywhere passed `resume`**. Every launch opened a new conversation behind a window showing the whole history.

The developer found it in the plainest possible way: told the agent their name, restarted, asked for it back, and was told *"nothing in this session identifies you."*

Measured before the fix: **seven session transcripts** under `.varnick/claude/projects/…`, one per launch of the app, none of them ever reopened.

[ADR-0009](../../../docs/adr/0009-resume-reads-the-mirror.md) states that "the SDK's copy is what the agent resumes from, its context and its continuity" as though it were a description. It was an intention, and nothing implemented it. The ADR is amended rather than left standing, because a document asserting a behaviour the code does not have is worse than one that never mentioned it.

## Two readings that were wrong, recorded because both cost time

**"Every Turn is a fresh conversation."** Read off a screenshot of two consecutive prompts, one of which had a restart between them that the screenshot could not show. It sent the investigation at the empty `session_id: ''` on the queued user message, which is *optional* on `SDKUserMessage` and was never the cause. Corrected by the developer.

**"The app hangs at start-up because the tokio pool is exhausted."** Eleven threads were parked in `AgentProcess::await_exit`, which is one per page load and does look alarming — but `Condvar::wait` releases the lock, and the blocking pool is 512. That hang is still unexplained and is not this ticket.

## What it does now

The agent host reads `session_id` off the SDK's `init` message — the same message the runtime report (ticket 32) already parses — writes it to `.varnick/claude/last-session.json` **before the turn is answered**, and passes `resume: <id>` on the next launch.

Three decisions inside that, each with a reason that is not obvious:

- **The pointer is used only if its transcript still exists.** `resume` against an id the CLI has forgotten fails the whole session, so a stale pointer would turn "the agent forgets" into "the agent will not start" — worse than the defect. Absent, unreadable and orphaned pointers are all a fresh conversation.
- **The transcript is found by id, not at a computed path.** The CLI derives its per-directory folder name from the working directory by a rule it owns and does not document. A mangling guessed at here would silently stop matching the day that rule changed, reporting "nothing to resume" for a store that is right there. One shallow directory scan depends only on the id.
- **`resumed` rides the runtime report and is not inferred.** The init message describes the session the CLI ended up in and says nothing about how it got there. varnick knows, because varnick asked — and the window shows it, so a restored transcript over a fresh agent can never fail to say so.

The pointer lives in the clone, which makes it agent-writable. Stated rather than discovered: `CLAUDE_CONFIG_DIR` is already in the clone, so the agent can already edit the transcript this points at. A pointer beside a store you can edit is not a new capability.

## The measurement

Not a unit test, and it could not have been one: a test that opened a session would put a Claude Code process on this machine outside `srt`, which is the one thing [ADR-0003](../../../docs/adr/0003-containment-wraps-the-process-tree.md) says never happens. So it was measured on the running app, twice — once for the code and once for the mechanism.

```
LIVE AGENT --resume=63ec1343-21db-4396-83ae-07456bf8ea1c
last-session.json  {"sessionId":"63ec1343-21db-4396-83ae-07456bf8ea1c"}
```

The relaunched app carried the flag, appended to the existing transcript rather than minting an eighth, and answered "what's my name" with "James."

## Watch for

- **The two halves must not diverge.** The mirror is keyed by `LIVE_SESSION_ID`, which varnick chooses; the agent's continuity is a UUID the CLI mints. If one is restored and the other is not, the panel's `memory` row is the only thing that says so — do not remove it to tidy the panel up.
- Nothing here changes the Sandbox policy, the write boundary, or any containment claim.
- The agent's own claim in conversation that it "won't remember this in future sessions" is a prior about Claude Code, not a report about varnick, and is now wrong.

- [x] A relaunched varnick passes `resume` with the id of the conversation it was last in
- [x] The pointer is written before the first turn settles, so a crash mid-answer keeps it
- [x] A missing, unreadable or orphaned pointer starts a fresh conversation rather than failing the launch
- [x] The window says which of the two happened
- [x] ADR-0009 no longer asserts a resumption that did not exist
- [x] `bun test packages`, `bun run drive`, typecheck and lint green

Found by the developer, who told the agent their name and restarted.
