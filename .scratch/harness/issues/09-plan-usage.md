# 09 — Read real plan usage

**What to build:** The 5-hour and weekly plan-usage figures outside the chat become measurements, so a developer knows how much runway they have before starting something long. Today they are seeded and marked as such.

**Blocked by:** 03 (needs a Sandboxed session to ask), which in turn needs 15. Was unblocked; the research half is done and merged, and the edge to 03 was discovered by doing it — see the comments.

**Status:** done

**Realizes:** `subscription.reading`, `subscription.read`

**The source is the open question and it is most of the ticket.** Answer it before writing code. If no source exists, the honest outcome is deleting the strip rather than shipping a number that looks measured — and that is an acceptable way to close this ticket.

- [x] A real source is identified and proven, and the read reports itself as live — wiring it to a Sandboxed session is what ticket 03 completes. **Proven against a session varnick does not spawn**; see the amendment at the foot of this file
- [x] A failed read leaves whatever was last known — which may be nothing — and never invents a figure
- [x] `readSubscriptionUsage` is removed from the unimplemented list
- [x] The strip stops being marked as seeded when the run stops being seeded. Not because the marker reads the unimplemented list — it does not, it gates on the actor mode and reads the list only to name what is stubbed

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

**The wire, closed.** `read-plan-usage` is a third `ControlRequest` kind on the
channel ticket 05 built — the type is no longer called `TurnControl`, because a
plan-usage read is not a Turn and never becomes one. It goes renderer →
`callHarness` → `route_of` (Host, beside the Turn, for the second of the two
reasons that list exists) → one line onto the agent process's stdin. The read
itself happens *inside* `srt`: `runAgentHost` hands `serveTurns` the session it
already holds, and `reportFromSession` adapts that one. Only the two figures come
back out, as `{"kind":"plan-usage","requestId":…,"usage":…|null}` on the stdout a
Turn's events already use, told apart by which id they name.

**With no agent running the read refuses, and that is the design rather than a
gap in it.** There is no session to ask, so the host says so and the machine
keeps whatever was last measured — nothing at all, before the first run.
`a_read_with_no_agent_running_refuses_rather_than_starting_one` is the assertion
that holds that shut, and it needs no process precisely because the answer is
that there is none. `DesignedPage` therefore asks twice: at start-up, and again
on entering `agent.running`, which is the first moment the question can be
answered.

**Also found, and fixed in the comments rather than the code:** the seeded marker
does not decide visibility by reading `LIVE_NOT_IMPLEMENTED` — it gates on
`mode` and uses the list only to name what is stubbed. Two comments claimed
otherwise. The behaviour is right and the comments were wrong: in seeded mode the
warning is true whatever the list holds, and a list-driven marker would go quiet
on the last wiring while the surface still rendered seeded numbers. The fourth
acceptance box is reworded below to say what actually has to be true.

**Amended by ticket 23 — what the measurement actually measured.** The
`subscription_type: max` with both windows populated, above, was read by calling
`get_usage` against **the developer's own Claude Code session on this machine**,
which is authenticated by a Claude subscription. varnick was not, and could not
be: it spawned its agent with `ANTHROPIC_API_KEY` and nothing else, and an
API-key session reports `rate_limits_available: false` — which
`packages/harness/src/subscription.ts` correctly refuses, and always did.

So the source is real and the parser is right, and both were verified against a
configuration the product did not ship. Every criterion above still holds on its
own terms; what did not hold is the sentence a reader takes away from them, that
the strip could show a figure. In the shipped v1 it could not, in any
circumstance, and nothing said so.

The wire was measured; the plan behind it was not. That distinction is the
lesson worth keeping: a read proven end-to-end against a session that was to
hand is not proven against the session the product opens, and the two differed
in the one property the whole feature depends on.

ADR-0011 gives varnick a subscription token, ticket 22 gave a Credential a Kind,
and ticket 23 makes the read conditional on it — so the refusal path stops being
the only reachable outcome. The measurement that closes this properly is ticket
23's, taken against what varnick spawns.

One paragraph above is now out of date rather than wrong: `DesignedPage` still
asks twice, but the first ask has moved off mount and onto the credential
turning out to be a subscription. It was sent before anything had been read,
which was free when the read was possible in every configuration and possible in
none — and the moment the kind decides the answer, the first moment there is an
answer is the moment to ask.
