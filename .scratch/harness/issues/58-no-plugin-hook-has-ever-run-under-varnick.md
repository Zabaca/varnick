# 58 — No plugin hook has ever run under varnick

**What to build:** A hook declared by a plugin in the clone either runs, or varnick says it cannot.

**Blocked by:** None — can start immediately.

**Status:** ready-for-agent

**Realizes:** no state path.

## The finding

[ADR-0010](../../../docs/adr/0010-the-agent-is-isolated-from-the-developers-claude-code.md)'s
amendment made the clone's own configuration the agent's — *"its hooks, its
skills, its MCP servers, and its `CLAUDE.md`"* — and priced the decision on
hooks in particular, at length: a hook grants no capability but grants *reach
through time*, firing in later sessions before anyone reads anything.

**They do not fire at all.** Found while giving the Profile a voice: the
`caveman` plugin ships a `SessionStart` hook that applies its style, declared in
its own `plugin.json`, and under varnick it has never once run. Its command is
`node "${CLAUDE_PLUGIN_ROOT}/src/hooks/caveman-activate.js"`, and the agent is
spawned with an environment `agentEnvironment` builds **outright rather than
inherits** — varnick runs on bun.

The evidence is not inference. That hook writes a flag file on every start, and
there has never been one under the clone's `CLAUDE_CONFIG_DIR`.

## Why it matters in both directions

**The capability is missing.** A developer who installs a plugin into the clone
gets its skills and its MCP servers and silently does not get its hooks. That is
half a feature, presented as a whole one.

**And the risk assessment was priced against something that is not happening.**
ADR-0010's amendment is a careful argument about the cost of clone-declared
hooks. The argument stands, but it has been describing a hypothetical, and a
reader should be able to tell which.

## The shape of the answer

Two candidates and they are not exclusive:

- **Make them run.** `node` is not on the agent's `PATH` — `developerToolsBin`
  already exists for exactly this class of problem — and `CLAUDE_PLUGIN_ROOT`
  has to be set. Establish which of the two is missing by measuring, not by
  reading the code.
- **Make the failure loud.** A hook that cannot spawn fails silently, which is
  the property that let this go unnoticed. The runtime report exists because
  *configured is not the same as loaded*; hooks are the one kind of
  configuration it does not report, and that is now a known gap rather than an
  oversight.

Whatever ships, a hook the agent wrote still runs **inside the Sandbox** and
still cannot reach outside it. Nothing here moves a boundary; it makes a
declared capability real, or admits it is not.

## Watch for

- Making hooks run makes ADR-0010's reach-through-time cost real for the first
  time. That was decided deliberately and the decision stands — but it should be
  *stated* on the way past, not slipped in as a bug fix.
- A hook that fails must not fail the session.
- Do not solve this by inheriting the developer's environment. `agentEnvironment`
  builds the environment outright on purpose, and that is ADR-0010's isolation.

- [ ] A `SessionStart` hook declared by a plugin in the clone runs
- [ ] The measurement says which of `PATH` and `CLAUDE_PLUGIN_ROOT` was missing
- [ ] A hook that cannot spawn is reported rather than silent
- [ ] The environment is still built outright, not inherited
- [ ] ADR-0010's amendment notes that its hook argument was hypothetical until now

Found while implementing the Profile's voice: the plugin's own hook was the obvious way to apply it, and the flag file it writes had never appeared.
