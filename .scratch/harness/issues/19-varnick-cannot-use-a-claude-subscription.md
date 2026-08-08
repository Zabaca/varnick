# 19 — varnick cannot use a Claude subscription, and one shipped feature depends on it

**What to build:** A decision about how varnick authenticates, and whatever follows from it. Today it authenticates by API key only. The developer's Claude subscription — the thing Claude Code itself uses — is unreachable, and one feature that shipped in v1 can only work under a subscription.

**Blocked by:** None.

**Status:** needs-info — how a developer pays for tokens is the developer's call.

**Realizes:** no state path. Nothing about this is visible in a machine, which is part of why two tickets passed over it.

## What is true today

- `src-tauri/src/credential.rs` reads keychain service `varnick`, account `anthropic-api-key`, falling back to `ANTHROPIC_API_KEY`, and injects `ANTHROPIC_API_KEY` into the agent subprocess.
- Claude Code's own subscription credential is a *different* keychain item — `Claude Code-credentials` — and this machine has one.
- [ADR-0010](../../../docs/adr/0010-the-agent-is-isolated-from-the-developers-claude-code.md) isolates the agent from `~/.claude` deliberately: `settingSources: []`, `CLAUDE_CONFIG_DIR` inside the clone, and every `CLAUDE*`/`ANTHROPIC_*` variable dropped by prefix. That isolation is right and this ticket does not propose weakening it.

So the agent varnick spawns authenticates by API key, and cannot authenticate any other way.

## The two consequences

**Tokens are billed per request** while a subscription the developer already pays for goes unused. That is a cost decision rather than a defect, but nothing in the product says it is being made.

**Ticket 09's plan-usage strip cannot work.** `packages/harness/src/subscription.ts` refuses when `rate_limits_available` is false, and its own comment records that this is false "for API-key, Bedrock, and Vertex sessions, where no plan exists to have windows". Ticket 09's research measured `subscription_type: max` with both windows populated — but that measurement was taken against a session using the *developer's* OAuth, not against what varnick spawns. The feature was verified in a configuration the product does not ship.

The refusal is honest — a failed read leaves the last known value, which is nothing — so the strip renders empty rather than lying. But it will always be empty, and nothing says why.

## Why neither ticket caught it

Ticket 02 chose the credential path before an agent existed to spawn. Ticket 09 measured its source before the agent was isolated from `~/.claude`. Ticket 11 isolated it without knowing a feature depended on what was being isolated away. Each was correct in isolation, and the seam between them is where the product lives.

## The options

1. **Support subscription authentication.** The SDK reads OAuth from Claude Code's own configuration, which ADR-0010 deliberately makes unreachable. Doing this means giving the host a way to pass a subscription credential the way it passes an API key — host-side, injected, never in the agent's reach — rather than re-opening `~/.claude`. Restores plan usage as a side effect.
2. **Stay API-key only, and say so.** Then `README.md` states it, the first-run message names an API key specifically rather than "a credential", and the plan-usage strip is **cut** — a permanently empty measurement is worse than no measurement, and ticket 09 already established that deleting it is an acceptable outcome.
3. **Support both**, with the credential source deciding whether the strip appears at all.

- [ ] The choice is recorded in ADR-0003 or a new ADR, with the cost of the rejected options
- [ ] The first-run message names what kind of credential is actually required
- [ ] If API-key-only, the plan-usage strip and `readSubscriptionUsage` are removed and `CONTEXT.md`'s `subscription` region goes with them
- [ ] If subscriptions are supported, ADR-0010's isolation is preserved — the credential is injected, not read from `~/.claude` by the agent
- [ ] Whatever ships, one measurement proves it: an agent that starts and answers under the credential the product actually documents

Relates to stories 11–15 and 70, and to tickets 02, 09 and 11.
