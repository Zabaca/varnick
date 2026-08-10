# 62 — A Turn that spawns subagents looks exactly like one that hung

**What to build:** While subagents run, the window says which and how far along; after they finish, the transcript still says they ran.

**Blocked by:** None — shipped in the same pass that wrote this ticket.

**Status:** done

**Realizes:** no new state path. `TASKS_REPORTED` on the Session.

## The gap

A `/mattpocock-skills:code-review` spawned four subagents and ran for ten
minutes. The window showed one `⚙ Agent(Standards review of ticket 55)` tool
line and then a spinner — the same spinner a hung process shows.

The developer asked three times whether anything was still happening. Answering
it meant reading the SDK's own transcripts off disk from outside the app:

```
.varnick/claude/projects/…/<session>/subagents/agent-*.jsonl
```

That is the state of the art for "is it working?" in a product whose entire
subject is watching an agent work.

## Nothing was missing from the SDK

All four of these were arriving and being discarded:

| message | carries |
| --- | --- |
| `system:task_started` | `task_id`, `description`, `subagent_type` |
| `system:task_progress` | `usage: { total_tokens, tool_uses, duration_ms }` |
| `system:task_updated` | `patch: { status, error }` |
| `system:background_tasks_changed` | every live task — **replace** semantics |

`beginTurn`'s `system` case answered `hook_response` and returned `[]` for
everything else, so each of them fell through a `default` that meant "not
interesting". They were interesting.

## Two halves, because they answer different questions

**The live set** answers *"is it still working?"* and is ephemeral. It is
emptied when the Turn ends — including when the Turn is interrupted, which is
the case that matters: the message that would have said the subagents stopped
belongs to a Turn nobody is listening to any more, so without an explicit clear
they would sit on screen forever.

**The transcript lines** answer *"what happened while I was away?"* and are
durable. A start line and a terminal line per subagent, carrying elapsed time,
tokens and tool count, joining `delta`, `tool` and `hook` in the answer — so
they survive an interrupt and reach the Session mirror.

A line per `task_progress` was rejected for the reason the `hook_response`
filter exists: it arrives every few seconds per task, and a transcript is not a
meter.

## What was decided, and why

- **Fold host-side, not in Core.** `task_progress` *patches* an entry rather
  than replacing it, so Core would need the same map to apply it. Two copies of
  a merge rule is one too many; what crosses the wire is always the whole set.
- **Replace, never merge** — the SDK's own word for `background_tasks_changed`,
  and the empty array is the ordinary way a panel empties rather than a
  malformed event.
- **An entry with no `task_id` is dropped rather than defaulted.** The id is
  what a later patch is matched against, so an entry without one could never be
  updated or removed and would sit in the panel until the Turn ended.
- **A figure nobody reported is left out rather than shown as zero.** `0 tools`
  beside a spinner reads as stuck; an absent field reads as not-yet-said, which
  is true. Elapsed is always shown, because it is honestly zero.
- **`RunningTasks` is a sibling of `ClaudeThinking`, not a prop on it.** That is
  a brainless component; this is varnick's fact.

## Watch for

- The live set is Session state and not Harness state, unlike the Runtime Report
  beside it. It **does not** outlive its Turn, and that asymmetry is the point.
- It does not save the transcript. A subagent starting is not a Turn boundary,
  and writing the mirror on a message that arrives every few seconds per task
  would put a file write on a progress meter.
- Descriptions and subagent types are third-party text — whoever wrote the
  prompt or the agent definition — and are capped like every other name crossing
  into Core.

- [x] A running subagent is listed with elapsed, tokens and tool count
- [x] Two subagents keep the order they started in
- [x] One that finishes leaves the list
- [x] An interrupted Turn takes its subagents with it
- [x] A start line and a finish line reach the answer, and therefore the mirror
- [x] `failed` and `killed` say so rather than reading as finished
- [x] Progress writes no transcript line
- [x] `RunningTask` is named in `CONTEXT.md`

Found while watching a code review the developer could not tell from a hang.
