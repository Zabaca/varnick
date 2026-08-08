# 09 — Read real plan usage

**What to build:** The 5-hour and weekly plan-usage figures outside the chat become measurements, so a developer knows how much runway they have before starting something long. Today they are seeded and marked as such.

**Blocked by:** 03 (needs a Sandboxed session to ask), which in turn needs 15. Was unblocked; the research half is done and merged, and the edge to 03 was discovered by doing it — see the comments.

**Status:** ready-for-agent

**Realizes:** `subscription.reading`, `subscription.read`

**The source is the open question and it is most of the ticket.** Answer it before writing code. If no source exists, the honest outcome is deleting the strip rather than shipping a number that looks measured — and that is an acceptable way to close this ticket.

- [x] A real source is identified and proven, and the read reports itself as live — wiring it to a Sandboxed session is what ticket 03 completes
- [x] A failed read leaves whatever was last known — which may be nothing — and never invents a figure
- [ ] `readSubscriptionUsage` is removed from the unimplemented list — waits on 03
- [ ] The strip stops being marked as seeded when the run stops being seeded. Not because the marker reads the unimplemented list — it does not, it gates on the actor mode and reads the list only to name what is stubbed

Covers story 70, and closes story 71 for these two numbers.

## Comments

**The source question is answered, and the answer is Path A.** A real source
exists: the Agent SDK's `get_usage` control request, the structured data behind
Claude Code's `/usage`, carrying `rate_limits.five_hour.utilization` and
`rate_limits.seven_day.utilization` as server-side percentages. Verified by
calling it on this machine, not by reading types — it returned a `max`
subscription with real figures in both windows. Also checked and ruled out: the
Anthropic Admin usage report (organization/API-key scoped, a different quantity),
the local CLI (no `usage` subcommand), and the SDK's browser and bridge
entrypoints (no usage surface). A locally-tallied figure was ruled out on
purpose: the plan window counts every device and claude.ai itself, so a local
tally drifts while looking identical to the real number.

`packages/harness/src/subscription.ts` parses that report and refuses rather
than defaulting — no plan, a null `rate_limits`, an absent window, or a null
`utilization` all throw, which is how "never invents a figure" is spelled. Eleven
tests, and a mutation check: replacing the refusal with `return 0` fails five of
them, so they discriminate rather than pass vacuously.

**What sent this ticket back behind 03.** The control request rides a live Agent
SDK session, and `query()` spawns a Claude Code executable. The first
implementation opened its own — which would have put an agent process on the
host *outside* srt, on launch. The clone's `.claude/settings.json` is writable by
the agent and SessionStart hooks run at session start, so that path executes
agent-authored code unconfined. That is precisely what ADR-0003 forbids and what
ticket 01's last criterion denies exists.

Cut before merge rather than sent back: `readSubscriptionUsage` now takes its
reader as a required parameter with no default, `reportFromSession()` adapts a
session someone else owns, and `readSubscriptionUsage` went back onto
`LIVE_NOT_IMPLEMENTED`. What remains is one wire from ticket 03's confined
session, and the strip stays honestly marked as seeded until then.

**Also found, and fixed in the comments rather than the code:** the seeded marker
does not decide visibility by reading `LIVE_NOT_IMPLEMENTED` — it gates on
`mode` and uses the list only to name what is stubbed. Two comments claimed
otherwise. The behaviour is right and the comments were wrong: in seeded mode the
warning is true whatever the list holds, and a list-driven marker would go quiet
on the last wiring while the surface still rendered seeded numbers. The fourth
acceptance box is reworded below to say what actually has to be true.
