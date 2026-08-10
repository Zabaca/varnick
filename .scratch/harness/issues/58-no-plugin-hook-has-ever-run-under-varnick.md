# 58 — No plugin hook has ever run under varnick

**What to build:** A hook declared by a plugin in the clone either runs, or varnick says it cannot.

**Blocked by:** None — can start immediately.

**Status:** done — the last box needs a launch, and closes at the next one. See the foot.

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

## The clone no longer contains a plugin that declares one

The caveman plugin was deleted in `9fa649c`, and the only plugin left in
`.claude/plugins/` is `mattpocock-skills`, whose `plugin.json` declares
`skills` and nothing else. **So there is currently no hook in the clone for this
ticket to make run.**

The finding is unchanged — the environment is still built without `node` and
without `CLAUDE_PLUGIN_ROOT`, so any hook that arrives will still fail
silently — but the evidence that made it visible is gone, and the first
acceptance criterion below now has nothing to test against.

Whoever takes this writes the fixture: a minimal plugin under
`.claude/plugins/` declaring a `SessionStart` hook that writes a flag file, and
a test asserting the file appears. That is a better artifact than the deleted
one anyway, because it is varnick's own and cannot be removed by a decision
about somebody else's plugin.

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

- [x] A fixture plugin in the clone declares a `SessionStart` hook
- [x] That hook runs, and the flag file it writes is asserted
- [x] The measurement says which of `PATH` and `CLAUDE_PLUGIN_ROOT` was missing
- [x] A hook that cannot spawn is reported rather than silent
- [x] The environment is still built outright, not inherited
- [x] ADR-0010's amendment notes that its hook argument was hypothetical until now

Found while implementing the Profile's voice: the plugin's own hook was the obvious way to apply it, and the flag file it writes had never appeared.

## The fixture

`.claude/plugins/varnick-hook-probe/` — varnick's own plugin, declaring one
`SessionStart` hook whose command is the exact idiom that failed:

```
node "${CLAUDE_PLUGIN_ROOT}/hooks/record.mjs"
```

It writes `hook-probe.json` under `CLAUDE_CONFIG_DIR`, which is inside the clone,
gitignored, and writable inside the Sandbox — so its presence is a fact about
*this launch* and not something a commit can fake.

Three rules the fixture lives by, each of them load-bearing:

- **Nothing on stdout.** A `SessionStart` hook's stdout is injected into the
  agent's context. A fixture that talked would change the thing it measures, on
  every session, for ever. Asserted.
- **Never throws, never exits non-zero.** A fixture that can fail a session is
  worse than the defect it proves. Every failure inside it is swallowed
  deliberately, and **absence of the file is the negative result** — which is why
  `hookProbeRecord` answers null rather than inventing a record.
- **It records what it was given, not what it expected.** `CLAUDE_PLUGIN_ROOT`,
  `argv0` and the head of `PATH` come from the run.

It replaces evidence that was lost rather than fixed: the finding was only ever
visible because `caveman` wrote a flag file that had never appeared, and deleting
that plugin took the evidence with it. A fixture varnick owns cannot be removed
by a decision about somebody else's plugin.

## What is proved where, and why it is split

**That the hook command can spawn** is proved headlessly, by running it with the
shim on `PATH` and `CLAUDE_PLUGIN_ROOT` supplied the way Claude Code supplies it.
This is the spawn that used to fail with `node: command not found` and say
nothing. It also asserts the silence, and that the interpreter which answered was
bun.

**That Claude Code fires it** cannot be: a `SessionStart` hook needs a real
Session, which needs a credential, and the only probe that opens one skips
without one — the same blindness that hid this defect for months. So the second
criterion is closed by a launch instead, and `pluginRoot` in the record is what
makes that check honest: **only Claude Code can set `CLAUDE_PLUGIN_ROOT`**, so a
record carrying it could not have been written by anything else.

To check it by hand at any time:

```
cat .varnick/claude/hook-probe.json
```

A file whose `ran` timestamp is after the current process started is a hook that
fired this launch. No file is the state varnick was in all along.
