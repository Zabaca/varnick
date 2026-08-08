# 26 — The agent's Grep tool does not work inside the Sandbox

**What to build:** An agent running under varnick can search the clone. Today it cannot: `Grep` is refused everywhere, including inside the one tree it is supposed to reach, and nothing in the product says so.

**Blocked by:** None.

**Status:** ready-for-agent

**Realizes:** no state path.

## How this was found, which is the part worth keeping

Probe 6 — "the Agent SDK's own Read, Grep and Glob tools, driven by a real Session" — is the only probe that opens a Session, and it skips without a credential. It has skipped since the day it was written. The first time it ran with a real credential it **failed**, and it failed on a *control*:

```
tools the Session actually called   Read:denied, Read:allowed, Grep:denied, Grep:allowed, Glob:denied, Glob:allowed
✗ expect(answers.grepControl).toBe('permitted')   Received: "denied"
```

`readControl` passed. So the agent authenticated, started, and called every tool — the machinery works. What failed is Grep reaching a file it is allowed to reach.

## Why

`rg` is not a separate binary. It is the Claude Code executable invoked under a different `argv[0]` — the shell function the installer adds does `exec -a rg /Users/<you>/.local/bin/claude`. That executable lives under `$HOME`, which `denyRead` covers.

And a binary under a denied root cannot run, which was measured separately while spiking ticket 25: `claude --version` alone returns `error: An internal error occurred (EPERM)` under the shipped policy, and emptying `denyRead` is what fixes it. It is a ~280MB self-extracting single-file executable, so it must read itself to start. That is a different case from [ADR-0003](../../../docs/adr/0003-containment-wraps-the-process-tree.md)'s correction, which measured `/usr/bin` system binaries executing while unreadable and does not generalise to this one.

So: Grep shells out to a binary the policy makes unrunnable. Read is pure `fs` and is unaffected.

## Two things to check before choosing a fix

- ~~Whether `Glob` is affected too.~~ **It is.** The first Turn run in the real application reported "I also have no Glob/Grep in this session" and fell back to reading known paths, which is a stronger signal than the probe gave — the probe stopped at Grep's control before reaching Glob. So both search tools are gone and only `Read` survives, which means the agent can read a file it is told about and cannot find one it is not.
- **Whether ADR-0003's central claim needs updating.** It says the SDK's `Read`, `Grep` and `Glob` "run inside the process without ever shelling out", measured against SDK 0.3.220 in another repository. If Grep now shells out, that sentence is stale. **The ADR's conclusion is unaffected** — `srt` wraps the process tree, so it covers a tool whether it shells out or not, which is precisely the argument for wrapping the tree. But the supporting detail should say what is true today.

## The fix is a decision, not an obvious edit

Each option gives something up, and this is the developer's call rather than the implementer's:

1. **Allow reading the Claude Code executable.** Cannot be done with `allowRead`: it is measured that `denyRead` on a root beats `allowRead` on a path beneath it, and hardlinking the binary into the writable root did not work either. It would mean not denying `$HOME` — the largest possible widening, and the thing that protects the login Keychain. **Almost certainly wrong.**
2. **Give the agent a `rg` that is not that binary.** A real ripgrep on a readable path, with the tool pointed at it. Smallest boundary change; adds a dependency a fresh clone has to get from somewhere.
3. **Accept it and say so.** Grep does not work; the agent has Read and Glob and Bash. Cheapest. Note that with ticket 27 open the agent has *only* Read, so "accept it" is a much larger concession than it first reads. Honest only if written into "Where confinement stops" — an agent silently missing a tool is worse than one documented as missing it.

- [ ] Whether Glob is affected is measured and written down
- [ ] Probe 6 passes, or the probe records the limitation deliberately rather than failing
- [ ] Whatever is chosen, `README.md` says what the agent can and cannot do inside the Sandbox
- [ ] ADR-0003's description of how the SDK's tools run matches what was measured today
- [ ] The Sandbox policy is not widened over `$HOME` under any option

## Not the only one

Ticket 27 is the sibling: every Bash command fails too, for an unrelated reason — Claude Code's scratch directory lives under `/tmp`, which `allowWrite` does not name. Between the two, an agent running under varnick today has `Read` and nothing else. Neither defect is in the credential work; both were simply never visible until something ran a Turn.

## And the thing this proves about the suite

A probe that skips is a probe that is not running, and this one skipped from the day it was written to the day it found a real defect. Whatever ships here should also make the skip visible — it prints a reason today, which was not enough, because nobody was reading the reason. Worth considering whether `bun test packages` should fail when the only probe that drives a real Session has never once been run.
