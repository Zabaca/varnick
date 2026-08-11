# 09 — The pre-release skill

**What to build:** the prose the orchestrator follows when the queue is empty, so
that cutting a pre-release is a procedure that can be read and adjusted rather
than behaviour buried in a command.

The skill owns the judgement and the command owns the mechanics. What the skill
decides: what this run actually changed for the developer, how to say it, which
tickets belong in the announcement and which are noise, and when a run has
produced nothing worth releasing. What it never does: promote. That is the
developer's control and the skill stops at leaving one pending.

Written as a skill because the release process is the thing most likely to be
adjusted after the first few nights, and adjusting English is cheaper than
adjusting a merge.

**Blocked by:** 06 — Cut a pre-release from the command line.

**Status:** ready-for-agent

- [ ] A skill exists that takes a finished run and leaves exactly one pending pre-release
- [ ] It states how to write an announcement from tickets, with the standard that it says what changed for the developer rather than what changed in the code
- [ ] It says what to do when a run merged nothing, or merged only work with no visible effect — a release nobody needs is not cut
- [ ] It says explicitly that promotion is never the agent's, and why
- [ ] It names what to record when a pre-release supersedes one the developer never promoted
- [ ] The orchestrator skill's final step points at it
