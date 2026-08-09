# 23 — Plan usage appears only under a subscription

**What to build:** The plan-usage strip shows real rolling windows when varnick is authenticated by a subscription, and is absent — not empty — when it is authenticated by an API key. Today it ships in both cases and can populate in neither.

**Blocked by:** 22.

**Realizes:** no new state path. The `subscription` region keeps its three states and gains a reason not to leave `unread`.

**Status:** ready-for-human — built and green on all seven commands. The one
criterion left is the measurement ADR-0011's last consequence asks for, which
needs a real subscription token and a running agent. See "The measurement, and
how to take it" at the foot of this file.

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

- [ ] Under a subscription, the strip renders real windows read from the running agent's session — **the human measurement below; everything up to the plan itself is wired and asserted**
- [x] Under an API key, `readSubscriptionUsage` is never invoked and the strip does not render
- [x] `#/states` still covers `subscription.read` with populated windows
- [x] `drive.ts` asserts both branches, and the API-key branch asserts the actor was not invoked rather than that the strip was empty
- [x] Ticket 09's record is amended to say what its measurement actually measured

Closes the feature half of ticket 19. Relates to story 70 and to ticket 09.

## Comments

**What was built.** One rule, in one place, read by the two things that must not
disagree about it: `hasPlanUsage(kind)` in `packages/core/src/domain.ts`, exported
for the same reason `canStartAgent` is. The `subscription` region's
`READ_SUBSCRIPTION` transition is guarded by it in both `unread` and `read`, with
no fallback — so `can({type:'READ_SUBSCRIPTION'})` is false under an API key and
the actor is never invoked. The plan-usage strip asks the same predicate and
returns nothing, so it is absent rather than empty and absent rather than hidden.
`DesignedPage`'s start-up ask moved from mount onto the credential turning out to
be a subscription, which is the first moment there is an answer to the question.

No new state, and the region still has exactly three. Under an API key it stays
`unread`, which is what `unread` already meant.

**Guarded, where the convention says "no handler".** CONTEXT.md's rule is that an
event a machine will not accept has no handler rather than a disabled control.
The reason it holds here is that it is about controls, not about handlers: a
guard with no fallback makes `can()` false, which is the same observable a
missing handler produces, and nothing binds `disabled` to anything. A missing
handler could not express this refusal anyway — it is decided by a fact in
context, not by which state the region is in.

Unlike `START`, this guard deliberately has no `startRefused`-style fallback. A
refused start is something a user asked for and must be told about; a plan-usage
read is asked for by the page on the user's behalf, and the whole of what there
is to report is a strip that is not there.

**`rate_limits_available` was not touched.** It stays the API telling the truth
about what it has, and a subscription session that reports false stays a real
failed read that leaves the last known figures standing. What changed is only
whether the read is attempted, never what it accepts.

**Two things asserted in `drive.ts` that could not be asserted before.** One
counter runs under both kinds in one loop, expecting one invocation under a
subscription and none under an API key — so the assertion of zero cannot pass by
counting a call that could never be made. And a credential re-read that comes
back an API key takes the strip away without discarding the figures measured
while there was a plan: nothing unmeasured them, and a machine that blanked them
on a credential event would be reporting a failed read that never happened.

Mutation-checked. Removing both guards fails exactly five assertions:

```
✗ under an API key, READ_SUBSCRIPTION is refused
✗ under an API key the plan-usage actor runs not at all
✗ and under an API key the region lands in unread
✗ and a re-read is refused from `read` as well as from `unread`
✗ so the region stays where it was rather than failing a read nobody could make
```

**What `drive.ts` cannot assert, and why.** It is component-free by construction,
and `chat-surface.tsx` cannot be imported outside Vite regardless — it reaches
`hooks.ts`, which reaches the Surface loader's `import.meta.glob`. So the strip's
gate is asserted as the predicate the component calls, exactly as the START
affordance is asserted as `canStartAgent` rather than as a button. That the
component *asks* is carried by the type checker, the lint boundary and the build,
and reviewed at `#/states → api-key-no-plan` — a new card that is the same
running session as `idle-empty` with an API key instead of a subscription, and
therefore the only place a human can see absent-not-empty without a token.

**`#/bare` grew the fourth region.** It showed `credential`, `sandbox` and
`agent` and never `subscription`, which was survivable while the read was
unconditional and is not now: the one thing plan usage is hard to tell apart from
outside is a read that was refused from a read that was never made, and both
leave the strip absent. The page now shows the region, the Credential Kind and
the figures, and its `READ_SUBSCRIPTION` button — filtered through `can()` like
every other — disappears under an API key, which is the gate itself on the
surface that has nothing covering for it.

**A scenario that had run ahead of the machines.** `reading-credential` parked
`subscription.reading` with no Credential Kind, which after this change is a
context the live machine cannot reach. It now carries `subscription` — the card
is a credential being read *again*, which is the only way both regions are busy
at once.

**CONTEXT.md needed no edit, which is worth noting rather than glossing.** Its
`subscription` line already said the region only runs under a subscription and
that nothing is rendered otherwise. That sentence was written alongside ADR-0011
and describes this ticket; it survived the take-back that removed
`credential.storing` for the same defect. It is true as of this commit, and it
was not before.

## The measurement, and how to take it

ADR-0011's last consequence is that one measurement proves this, and it is not
one an agent can take: it needs a real subscription token, a real agent process,
and a plan with real windows behind it.

```
claude setup-token
security add-generic-password -s varnick -a claude-oauth-token -w
bun tauri dev
```

The `-w` is last and carries no value — `add-generic-password` takes the keychain
as a positional argument, so a `-w VALUE` written before it writes into whatever
follows. `security` prompts instead.

What to look for, in order:

1. The strip is **absent** at first, and stays absent while the credential is
   read. Nothing renders where it would be.
2. It appears with two figures once the agent reaches `agent.running` and the
   read comes back — 5h and week, both numbers, no seeded marker. That is the
   measurement: an agent started and answering under a subscription token, with
   plan usage populated, which is the only evidence this ever worked.
3. Remove the token (`security delete-generic-password -s varnick -a
   claude-oauth-token`), leave the API key, and relaunch. The strip must not
   appear at all — not empty, not zeroed.

`#/bare` is where the two absences are told apart, which is why it grew the
fourth region in this ticket. It shows `subscription`, `credential kind`, and the
figures, and — because every button on that page is filtered through `can()` —
a `READ_SUBSCRIPTION` button that is simply **not there** under an API key. So:

- **button absent, kind `api-key`, region `unread`** — the read was never made.
  That is this ticket working.
- **button present, kind `subscription`, region `unread`, no figures** — the read
  was made and refused. That is a real failed read, and the first thing to check
  is whether the session reported `rate_limits_available: false`. It is not
  something to weaken; press the button and watch the region pass through
  `reading` to confirm.


## The branch this ticket left standing does not work either

Measured after merge, with a real subscription token: `rate_limits_available` is `false` and `subscription_type` is `null`. So the read refuses under a subscription too, and the strip is absent in every configuration rather than only under an API key.

Nothing here was wrong. The gate is correct, the actor is not invoked under an API key, and absent-not-empty is the right rendering. It is that the remaining branch was assumed to work and could not be tested until a subscription token existed — one does now, and it does not. Ticket 31 carries the decision.
