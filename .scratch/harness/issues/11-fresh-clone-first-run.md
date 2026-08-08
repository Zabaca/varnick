# 11 — A fresh clone that runs

**What to build:** Someone who did not write varnick clones it, runs it in dev mode, and gets an empty chat that works — or one sentence naming the single thing missing. No personal configuration baked in, and no dependence on Claude Code settings they forgot they set. This is the difference between usable and nominally open source.

**Blocked by:** 03 (there has to be a working chat to arrive at).

**Status:** done, except the fourth criterion, which cannot be met on this machine — see Comments

**Realizes:** `credential.absent`, `agent.down` — the first frame a stranger sees. `#/states → cold-start`.

Documentation honesty about where confinement stops is ticket 13, which is blocked on the probes that measure it.

- [x] No paths, usernames, model defaults or allowlist entries specific to the author
- [x] First launch on a machine that has never run varnick is a working chat, or one legible sentence naming what to do
- [x] varnick is isolated from the developer's existing Claude Code configuration by default, with a flag to inherit it — so behaviour does not depend on forgotten machine state
- [ ] The clean-clone run is actually performed on a machine that has never run varnick, and what happened is reported, including anything missing

Covers stories 41, 42, 43, 44, 45.

## Comments

### The clean-clone run, and why the fourth box stays empty

There is no machine available that has never run varnick, and inventing one
would be worse than the gap — `PRODUCT.md` records that this project has no
users besides its author and no deployments.

What was done instead is `scripts/clean-clone.sh`: a `git clone` into a fresh
temporary directory, run under `env -i` with a `HOME` created a moment earlier,
a `PATH` of the system directories plus wherever `bun` lives, and nothing else.
No `CLAUDE*`, no `ANTHROPIC_*`, no `VARNICK_*`, no shell profile, no bun install
cache, no `~/.claude`. It is repeatable and it prints its own limits.

Everything a stranger would reach passed: install, typecheck, 227 tests
including the real-kernel boundary probes, 195 drive assertions, the production
build, the Harness runtime generating `sandbox-policy.json` for a clone that had
never been run and establishing the kernel Sandbox in it, and the dev server
serving the page.

It establishes that the repository builds and runs from nothing but its own
contents. It does **not** establish a clean machine: the kernel, the installed
toolchains, the login keychain and the OS are still the author's, and a scrubbed
`HOME` is not a new user account. The desktop launch, the credential path and
the chat itself are outside what a script can honestly assert — the first needs
a window, and the last two need a keychain no test here may touch.

### Story 45 is narrower than it reads, and the flag says so

`VARNICK_INHERIT_CLAUDE_CONFIG=1` restores the clone's own configuration and the
developer's environment. It cannot restore skills, plugins, user settings, user
`CLAUDE.md`, or stdio MCP servers installed under the home directory, because
`denyRead` covers `$HOME` and reaching them means a read-allow over the home
directory — the mistake ADR-0003 records twice, and what keeps the login
Keychain shut. Recorded in ADR-0010 rather than fixed by widening the policy.
