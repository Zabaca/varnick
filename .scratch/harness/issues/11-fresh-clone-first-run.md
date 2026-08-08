# A fresh clone that runs

**Status:** ready-for-agent

**Blocked by:** 01, 03, 04

**Realizes:** `credential.absent`, `agent.down` — the first frame someone who did not write varnick sees. `#/states → cold-start`.

The product is a repository someone clones. This slice is the difference between usable and nominally open source.

- no personal configuration baked in — paths, usernames, model defaults, allowlist entries
- first launch is an empty chat that works, or a legible message naming the one thing missing
- varnick is isolated from the user's existing Claude Code configuration by default, with a flag to inherit it — so behaviour does not depend on machine state they forgot they set
- the README states plainly where confinement is **partial**: Userspace code executes in the host process when it loads, so the agent's output reaches the host by being run. The Sandbox protects the home directory, other repositories and the network. It does not protect the clone from the code the agent writes into it. Git is the undo.
- the README claims confinement only on macOS unless the bubblewrap or Windows backend has actually been exercised — neither has been

**Open question worth answering here:** whether the dev server can itself run inside the sandbox. If it can, the remaining escape narrows considerably at low cost.

**Done when** the repository is cloned to a clean directory on a machine that has never run it, and the result is either a working chat or one sentence naming what to do. Report what actually happened, including what was missing.

Covers stories 8, 9, 41, 42, 43, 44, 45.
