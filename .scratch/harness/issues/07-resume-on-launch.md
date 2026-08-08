# 07 — Resume the Session on launch

**What to build:** Quitting and relaunching continues the conversation instead of starting over. A day's work is not a day's conversation lost, a crashed unattended run is recoverable rather than opaque, and the transcript is intact after the agent writes code that does not compile — that last case is the one the mirror exists for.

**Blocked by:** 06 (needs the mirror to read from), 15 (the renderer cannot reach the mirror without it).

**Status:** done

**Realizes:** `turn.idle` entered with a restored transcript — the `#/states → idle-empty` card, with messages

The entry point already exists: the Harness spawns the Session from an input the states page uses to park a conversation mid-flight. This ticket fills it from disk instead of from a literal.

**Decided and recorded:** [ADR-0009](../../../docs/adr/0009-resume-reads-the-mirror.md). Resume reads the **mirror**, redactions and all, and the surface says when it is showing a redacted record. A Turn in flight at the crash resumes as **`turn.idle`** — and the decision cost nothing, because the mirror is written at Turn boundaries and holds only complete messages, so a Turn that was still streaming left nothing on disk to fold in. The transcript ends at the last completed boundary.

- [x] Quitting mid-conversation and relaunching shows the same transcript
- [x] Killing the process and relaunching shows the same transcript
- [x] A Userspace module that does not compile leaves the transcript readable
- [x] The in-flight-at-crash decision is recorded, not just implemented

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
