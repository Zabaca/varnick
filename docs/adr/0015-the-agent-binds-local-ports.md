# The agent binds local ports

**Status:** accepted

## Context

`sandbox.ts` set `network.allowLocalBinding: false` with no comment beside it —
unique in a file where every other field carries the argument for its value.
It was srt's default carried through, not a decision.

What it cost is the whole of the agent's ability to observe its own work: no dev
server, no test server, no headless browser, no CDP. For a product whose premise
is that the agent builds UI, that is fatal. It is also what decides whether a
**Preview** ([ADR-0014](./0014-core-is-authored-in-a-worktree.md)) can be tested
by the agent or only by a person — and a flow where a human must look at every
iteration is the DX failure the worktree model exists to avoid.

## Decision

`allowLocalBinding: true`.

## Why this is not a network widening

Measured in srt 0.0.67. The flag adds exactly three Seatbelt rules:

```lisp
(allow network-bind     (local  ip "*:*"))
(allow network-inbound  (local  ip "*:*"))
(allow network-outbound (remote ip "localhost:*"))
```

srt's own comments, verbatim:

> bind/inbound are local operations (no remote endpoint), so wildcarding them
> does not grant egress.

> outbound uses `(remote ip "localhost:*")` so the egress allowlist remains
> enforced when allowLocalBinding is set (#225, #88).

The allowlist — `api.anthropic.com`, `registry.npmjs.org` — is untouched, and the
proxy still enforces it. Preserving egress under this flag is something srt was
patched for twice, with issue numbers.

## What it does grant, named rather than glossed

**Ingress on any interface.** The bind rule is `local ip "*:*"`, not loopback.
srt's comment explains why: dual-stack runtimes bind `127.0.0.1` as
`::ffff:127.0.0.1`, which Seatbelt's `localhost` token does not match, and `*:*`
is the only form that admits it. So the agent can bind `0.0.0.0` and something on
the same network can connect in. `packages/core/vite.config.ts` already warns
about exactly this shape for `VARNICK_HOST`, and the warning now applies to a
second process nobody configured.

There is no loopback-only form of this flag. Nothing enforces the narrower thing;
it is convention.

**Loopback egress.** The agent can reach other services on the machine — a local
database, an MCP server, another dev server.

**Not the Harness, and not the Tauri host.** Both speak NDJSON over stdio, not
sockets. Binding reaches neither.

**Not the srt proxy's allowlist.** The agent already talks to the proxy — that is
how egress works at all — and the proxy enforces the allowlist regardless of who
connects.
