# 18 — Decide whether reads should be deny-by-default

**What to build:** A decision, and whichever policy follows from it. Reads are currently allow-by-default: `denyRead` is a deny list, and everything not on it is readable. That covers home directories, both keychains, and four binaries — and leaves everything else open, including a repository stored anywhere other than under `/Users`.

**Blocked by:** None — the measurement exists as probe 7.

**Status:** needs-info — the trade-off below is the developer's to weigh, not an implementer's.

**Realizes:** no state path.

## What is measured

```
probe 7 — a repository outside a home directory
  read  secret.txt              READABLE — exit 0
  read  under $HOME  (control)  denied — exit 1
  write into it                 refused — exit 1
```

Writes are already deny-by-default and hold correctly: `allowWrite` is a genuine allowlist naming the clone and the temp directory. Reads are the asymmetric half.

So a repository on `/opt`, `/srv`, `/Volumes`, or an external disk is fully readable by the agent, while the same repository under `~/` is not. Most people keep their code under a home directory, which is why this has never bitten — but "most people" is not a boundary.

## The choice

**Leave it, and say so.** This is what ships today, and the README states it plainly. It is defensible: the sensitive things a developer actually keeps — SSH keys, cloud credentials, keychains, other checkouts — are overwhelmingly under `$HOME`, and the deny list names them. It costs nothing and protects the common case.

**Or make reads deny-by-default.** `srt`'s filesystem config accepts a `denyAllExcept` shape as well as the `allowAllExcept` one in use. That inverts the boundary: the clone is readable, plus whatever the toolchain genuinely needs, and everything else is refused. Strictly stronger, and it would have made three of this project's four wrong turns impossible to make.

The cost is real and must be measured rather than guessed. An interpreter, its standard library, `git`, the system libraries every process links, the CA bundle TLS needs, and the SDK's own dependencies all have to be reachable, and they are not in one place. An allowlist that is nearly right fails as a startup error with no obvious cause — ticket 03 already hit exactly that shape once, when a child could not read its own working directory.

**If it is pursued, the honest sequence is:** build the allowlist, run the whole existing suite under it — `containment.probe.test.ts` and `sandbox.boundary.test.ts` both drive real processes — and only then decide. A deny-by-default policy that has not started an agent is not evidence of anything.

- [ ] The choice is made and recorded in ADR-0003, alongside the four corrections that led here
- [ ] If reads stay allow-by-default, `README.md` says so as a decision rather than as a description
- [ ] If they become deny-by-default, probe 7 is inverted and every other probe still passes unchanged
- [ ] Either way, `packages/harness/src/sandbox.ts` says which shape it is using and why, so the next reader does not have to infer it from the field name

Relates to stories 1, 2, 6, 7 and to ticket 13, which documented the current answer.

## Comments

**The two prerequisites are in; the inversion is not.** `denyRead` is untouched and the policy still reads back exactly the clone.

*The violation monitor.* `establishSandbox` now starts `srt`'s `startMacOSSandboxLogMonitor` once the kernel restrictions are real, and `releaseSandbox` stops it. An unexpected denial goes to `console.warn` — stderr, which `src-tauri/src/bridge.rs` inherits, so it lands in varnick's own output; the same channel and the same argument as the policy report immediately above it. Measured noise floor before filtering: three denials for one `cat`, of which two are `sysctl-read kern.iossupportversion` that *every* wrapped command trips. So `isUnexpectedViolation` stays silent for anything that is not a read and for any read under a path `denyRead` names — and deliberately does not count the filesystem root as such a name, because `denyRead: ['/']` would otherwise silence the monitor at the exact moment it becomes the only thing that says why the agent will not start. Probe 10 in `containment.probe.test.ts` measures it, with the same real denial classified against a policy that never denied `$HOME` as the control. On a correct policy a developer sees nothing at all.

*The computed allowlist.* `readAllowlistFor` in `sandbox.ts` derives the interpreter's install root from `process.execPath` (`~/.bun` here, Homebrew or nvm elsewhere — the reason this is a function), the SDK's tree from `agentSdkEntry()`, and the toolchain from the new `developerToolsBin()` in `agent.ts`. Only the eight measured system paths are constants, with a comment saying they were measured.

*It is not wired into the policy, and that is the answer to the question the brief called the most important judgement.* Adding it to `allowRead` today would weaken the boundary and buy nothing. Nothing, because reads are allow-by-default: every path on the list is already readable, so no entry permits anything new. Weaken, because `allowRead` beats `denyRead` — `/usr` re-opens all four `UNREADABLE_BINARIES`, and `/Library` re-opens `/Library/Keychains`, which ticket 16 denied after dumping 37 generic passwords out of it. `~/.bun` is a third, smaller widening: it is under the denied `$HOME`. `sandbox.test.ts` asserts that overlap, so the mistake fails there rather than in a probe with a keychain dump in it. **The inversion therefore cannot be "add these lines and change `denyRead` to `['/']`"** — it has to restore the binary and keychain denials some other way in the same change, since under a denied root they are no longer covered by the deny list at all.
