# varnick takes a subscription token, not the subscription

varnick authenticates with **either** an Anthropic API key **or** a Claude subscription, and the host decides which by what it finds. The kind is not a preference the developer sets in two places; it is a property of the credential that was resolved, and it travels with the reading.

A credential therefore has a **kind** as well as a **source**. `source` — `keychain` or `env` — says which store answered, and already existed. `kind` — `api-key` or `subscription` — says what was in it, and decides two things:

- **Which variable the agent is spawned with.** `ANTHROPIC_API_KEY` for a key, `CLAUDE_CODE_OAUTH_TOKEN` for a subscription. Both are first-class authentication variables to the Agent SDK, listed side by side in its own credential table, so this is one substitution rather than a second authentication path.
- **Whether plan usage exists to be read.** Rolling windows are a property of a plan. Under an API key there is no plan, `rate_limits_available` is false, and the strip is not rendered — rather than rendered permanently empty, which is what shipped in v1.

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
- **The plan-usage strip becomes conditional, and the `subscription` region only runs under a subscription.** `readSubscriptionUsage` is not invoked under an API key, so its refusal path stops being the normal case.
- **One measurement proves this, not two.** An agent that starts and answers under a subscription token, with plan usage populated, is the only evidence that this works — ticket 09's original measurement was taken against the developer's own Claude Code session rather than against what varnick spawns, which is how a feature shipped that could never have worked.
