# 31 — Plan usage is unreachable under every credential varnick can hold

**What to build:** A decision. The plan-usage strip cannot render under an API key, and — measured today — cannot render under a subscription token either. It has never been reachable in any configuration the product ships, and ticket 23 moved the defect rather than closing it.

**Blocked by:** None.

**Status:** needs-info — cutting a shipped feature is the developer's call.

**Realizes:** the `subscription` region, which may stop existing.

## The measurement

A real `claude setup-token` credential, in varnick's own Keychain item, driving a real Session through the Agent SDK — the same credential the Tauri host injects:

```
subscription_type:       null
rate_limits_available:   false
rate_limits:             null
```

`readSubscriptionUsage` refuses on exactly that condition, so the read fails and the strip stays absent. **The session does not even know it is a subscription.** As far as usage reporting is concerned, a `setup-token` session is indistinguishable from an API-key one.

### The timing explanation, tested and rejected

The developer's own statusline shows `5h:21% wk:75%`, which looked like a contradiction. It is not, and the way it was resolved is worth keeping because the obvious answer was wrong twice.

Their statusline script calls nothing. It reads `.rate_limits.five_hour.used_percentage` out of the JSON Claude Code pipes to it, and its own comment says:

```
# Rate-limit usage (Pro/Max only; populated after first API response in a session)
```

"Populated after first API response" is a real condition, and the first measurement above did not meet it — the usage request was fired alongside the start of the session. So the reading was retested with the input stream held open, the way `runAgentHost` keeps a session alive, and the request made *after* a completed `result`. Same answer: `subscription_type: null`, `rate_limits_available: false`, `rate_limits: null`.

**So it is the credential, not the timing.** The statusline has figures because that session is the developer's interactive login. A `setup-token` session reports nothing, warm or cold.

### Four routes, all closed by measurement

| Route | `setup-token` | interactive login |
|---|---|---|
| SDK usage control request | `rate_limits_available: false`, `rate_limits: null` | — |
| Session transcript (`*.jsonl`) | no such field, across all 69 on this machine | no such field |
| Statusline payload | **no `rate_limits` key at all** | has it |
| `GET /api/oauth/usage` | **429** | **200** — `five_hour 28.0`, `seven_day 76.0` |

The statusline row is the one that settles it, because the statusline is where the developer *saw* the figures. Its script calls nothing; it reads `.rate_limits` out of the JSON Claude Code pipes to it. Captured that JSON from a real interactive session running under `CLAUDE_CODE_OAUTH_TOKEN`, with a config directory holding no credentials so the token was the only auth. The key is absent, and the session's own banner says what it thinks it is:

```
Sonnet 5 · Claude API
```

**Claude Code treats a `setup-token` session as API authentication, not as a plan.** That single fact explains every row: no `subscription_type`, no windows from the SDK, nothing in the statusline payload, and a `429` from the usage endpoint. The endpoint answers `200` with real figures for the interactive token — the credential [ADR-0011](../../../docs/adr/0011-varnick-takes-a-subscription-token-not-the-subscription.md) refuses to hold, for reasons that have not changed.

So there is no route to plan usage that does not go through that ADR. The lead is closed rather than open.

## Why this was not caught before, which is the part worth keeping

This is [ADR-0011](../../../docs/adr/0011-varnick-takes-a-subscription-token-not-the-subscription.md)'s own warning, repeating one level down.

Ticket 09 measured `subscription_type: max` with both windows populated, and that measurement was real — but it was taken against the developer's **interactive** Claude Code login, the OAuth pair in `Claude Code-credentials`. ADR-0011 then refused to read that item, for good reasons that still hold: its access token expired 74 minutes after it was read, and consuming it would mean varnick implementing OAuth refresh against an item another process is concurrently using.

So the credential ADR-0011 chose is not the credential ticket 09 measured. Ticket 19 spotted exactly this gap — "the feature was verified in a configuration the product does not ship" — and ticket 23 was written to fix it. It fixed the *symptom*: the strip is now absent rather than permanently empty, and `readSubscriptionUsage` is not invoked under an API key. It did not ask whether the remaining branch works, because nothing could ask that until a subscription token existed to try. One did today, and it does not.

Ticket 23's gate is not wrong. It is just never the thing standing between the developer and a figure.

## The options

1. **Cut it.** Remove the strip, `readSubscriptionUsage`, the `subscription` region and its states, and `CONTEXT.md`'s entry for them. Ticket 09 already established that deleting it is an acceptable outcome, and a region that can only ever sit in `unread` is a state machine describing something that does not happen. Smallest honest product.
2. **Keep the machinery, cut the claim.** Leave the region and the actor, and document that no credential varnick can hold reports plan windows. Defensible only if written where someone looks — otherwise it is three states and a card for a feature that has never once produced a number.
3. **Reopen ADR-0011.** The only credential that reports windows is the interactive OAuth pair, which that ADR refuses to read and gives measured reasons for. Reversing it means owning token refresh and racing Claude Code for the same Keychain item. **Recorded for completeness; the ADR's reasoning has not changed and this is not a recommendation.**

## Watch for

- **Do not make the strip render seeded figures under a live credential.** That is the exact claim `SeededMarker` and ADR-0011 exist to prevent, and it would be the tempting way to make this look fixed.
- Whatever is chosen, `#/states` and its coverage check follow: cutting the region removes cards, and drive.ts fails the build if a scenario names a state that no longer exists.
- Ticket 09's record should say what its measurement actually measured — an interactive login, not what varnick spawns. It was amended once already by ticket 23; this is the second correction to the same sentence.

- [ ] The choice is recorded, in ADR-0011 if the credential decision is unchanged
- [ ] If cut, the region, the actor, the strip, the scenarios and the `CONTEXT.md` entry all go together, and `bun run drive` proves nothing was left naming them
- [ ] If kept, the README says plainly that plan usage does not populate and why
- [ ] Either way, no surface shows a number it did not measure

Found by the developer noticing the strip was missing in the running app, and by asking a real session what it knew.
