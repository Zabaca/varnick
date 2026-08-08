# Read real plan usage

**Status:** ready-for-agent

**Realizes:** `subscription.reading`, `subscription.read`

`readSubscriptionUsage` returns `{ fiveHourPct: 68, weeklyPct: 41, source: 'seeded' }`. This slice finds a real source for the 5-hour and weekly windows and returns `source: 'live'`.

**The source is the open question and it is the whole ticket.** If no source exists, the honest outcome is to delete the strip rather than ship a number that looks measured. Answer that before writing code.

The machine already handles the failure correctly: a failed read leaves whatever was last known — which may be nothing — and never invents a figure. Keep that.

**Done when** `source` is `'live'`, `readSubscriptionUsage` is removed from `LIVE_NOT_IMPLEMENTED`, and the seeded marker beside the strip disappears on its own because it reads that list. That marker going away is the acceptance criterion, not a follow-up chore.

Covers story 70, and closes story 71 for these two numbers.
