# 38 — The agent owns its environment, inside the fence

**What to build:** The agent reads the clone it works in — its `CLAUDE.md`, its settings, its hooks, its skills and its plugins — while nothing derived from that clone is ever executed outside the Sandbox.

**Blocked by:** None.

**Status:** done.

**Realizes:** no state path.

## What was wrong

`settingSources: []` isolated the agent from two things and only ever needed to isolate it from one.

The developer's `~/.claude` was never reachable anyway: the Sandbox denies `$HOME`, which is a stronger guarantee than an option. What the flag actually removed was the **clone's own** configuration — including `CLAUDE.md`, which the SDK loads only when `project` is among the sources. So varnick's agent worked in this repository without the repository's own rules, and the developer had spent an evening watching it rediscover them.

The developer put it directly: *"varnick should be able to fully own its environment. why can't we allow it to write hooks and plugins and what not?"*

## The argument that changed

The claim under `settingSources: []` was that agent-authored code must not run. Examined, it splits in two:

- **"A hook gives the agent capability it does not have" — false.** A hook loaded from the clone runs *inside the Sandbox*, in the same confined process the agent already runs `Bash` in. `$HOME` is denied to it, Core is unwritable to it, the credential is in another process entirely.
- **"A hook gives the agent reach it does not have" — true, and it is about time rather than privilege.** It fires in later sessions, before anyone reads anything, and never appears in the transcript. An injection that lands once can make itself permanent and invisible.

That second cost is real and it is not what isolation was priced against. The line that actually matters is narrower, and it now stands alone:

> **Nothing derived from the clone is ever executed outside the Sandbox.**

varnick runs exactly one Claude Code process outside it — the `setup-token` mint, ADR-0003's bounded exception — and that one already sets `CLAUDE_CONFIG_DIR` and a working directory outside the clone. `the_command_runs_outside_the_clone_and_reads_its_configuration_there` was defensive when it was written; its comment now says it is load-bearing.

The reach problem is answered the way this codebase answers everything: **visibly**. The runtime panel already reports what the agent actually loaded, so a plugin or skill the agent gave itself is a thing on screen.

## What it does now

- `settingSources: ['project', 'local']`. `user` is deliberately absent — it is `~/.claude`, which the Sandbox denies, so naming it would be a claim this cannot honour. `VARNICK_INHERIT_CLAUDE_CONFIG=1` adds it for a run that has widened the policy by hand.
- `skills: 'all'`. The SDK calls this "the single place to turn skills on", and omitting it is not "skills off" but "no opinion".
- Plugins are **discovered** from `.claude/plugins/`, the rule Surfaces follow: adding one never requires editing Core. They are passed as a query option rather than through a settings file, which is also what makes them work — the plugins a developer has *installed* live under `~/.claude`, so a plugin exists for this agent only if it is inside the clone.
- `systemPrompt: { type: 'preset', preset: 'claude_code' }` (ticket 37) is what makes `CLAUDE.md` reachable at all, and the two changes together are why the agent now knows both where it is and what the repository expects.

`caveman` and `mattpocock-skills` are vendored into `.claude/plugins/`. 25MB of `node_modules` was dropped from the second — changesets tooling for publishing, no runtime dependencies, no hooks — taking 26MB to 2.6MB.

## Watch for

- **`.claude/**` is agent-writable**, deliberately. That is what "owns its environment" means, and it is the developer's decision rather than an oversight.
- **`caveman` states no licence** in its manifest and gives no repository. Worth settling before varnick is published; it lifts out without touching code.
- `managedSettings` is the SDK's policy tier — *"intended for embedding applications … that need to enforce [lockdown] on the spawned subprocess"* — and is deliberately unused. Nothing needs locking today, and inventing a policy to fill a tier would be speculation. It is the lever if one is ever needed.
- ADR-0010 is amended rather than contradicted. Its opening argument was reproducibility, and it is better served now than before: what the agent loads lives in the clone and travels with it.

- [x] The agent reads the clone's `CLAUDE.md`, settings, skills and plugins
- [x] `~/.claude` stays unreachable, by the Sandbox rather than by an option
- [x] Plugins are discovered rather than registered
- [x] The one process outside the Sandbox still cannot read the clone, and its test says why that matters
- [x] `bun test packages`, `bun run drive`, typecheck, lint and `cargo test` green

Asked for by the developer, who challenged the rule rather than accepting it.
