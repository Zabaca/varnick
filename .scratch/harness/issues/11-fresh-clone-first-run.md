# 11 — A fresh clone that runs

**What to build:** Someone who did not write varnick clones it, runs it in dev mode, and gets an empty chat that works — or one sentence naming the single thing missing. No personal configuration baked in, and no dependence on Claude Code settings they forgot they set. This is the difference between usable and nominally open source.

**Blocked by:** 03 (there has to be a working chat to arrive at).

**Status:** ready-for-agent

**Realizes:** `credential.absent`, `agent.down` — the first frame a stranger sees. `#/states → cold-start`.

**Open question worth answering here:** whether the dev server can itself run inside the sandbox. Userspace code executes in the host process when it loads, so the agent's output reaches the host by being run; if the dev server can be confined, that remaining escape narrows considerably at low cost.

- [ ] No paths, usernames, model defaults or allowlist entries specific to the author
- [ ] First launch on a machine that has never run varnick is a working chat, or one legible sentence naming what to do
- [ ] varnick is isolated from the developer's existing Claude Code configuration by default, with a flag to inherit it — so behaviour does not depend on forgotten machine state
- [ ] The README states plainly where confinement is **partial**: the Sandbox protects the home directory, other repositories and the network; it does not protect the clone from the code the agent writes into it. Git is the undo
- [ ] The README claims confinement only on macOS unless the bubblewrap or Windows backend has actually been exercised — neither has been
- [ ] The clean-clone run is actually performed and what happened is reported, including anything missing

Covers stories 8, 9, 41, 42, 43, 44, 45.
