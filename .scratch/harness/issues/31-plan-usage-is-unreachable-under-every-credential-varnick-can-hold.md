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
