# 09 — Read real plan usage

**What to build:** The 5-hour and weekly plan-usage figures outside the chat become measurements, so a developer knows how much runway they have before starting something long. Today they are seeded and marked as such.

**Blocked by:** None — can start immediately.

**Status:** ready-for-agent

**Realizes:** `subscription.reading`, `subscription.read`

**The source is the open question and it is most of the ticket.** Answer it before writing code. If no source exists, the honest outcome is deleting the strip rather than shipping a number that looks measured — and that is an acceptable way to close this ticket.

- [ ] Usage is read from a real source and reports itself as live
- [ ] A failed read leaves whatever was last known — which may be nothing — and never invents a figure
- [ ] `readSubscriptionUsage` is removed from the unimplemented list
- [ ] The seeded marker beside the strip disappears on its own, because it reads that list. That is the acceptance criterion, not a follow-up chore

Covers story 70, and closes story 71 for these two numbers.
