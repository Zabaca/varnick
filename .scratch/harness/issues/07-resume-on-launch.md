# 07 — Resume the Session on launch

**What to build:** Quitting and relaunching continues the conversation instead of starting over. A day's work is not a day's conversation lost, a crashed unattended run is recoverable rather than opaque, and the transcript is intact after the agent writes code that does not compile — that last case is the one the mirror exists for.

**Blocked by:** 06 (needs the mirror to read from), 15 (the renderer cannot reach the mirror without it).

**Status:** ready-for-agent

**Realizes:** `turn.idle` entered with a restored transcript — the `#/states → idle-empty` card, with messages

The entry point already exists: the Harness spawns the Session from an input the states page uses to park a conversation mid-flight. This ticket fills it from disk instead of from a literal.

**Decide and record:** what happens when a Turn was in flight at the moment of the crash. The honest options are resuming as `turn.idle` with the partial folded into the transcript, or resuming as `turn.failed` with a reason. Not `sending` — nothing is in flight, and a state that lies about a live request is worse than either.

- [ ] Quitting mid-conversation and relaunching shows the same transcript
- [ ] Killing the process and relaunching shows the same transcript
- [ ] A Userspace module that does not compile leaves the transcript readable
- [ ] The in-flight-at-crash decision is recorded, not just implemented

Covers stories 22, 23, 24, 25.

## Comments

**Decide which store the resumed conversation comes from, and say so.** The
mirror is deliberately not a byte-faithful copy: ticket 06 redacts secret values
and credential shapes on the write path, so a message in the mirror can differ
from what was actually said. Reading the conversation back out of the mirror
therefore replaces the original text with `[redacted]` in the live Session —
which may be right, but nobody has decided it. The Agent SDK keeps its own copy
for resumption; the mirror exists to survive a build the agent just broke. Name
which one resumption reads, and if it is the mirror, say in the surface what a
developer is looking at.
