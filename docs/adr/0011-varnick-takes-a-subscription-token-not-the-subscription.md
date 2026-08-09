# varnick takes a subscription token, not the subscription

varnick authenticates with **either** an Anthropic API key **or** a Claude subscription, and the host decides which by what it finds. The kind is not a preference the developer sets in two places; it is a property of the credential that was resolved, and it travels with the reading.

A credential therefore has a **kind** as well as a **source**. `source` — `keychain` or `env` — says which store answered, and already existed. `kind` — `api-key` or `subscription` — says what was in it, and decides one thing:

- **Which variable the agent is spawned with.** `ANTHROPIC_API_KEY` for a key, `CLAUDE_CODE_OAUTH_TOKEN` for a subscription. Both are first-class authentication variables to the Agent SDK, listed side by side in its own credential table, so this is one substitution rather than a second authentication path.

This decision originally claimed a second thing — *whether plan usage exists to be read* — and that claim is withdrawn. It was false in the only configuration this decision produces; see "What the subscription token turned out not to carry" below.

Neither value is ever read by the agent from a store. Both are injected by the Rust host into the subprocess environment, exactly as [ADR-0008](./0008-the-harness-runs-as-one-long-lived-host-process.md) requires, and [ADR-0010](./0010-the-agent-is-isolated-from-the-developers-claude-code.md)'s isolation of `~/.claude` is untouched. A subscription credential reaches the agent the same way a key does and by the same audit.

## Rejected: reading `Claude Code-credentials`

The obvious implementation, and the one this decision exists to refuse. Claude Code stores its own OAuth credential in a keychain item that a host process can read, and it holds exactly what an agent needs to authenticate as the subscriber.

It was measured before it was rejected. The item holds `accessToken`, `refreshToken`, `expiresAt`, `refreshTokenExpiresAt`, `subscriptionType` and `scopes`. **The access token measured on this machine expired 74 minutes after it was read.** The refresh token lasts weeks.

So reading that item means varnick implements OAuth refresh: detecting expiry, calling a token endpoint, and writing a new pair back into the keychain item that Claude Code is also using, from a second process, with no lock between them. varnick would own the lifecycle of a credential it did not mint, for a product it does not ship, and the failure mode — two processes refreshing the same token and invalidating each other — is intermittent and would present as authentication failing at random.

`claude setup-token` mints a long-lived token for exactly this use, and the SDK takes it from `CLAUDE_CODE_OAUTH_TOKEN`. The developer runs one command, the token goes in the keychain beside the API key, and varnick reads a string and injects it. No expiry handling, no shared mutable state, no second copy of an authentication protocol.

**This is a boundary, not a convenience.** varnick does not read another application's credential store. If the subscription token ever needs refreshing, the answer is that the developer mints another one — not that varnick learns to refresh.

## Rejected: staying API-key-only

The cheaper option, and defensible: it is what shipped, and the fix would have been to delete the plan-usage strip and say so in the README. It was rejected because the developer already pays for a subscription, and a harness that bills per request while an unused plan sits beside it is making a cost decision on the developer's behalf without saying so.

## Rejected: a setting

Asking the developer to declare which kind they are using, then looking for that one. It adds a way to be wrong — a setting that says `api-key` beside a stored subscription token — for no information the host cannot get by looking.

## Consequences

- **Precedence is subscription first, within each store.** Keychain still beats environment, which is unchanged. A developer holding both is taken to prefer the plan they already pay for; the environment variable remains the escape hatch, and CI, which has a key and no plan, is unaffected.
- **`resolve()` returns a kind, so every caller has to handle both.** The precedence rule stays a pure function with no keychain in it, and the kind is decided there rather than at the spawn — the spawn asks what to inject and is told.
- ~~**The plan-usage strip becomes conditional, and the `subscription` region only runs under a subscription.**~~ **Withdrawn by ticket 31.** The gate was built and was correct; it was never the thing standing between the developer and a figure. The strip, the region, `readSubscriptionUsage` and the `read-plan-usage` control kind are all removed. What replaces this consequence is a plainer one: **the Credential Kind decides which variable is injected and nothing else.** Nothing varnick renders differs by kind.
- **One measurement proves this, not two.** An agent that starts and answers under a subscription token is the only evidence that this works — ticket 09's original measurement was taken against the developer's own Claude Code session rather than against what varnick spawns, which is how a feature shipped that could never have worked. That measurement has now been taken: see "The measurement, taken" below, where a subscription token authenticates a real confined Session.

## The measurement, taken

A subscription token was minted with `claude setup-token`, stored in the Keychain as `varnick`/`claude-oauth-token`, and used to drive containment probe 6 — the only probe that opens a real Session. The agent authenticated, started, and called tools:

```
tools the Session actually called   Read:denied, Read:allowed, Grep:denied, Grep:allowed, Glob:denied, Glob:allowed
```

So a subscription authenticates what varnick spawns, which is what this decision claimed and what nothing had shown.

The same run failed, which is what happens when a probe that has always skipped finally runs. It failed twice over, and only one of them was a real defect.

The real one is ticket 27: every Bash command was refused, because Claude Code writes its scratch directory to `/tmp/claude-<uid>` and `allowWrite` named only the clone and `os.tmpdir()`. Fixed, with a probe holding it.

The other was the probe itself. `Grep` and `Glob` answer with paths relative to the working directory, and the control compared against absolute ones — so two working tools read as denied, and that was written up as a product defect before anyone printed what the tools had returned. Retracted in ticket 26. With the comparison fixed, every control passes and every denial holds.

Neither is a consequence of this decision; both were equally true under an API key. What the credential unlocked was the ability to see them at all.


## What the subscription token turned out not to carry

Measured after this decision shipped, against a real `claude setup-token` credential driving a real Session:

```
subscription_type:       null
rate_limits_available:   false
rate_limits:             null
```

**A subscription token authenticates, and reports no plan.** It does not even identify itself as a subscription. Claude Code's own banner for such a session reads `Claude API`: it treats a `setup-token` credential as **API authentication, not as a plan**. That single fact closes every route to the windows —

| Route | `setup-token` | interactive login |
|---|---|---|
| SDK usage control request | `rate_limits_available: false` | — |
| Session transcript (`*.jsonl`) | no such field | no such field |
| Statusline payload | no `rate_limits` key at all | has it |
| `GET /api/oauth/usage` | `429` | `200` — real figures |

— and the endpoint that answers is the interactive OAuth pair, the credential this ADR refuses to read for reasons that have not changed. There is no route to plan usage that does not go through this decision.

**The first consequence is unaffected and this decision stands:** the token authenticates, an agent runs under it, and the developer's plan pays for the tokens rather than an API key billing per request. That was the reason for choosing it and it holds.

**The second consequence is withdrawn.** "Whether plan usage exists to be read" has one answer in practice — no — so it was never a thing the Kind decided. Ticket 31 cut the strip, the `subscription` region, `readSubscriptionUsage`, the `read-plan-usage` control kind and the scenarios that showed them.

What this also undoes is the assumption underneath ticket 23. The windows ticket 09 measured came from the developer's *interactive* Claude Code login — the OAuth pair in `Claude Code-credentials`, which this ADR refuses to read. **The credential that reports plan usage is precisely the one varnick will not hold.** Ticket 23's gate was correct and was simply never what stood between the developer and a figure.

Reversing this would mean owning OAuth refresh and racing Claude Code for the same keychain item — recorded for completeness in ticket 31 and not recommended. The reasoning in "Rejected: reading `Claude Code-credentials`" above has not changed.
