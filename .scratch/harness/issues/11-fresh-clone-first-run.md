# 11 — A fresh clone that runs

**What to build:** Someone who did not write varnick clones it, runs it in dev mode, and gets an empty chat that works — or one sentence naming the single thing missing. No personal configuration baked in, and no dependence on Claude Code settings they forgot they set. This is the difference between usable and nominally open source.

**Blocked by:** 03 (there has to be a working chat to arrive at).

**Status:** ready-for-agent

**Realizes:** `credential.absent`, `agent.down` — the first frame a stranger sees. `#/states → cold-start`.

Documentation honesty about where confinement stops is ticket 13, which is blocked on the probes that measure it.

- [ ] No paths, usernames, model defaults or allowlist entries specific to the author
- [ ] First launch on a machine that has never run varnick is a working chat, or one legible sentence naming what to do
- [ ] varnick is isolated from the developer's existing Claude Code configuration by default, with a flag to inherit it — so behaviour does not depend on forgotten machine state
- [ ] The clean-clone run is actually performed on a machine that has never run varnick, and what happened is reported, including anything missing

Covers stories 41, 42, 43, 44, 45.
