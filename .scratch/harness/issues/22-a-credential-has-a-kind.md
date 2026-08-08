# 22 — A credential has a kind, and the kind decides what the agent is spawned with

**What to build:** varnick authenticates with either an Anthropic API key or a Claude subscription token, whichever the host finds, and the agent is spawned with the variable that matches. A developer who has run `claude setup-token` and stored the result never sees an API-key message, and never exports anything.

**Blocked by:** None.

**Status:** ready-for-agent

**Realizes:** no new state path. `credential.present` gains a fact; it does not gain a state.

This is [ADR-0011](../../../docs/adr/0011-varnick-takes-a-subscription-token-not-the-subscription.md), which is the decision ticket 19 was waiting for. **Read it before starting** — in particular the rejected option, because reading Claude Code's own keychain item is the implementation this ticket exists to not do, and it will look like the obvious shortcut.

## What is true today

`src-tauri/src/credential.rs` resolves one thing: keychain `varnick`/`anthropic-api-key`, falling back to the `ANTHROPIC_API_KEY` environment variable, and injects `ANTHROPIC_API_KEY`. `resolve()` is pure and carries seven `cargo test` cases. `packages/harness/src/credentials.ts` is the half Core sees and narrows the answer to `{ source }`.

## What changes

A reading answers with **two** facts rather than one — `source`, which exists, and `kind`, which is new: `api-key` or `subscription`.

Resolution order, and it is four cases rather than two:

| | subscription | api key |
|---|---|---|
| keychain (`varnick`) | account `claude-oauth-token` | account `anthropic-api-key` |
| environment | `CLAUDE_CODE_OAUTH_TOKEN` | `ANTHROPIC_API_KEY` |

Keychain still beats environment — unchanged, and it is why a fresh clone is told to use the keychain. Within a store, a subscription beats a key: ADR-0011 records that a developer holding both is taken to prefer the plan they already pay for, and that CI, which has a key and no plan, is unaffected either way.

The spawn asks the store what to inject and is told a name as well as a value. `ANTHROPIC_API_KEY` for a key, `CLAUDE_CODE_OAUTH_TOKEN` for a subscription — both are first-class authentication variables to the Agent SDK, which lists them side by side, so this is a substitution rather than a second authentication path.

## Watch for

- **`resolve()` must stay pure and stay the only place precedence lives.** It gains a kind and four inputs; it does not gain a keychain. Its seven existing cases are the prior art and none of them should lose meaning.
- **`Secret` has no `Serialize` and a `Debug` that refuses. Neither may be relaxed** to carry a kind — the kind is not secret and belongs beside the value, not inside it.
- **`VARNICK_OWNED_VARIABLES` in `packages/harness/src/agent.ts` must learn the new name.** ADR-0010 drops every `CLAUDE*` and `ANTHROPIC_*` variable from the agent environment by prefix; a credential varnick injects itself must be owned rather than inherited, or the isolation will strip the thing that authenticates. This is the failure that would present as "the subscription token does nothing" with no error anywhere.
- **No test may read or write the developer's real Keychain.** `resolve()` is pure precisely so the precedence can be tested without one. The one manual measurement below is a developer action, not a test.
- The value still never crosses the bridge, never enters a log, an error string, or the Session mirror. Nothing here weakens that and the existing structure — `&'static str` error tags, messages selected by enum — is what enforces it.

- [ ] A stored subscription token authenticates an agent, and the agent is spawned with `CLAUDE_CODE_OAUTH_TOKEN` and no `ANTHROPIC_API_KEY`
- [ ] A stored API key still authenticates an agent exactly as it did, spawned with `ANTHROPIC_API_KEY`
- [ ] `resolve()` decides the kind, is pure, and its cases cover both kinds from both stores and the precedence between them
- [ ] `credential.present` carries the kind into Core, and nothing carries the value
- [ ] The first-run message names both ways to supply a credential, and names `claude setup-token` for the subscription one
- [ ] `cargo test` and `cargo build` both run — `cargo` is at `~/.cargo/bin` and is not on the default PATH, and ticket 02 shipped Rust tests that had never been executed
- [ ] **One measurement, recorded in this ticket:** an agent started under a subscription token that answers a Turn. Nothing else proves this works, and ADR-0011 exists because a previous feature was verified in a configuration the product does not ship

Closes the decision half of ticket 19. Relates to stories 11–15.
