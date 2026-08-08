# 04 — Probe the containment against a real sandboxed process

**What to build:** Evidence that the boundary in tickets 01 and 03 is the boundary the product claims. A probe suite runs a real agent under the real policy and reports what it could and could not reach. Until this exists, the confinement claim rests on documentation — which is exactly how the `Read`/`Grep` hole in the SDK's own sandbox option went unnoticed.

**Blocked by:** 03 (needs a real agent process under the real policy) — now merged, and it left the first real-agent probe behind in `sandbox.boundary.test.ts` to build on.

**Status:** done — five probes measured, one skips without a credential

**Realizes:** no state path — this is the evidence for 01 and 03, and the only test in the project that can fail in a way the machines cannot detect.

Seam 2 from the spec. Prior art is `zbc/packages/agent` — its `sandboxed.test.ts` and `e2e/smoke.ts` are the closest existing examples, and its ADR-0002 is the record of what happens when containment is asserted rather than measured.

- [x] A probe file outside the boundary is unreadable by `Bash`, `Read`, `Grep` **and** `Glob` alike — the last three are the ones that walked past the SDK's option
- [x] Each entry in `DENIED_BINARIES` is measured, and the result recorded rather than assumed. **This criterion originally read "each denied binary reports as not found" and that is false** — `security`, `osascript` and `open` all execute; only `sudo` is blocked, for its own setuid reason. Denying read is not denying execution. Measure and report; do not weaken the policy to make a nicer number, and do not delete the entries — they are still worth having
- [x] A non-allowlisted host is unreachable; an allowlisted host is reachable
- [x] The run fails rather than proceeding when the sandbox cannot be established
- [x] The suite's actual output is quoted in the PR, not summarised

Slow and machine-dependent is accepted. A fast version of this test is a version that proves nothing.

Covers stories 1, 2, 5, 6, 7, 10.

## What it measured

`packages/harness/src/containment.probe.test.ts`, Darwin 25.5, `srt` 0.0.67, Agent SDK 0.3.226. Six probes, each with a positive control named beside it in the source.

1. **One file under `$HOME`, asked for four ways.** `Bash` refused with `Operation not permitted`; `Read`, `Glob` and `Grep` — run as `readFileSync`, `readdirSync` + pattern match, and a content match over that walk, inside the real agent entry — all `EPERM`. Every one of the four permitted against the same marker inside the clone. The Agent SDK loaded from inside the Sandbox, which is what proves the process got far enough to be denied.
2. **`DENIED_BINARIES`.** `security`, `osascript` and `open` are unreadable and run anyway. `sudo` is refused. Each execution probe was run unconfined first, so a refusal inside means the Sandbox rather than a missing binary.
3. **`sudo` is not stopped by the denied list.** The same policy with all four entries lifted out of `denyRead` leaves `sudo` refused with the same `Operation not permitted`, while `security` becomes readable — so the list is not the cause. `sudo` is also mode `-r-s--x--x`, unreadable to every non-root process before any policy applies, and its `denyRead` entry therefore denies nothing new. Recorded as a second correction on ADR-0003.
4. **Network.** `api.anthropic.com` answered; `example.com` got `CONNECT tunnel failed, response 403`.
5. **No unconfined fallback.** A clone whose `sandbox-policy.json` the schema rejects makes `establishSandbox` raise; the same clone with the generated policy establishes and wraps a command.
6. **The write boundary, including ADR-0002's two open gaps.** Core, the Harness, the root `package.json`, `sandbox-policy.json` and a root `vite.config.ts` are all refused. `packages/userspace/package.json` is writable — asserted *open*, so that closing it is a decision someone makes rather than a change nobody notices.

**What did not run.** Probe 6 drives the SDK's own `Read`, `Grep` and `Glob` tools through a real Session, and needs a credential; it skips with a printed reason without one, and it skipped here. Probe 1 is what covers those three in its absence — the same syscalls, in the agent process, under the same kernel policy and inside the same process tree. There is deliberately no faked substitute: the Sandbox denies local binding and every unlisted host, so a stub API is unreachable from inside, and widening the policy to reach one would be widening the policy to make a probe pass.
