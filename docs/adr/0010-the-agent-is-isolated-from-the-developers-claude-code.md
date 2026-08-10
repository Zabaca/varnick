# The agent is isolated from the developer's own Claude Code, and takes a flag to inherit it

varnick starts a Claude Code process. Left alone, that process reads settings,
`CLAUDE.md`, MCP servers, plugins and hooks off the filesystem, and reads a good
deal more out of the environment it was handed. All of it belongs to whoever is
running varnick, most of it was configured for other work, and some of it was
configured months ago and forgotten. Behaviour assembled out of that is
behaviour nobody else can reproduce — including the person it belongs to.

So the session is isolated by default, and
`VARNICK_INHERIT_CLAUDE_CONFIG=1 bun tauri dev` is the way out.

> **Amended by ticket 38 — the clone half is reversed.** This ADR isolated the
> agent from *two* things and only ever needed to isolate it from one. The
> developer's `~/.claude` is still not read, and cannot be: the Sandbox denies
> `$HOME`, which is a stronger guarantee than an option. But the **clone's own**
> configuration is now the agent's: `settingSources: ['project', 'local']`, its
> hooks, its skills, its MCP servers, and its `CLAUDE.md` — which the SDK loads
> only when `project` is among the sources, and whose absence meant the agent
> worked in this repository without the repository's own rules.
>
> The argument that changed. A hook loaded from the clone runs **inside the
> Sandbox**, in the same confined process the agent already runs `Bash` in — it
> grants no capability. What it grants is *reach through time*: it fires in
> later sessions, before anyone reads anything, and never appears in the
> transcript, so an injection that lands once can make itself permanent and
> invisible. That is a real cost, and it is not the one this ADR was priced
> against. The line that actually matters is narrower and now stands alone:
>
> **Nothing derived from the clone is ever executed outside the Sandbox.**
>
> varnick runs exactly one Claude Code process outside it — the `setup-token`
> mint, ADR-0003's bounded exception — and that one already sets a
> `CLAUDE_CONFIG_DIR` and a working directory outside the clone. That was
> defensive when it was written and is load-bearing now.
>
> The reach problem is answered the way this codebase answers everything else:
> **visibly**. The runtime panel reports what the agent actually loaded, because
> configured is not the same as loaded — so a plugin or skill the agent gave
> itself is a thing on screen rather than a thing to be discovered.
>
> Reproducibility, which is this ADR's opening argument, is better served than
> before: what the agent loads now lives *in the clone*, so it travels with it.
> A plugin under `~/.claude` was never reproducible and was never reachable
> either. One is copied into `.claude/plugins/` or it does not exist.
>
> **One consequence, examined and accepted.** `.claude/**` is agent-writable,
> and the developer's *own* Claude Code sessions run in this directory and load
> the same settings and plugins. So a hook the agent writes fires in those
> sessions, unconfined — varnick honours the invariant above, and the
> developer's other tooling is not varnick.
>
> The alternative was a varnick-only plugin directory the agent could write and
> nothing else would read, at the cost of the agent being unable to give itself
> a hook at all. The developer chose to share: *"leave .claude alone, i think it
> makes sense to share."* Recorded here rather than left implicit, because a
> reader finding a writable `.claude` later should be able to tell a decision
> from an oversight — which is precisely the distinction the host's own deny
> line went missing inside.

## Second amendment — the hook argument above was hypothetical until now

**Everything this amendment prices about hooks was, at the time it was written,
describing something that did not happen.** Plugin hooks had never fired under
varnick, not once. A plugin declares its hook as a command, that command is
conventionally `node <script>`, and `agentEnvironment` builds the environment
outright rather than inheriting it — varnick runs on bun, so nothing on the
agent's `PATH` answered to `node`. A hook that cannot spawn fails silently. That
is ticket 58, and it means the paragraph above beginning *"The argument that
changed"* was a careful assessment of a cost varnick was not yet paying.

The gap is closed rather than accepted: varnick writes a `node` onto the agent's
`PATH` that is bun, and a hook that still cannot run now says so in the
transcript instead of failing quietly.

**So the reach-through-time cost is real from this commit forward, and that is
stated rather than slipped past.** The decision itself does not change — the
argument above was made on the merits and stands on them — but a reader should
be able to tell when it started being true. `.claude/plugins/varnick-hook-probe`
is the fixture that keeps the answer checkable: its `SessionStart` hook records
that it ran, so *"a plugin's hooks fire under varnick"* is something a launch
demonstrates rather than something this document asserts.

Two things that did **not** move. The environment is still built outright, never
inherited — the fix is one name on `PATH`, not the developer's shell. And a hook
from the clone still runs inside the Sandbox, so the invariant this whole
amendment turns on is untouched: **nothing derived from the clone is ever
executed outside the Sandbox.**

## What isolation is, exactly

Two Agent SDK options and one environment rule, all of them in
`packages/harness/src/agent.ts` and all of them pure functions with tests:

- **`settingSources: []`** — the SDK's own isolation mode. No
  `~/.claude/settings.json`, no `.claude/settings.json`, no
  `.claude/settings.local.json`, and no `CLAUDE.md`, which loads with the
  project source. Hooks are declared in those settings, so they go with them.
- **`strictMcpConfig: true`** — no `.mcp.json`, no MCP servers from user
  settings, none contributed by plugins. Only servers varnick passes itself,
  and today it passes none.
- **Every `CLAUDE*` and `ANTHROPIC_*` variable is dropped** from the
  subprocess environment, except the credential the host injected, which is the
  only reason the agent can authenticate. A prefix rule rather than a list,
  because a list is right today and stale on the next release, and a stale list
  fails silently.

  **Amended by [ADR-0011](./0011-varnick-takes-a-subscription-token-not-the-subscription.md).**
  The exception was written as `ANTHROPIC_API_KEY` when that was the only
  credential varnick had. There are now two — `ANTHROPIC_API_KEY` for a key and
  `CLAUDE_CODE_OAUTH_TOKEN` for a subscription — and the host injects exactly
  one of them, having removed the other from the child's environment so an
  inherited variable cannot sit beside an injected one.

  The second name matters more than it looks. `CLAUDE_CODE_OAUTH_TOKEN` matches
  the `CLAUDE` prefix this rule drops by, so a subscription credential left to
  the rule would be scrubbed out of the environment of the very process it
  authenticates — and nothing anywhere would say so. The variable is named in
  `VARNICK_OWNED_VARIABLES`, and the test that holds it is
  "a subscription token survives the scrub that its own name matches".

That last one is not hypothetical tidying. Probed under the real generated
policy, from a terminal that happened to be a Claude Code session:

```
env | grep -c '^CLAUDE'   -> 9
```

Nine variables — `CLAUDECODE`, `CLAUDE_CODE_ENTRYPOINT`, `CLAUDE_EFFORT`,
`CLAUDE_CODE_SESSION_ID` and the rest — reaching the confined process, none
chosen by varnick, all of them an accident of which terminal the app was
launched from.

The scrub is measured in the same place rather than only in a unit test.
`--selftest` in the real agent entry, under the real wrapper, now reports both
counts, and `sandbox.boundary.test.ts` asserts the second:

```
boundary probe: the confined process was handed 9 inherited Claude Code /
Anthropic variables, and isolation left 0.
```

The first number is reported and not asserted — it depends entirely on the
terminal varnick was launched from. The second is the claim, and it is the one
figure here that does not vary by machine.

`agentConfigurationOptions(true)` returns `{}`. Inheriting is the *absence* of
the two options rather than an option asking for the opposite: what the flag
restores is the CLI's own default, and stating it any other way would be varnick
deciding what "inherit" means on Claude Code's behalf.

## `CLAUDE_CONFIG_DIR` moves in both modes, and that is containment rather than configuration

Measured under the policy `sandboxPolicyFor` generates:

```
mkdir ~/.varnick-write-probe   -> Operation not permitted
ls    ~/.claude                -> Operation not permitted
write inside the clone         -> ok
write inside the temp directory-> ok
```

`allowWrite` is the clone and the temp directory. A Claude Code process pointed
at `~/.claude` cannot write its own session store, so redirecting the config
directory is a condition of the agent running at all — not only of it running
isolated. It goes to `<clone>/.varnick/claude`, gitignored, one per clone.

## Consequences

- **The flag cannot restore anything under `$HOME`, and must not be made to.**
  `denyRead` covers the home directory, so `~/.claude` — user settings, user
  `CLAUDE.md`, skills, plugins, and any stdio MCP server installed there — stays
  unreachable with the flag or without it. What the flag actually restores is
  the clone's own configuration and the developer's environment. Widening
  `allowRead` to reach the rest is not on the table: `~/.claude.json` holds MCP
  server credentials, and a read-allow over the home directory is the exact
  mistake [ADR-0003](./0003-containment-wraps-the-process-tree.md) records
  twice — it is also what keeps the login Keychain shut.

  This narrows story 45 in `.scratch/harness/spec.md`, which asks for "my
  existing skills and MCP servers" to be available under the flag. Under the
  Sandbox, the ones installed under the home directory are not, and cannot be
  without weakening the policy. The flag is honest about the half it can do.

- **None of this creates a path for agent-authored configuration to run
  unconfined.** The rule is
  [ADR-0003](./0003-containment-wraps-the-process-tree.md)'s last consequence:
  a session runs `SessionStart` hooks from settings the agent can write, so a
  Claude Code process started host-side would execute agent-authored code
  outside the Sandbox. Nothing here starts one. `agentEnvironment` and
  `agentConfigurationOptions` compute strings; the Harness never opens a
  settings file, never reads `<clone>/.varnick/claude`, and never resolves a
  hook. The single `query()` call lives in `runAgentHost`, which is already
  inside `srt`, so everything those strings select is read by a confined
  process. The isolated default makes this *smaller* than it was: with
  `settingSources: []` the clone's `.claude/settings.json` is not read at all,
  so the hooks ADR-0003 warns about do not run even inside the Sandbox unless
  the flag is set.

- **The agent can write its own config directory, and it makes no difference.**
  `<clone>/.varnick/claude` is inside the clone, which is the agent's writable
  tree. Isolated, nothing there is read. Inherited, it is read by the confined
  Claude Code process — the same class of thing as the clone's
  `.claude/settings.json`, with the same containment, and already recorded in
  ADR-0003. It is not a new escape; it is the existing one, unchanged.

- **The flag never reaches the agent.** `VARNICK_INHERIT_CLAUDE_CONFIG` is
  stripped from the subprocess environment in both modes. It is varnick's
  switch, and an agent that can read it is an agent whose behaviour depends on
  it.

- **It is an environment variable, not a setting in the clone.** Same class as
  `VARNICK_HOST` and `VARNICK_HARNESS_ENTRY`: a property of one launch, read
  before anything renders. A setting stored in the clone would be a setting the
  agent can write, which is the whole problem restated.
