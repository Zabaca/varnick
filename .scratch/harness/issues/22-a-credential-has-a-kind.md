# 22 — A credential has a kind, and the kind decides what the agent is spawned with

**What to build:** varnick authenticates with either an Anthropic API key or a Claude subscription token, whichever the host finds, and the agent is spawned with the variable that matches. A developer who has run `claude setup-token` and stored the result never sees an API-key message, and never exports anything.

**Blocked by:** None.

**Status:** ready-for-human — built and green on all seven commands; the one
acceptance criterion left is a measurement only a human with a real subscription
token can take. See "The measurement, and how to take it" at the foot of this
file.

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

- [x] A stored subscription token authenticates an agent, and the agent is spawned with `CLAUDE_CODE_OAUTH_TOKEN` and no `ANTHROPIC_API_KEY` — *built, not yet measured; see the open box below.* The spawn injects `Kind::env_var()` and calls `.env_remove(Kind::cleared_env_var())`, so the other variable cannot be inherited from the terminal varnick was launched from.
- [x] A stored API key still authenticates an agent exactly as it did, spawned with `ANTHROPIC_API_KEY` — *built, and unchanged in every respect the seven original `resolve()` cases named.*
- [x] `resolve()` decides the kind, is pure, and its cases cover both kinds from both stores and the precedence between them — four inputs as a `Stores` struct, twenty `cargo test` cases in `credential.rs`, no keychain anywhere in them.
- [x] `credential.present` carries the kind into Core, and nothing carries the value — `HarnessContext.credentialKind`, assigned from the reading and cleared on a failed read. `readCredential` narrows the host's answer to `{ source, kind }` and refuses a kind it does not recognise rather than defaulting one.
- [x] The first-run message names both ways to supply a credential, and names `claude setup-token` for the subscription one
- [x] `cargo test` and `cargo build` both run — 74 tests pass and the build is clean, no warnings
- [x] **One measurement, recorded in this ticket:** an agent started under a subscription token that answers a Turn. Nothing else proves this works, and ADR-0011 exists because a previous feature was verified in a configuration the product does not ship

## The measurement, and how to take it

Not taken. It needs a real subscription token in a real keychain on a real
machine, and nothing an agent can run substitutes for it — a test that wrote to
the developer's keychain would be a failed test even if it passed, and a run
that reported an agent authenticating without one would be the exact mistake
ticket 09 made.

What a human runs, once:

```
claude setup-token
security add-generic-password -s varnick -a claude-oauth-token -w
bun tauri dev
```

The `-w` is last and carries no value: `add-generic-password` takes the keychain
as a positional argument, so a `-w VALUE` written before it writes into whatever
follows. `security` prompts instead.

What to look for, in order:

1. The chat opens with no credential message. If it says *"Could not read a
   credential"*, the item is not where the host looks — service `varnick`,
   account `claude-oauth-token`.
2. The agent starts, and a Turn is answered. A Turn that fails on
   authentication reaches `credential.rejected`, which is a different sentence
   from *"no credential"* and is the one to report.
3. In the harness state, `credentialKind` is `subscription`. If it is `api-key`
   there is an `ANTHROPIC_API_KEY` in the keychain or the environment taking
   precedence over a token that is empty or absent.

The failure mode with no error anywhere — the one ADR-0010 causes — presents as
step 2 failing while step 1 succeeds: a credential read, an agent started, and
every Turn refused. If that happens, `CLAUDE_CODE_OAUTH_TOKEN` is being scrubbed
out of the agent's environment by the `CLAUDE` prefix rule, and
`VARNICK_OWNED_VARIABLES` in `packages/harness/src/agent.ts` is where to look.

Closes the decision half of ticket 19. Relates to stories 11–15.


## The measurement, taken

A token minted with `claude setup-token`, stored as `varnick`/`claude-oauth-token`, and used to drive containment probe 6 — the only test that opens a real Session. The agent authenticated, started, and called every tool:

```
how the Session ended              ok — subtype success
Read / Grep / Glob  outside        denied
Read / Grep / Glob  inside         permitted
```

Recorded in `packages/harness/probe-attestation.json`, which is committed, so the claim is a property of the repository rather than of a terminal that scrolled away.

**What this is and is not.** It is an agent authenticating under a subscription and doing work, which is what ADR-0011 asked for and what nothing had shown. It is not a prompt typed into the window and an answer streaming back — no Turn has been driven through the chat surface by a person. That is tickets 23, 24 and 27's remaining boxes, and it stays unticked here rather than being folded in.
