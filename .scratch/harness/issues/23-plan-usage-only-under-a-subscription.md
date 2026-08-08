# 23 — Plan usage appears only under a subscription

**What to build:** The plan-usage strip shows real rolling windows when varnick is authenticated by a subscription, and is absent — not empty — when it is authenticated by an API key. Today it ships in both cases and can populate in neither.

**Blocked by:** 22.

**Realizes:** no new state path. The `subscription` region keeps its three states and gains a reason not to leave `unread`.

**Status:** ready-for-agent

## What is true today

`packages/harness/src/subscription.ts` refuses when `rate_limits_available` is false, and its own comment records that this is false "for API-key, Bedrock, and Vertex sessions, where no plan exists to have windows". Since varnick spawns an API-key session, that refusal is the only outcome that has ever been possible in the shipped product.

The refusal is honest — a failed read leaves the last known value, which is nothing, so the strip renders empty rather than inventing a figure. But it is permanently empty and nothing says why. Ticket 09's measurement of `subscription_type: max` with both windows populated was taken against the developer's own Claude Code session, not against what varnick spawns.

## What changes

`READ_SUBSCRIPTION` is only sent, and `readSubscriptionUsage` only invoked, under a Credential Kind of `subscription`. Under an API key the region stays `unread`, the actor never runs, and the strip is not rendered at all.

Absent rather than empty is the whole point. An empty measurement reads as "we tried and got zero"; nothing at all reads as "this does not apply", which is the truth. Ticket 09 established that removing the strip was an acceptable outcome, so removing it *conditionally* is strictly better than what it was prepared to accept.

## Watch for

- **A region that stays `unread` is not a broken region.** Do not add a fourth state meaning "not applicable" — the kind is already in context and the view can read it, and a state for a fact that is not a state is exactly what CONTEXT.md's state-name discipline is for.
- **Do not weaken `rate_limits_available`.** It is the API telling the truth about what it has. If a subscription session ever reports false, that is a real failed read and must stay one.
- The states page is coverage-checked. `subscription.read` still needs its card and still needs seeded windows — a scenario carrying a state with no data is not an honest rendering of it.
- Every control still comes from `snapshot.can()`; a strip that is not rendered must be a strip the view was not asked for, not one hidden by CSS.

- [ ] Under a subscription, the strip renders real windows read from the running agent's session
- [ ] Under an API key, `readSubscriptionUsage` is never invoked and the strip does not render
- [ ] `#/states` still covers `subscription.read` with populated windows
- [ ] `drive.ts` asserts both branches, and the API-key branch asserts the actor was not invoked rather than that the strip was empty
- [ ] Ticket 09's record is amended to say what its measurement actually measured

Closes the feature half of ticket 19. Relates to story 70 and to ticket 09.
