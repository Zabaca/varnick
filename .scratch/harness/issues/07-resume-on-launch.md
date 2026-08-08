# Resume the Session on launch

**Status:** ready-for-agent

**Blocked by:** 06

**Realizes:** `turn.idle` entered with a restored transcript — the same card as `#/states → idle-empty`, with messages

Launch currently spawns a Session with a hard-coded `sessionId` and an empty transcript. This slice reads the last Session from the host-side mirror and spawns with it, so relaunching continues rather than starts over.

The entry point already exists: the Harness spawns the Session from `context.sessionInput`, which the states page uses to park a conversation mid-flight. This slice fills it from disk instead of from a literal.

Decide and record: what happens when a Turn was in flight at the moment of the crash. The honest options are resume as `turn.idle` with the partial folded into the transcript, or resume as `turn.failed` with a reason. Do not resume into `sending` — nothing is in flight, and a state that lies about a live request is worse than either.

**Done when** quitting mid-conversation and relaunching shows the same transcript, killing the process shows the same transcript, and a Userspace module that does not compile leaves the transcript readable — that last one is the case the mirror exists for.

Covers stories 22, 23, 24, 25.
