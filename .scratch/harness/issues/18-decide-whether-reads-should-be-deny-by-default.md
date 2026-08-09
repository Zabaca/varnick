# 18 — Decide whether reads should be deny-by-default

**What to build:** A decision, and whichever policy follows from it. Reads are currently allow-by-default: `denyRead` is a deny list, and everything not on it is readable. That covers home directories, both keychains, and four binaries — and leaves everything else open, including a repository stored anywhere other than under `/Users`.

**Blocked by:** None — the measurement exists as probe 7.

**Status:** fixed — the inversion is in, measured with `bun run probe` under a real subscription credential. See the last comment for what the spike had not found.

## The decision, and the one thing about it that cannot be undone

Approved. Not because the cost is low but because it was measured: nine entries, every one load-bearing, allow-within-deny proven with a negative control, and `git` already solved and shipped.

**It is a one-way door for clones, and that is by design rather than by accident.** `strongerLeaf` in `sandbox.ts` merges every clone's policy forward by always taking the stronger side — union for a denial, intersection for an allowance. So a clone that runs once with `denyRead: ['/']` keeps it permanently: reverting the generator does nothing, because the merge holds the stronger value, and each developer would have to edit their own `sandbox-policy.json` to go back. That is ticket 17 working exactly as intended, and it is why this is worth doing deliberately.

**Two things go first, and neither is optional.** They are what make a wrong allowlist diagnosable by whoever hits it rather than only by whoever wrote it:

1. **Wire `startMacOSSandboxLogMonitor`.** srt already ships it and it watches kernel deny events. Without it a missing entry is `exit 133` and nothing else — and this project has already lost a day to a failure that did not say what it was. With it, the refused path is named.
2. **Compute the allowlist, do not write it down.** `~/.bun` is this machine's interpreter; another clone has node, or Homebrew, or a different toolchain. The list must be derived at policy-generation time from what is actually in use — `process.execPath`, the resolved toolchain, the SDK entry — or a fresh clone on an unfamiliar machine is a hang with no explanation.

Only then invert the boundary, and only with the full suite driven under it: `containment.probe.test.ts` and `sandbox.boundary.test.ts` both run real processes, and probe 6 now runs a real Session.

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

**Or make reads deny-by-default.** This has now been spiked, and both halves of the original framing were wrong.

**Wrong the first way: the mechanism.** This ticket said "srt's filesystem config accepts a `denyAllExcept` shape as well as the `allowAllExcept` one in use". It does not. `generateReadRules` in `macos-sandbox-utils.js` always emits `(allow file-read*)` first and then denies; there is no allowlist-first read mode, and the `denyAllExcept` string in that file is a **log label** that is itself mis-set — with the `denyOnly` shape actually in use, `'allowAllExcept' in readConfig` is false, so it prints `denyAllExcept` on every run regardless.

What does work is putting **`/` in `denyRead`** and the needed paths in `allowRead`. srt anticipates it: there is dedicated handling for a denied root, with a comment explaining that `(subpath "/")` denies the root inode so dyld aborts before exec, and re-allowing the literal root to fix it. Somebody hit this before us.

**Wrong the second way: "the cost must be measured rather than guessed" implied it was hard to find out.** It took about ten minutes. Under `denyRead: ['/']`, this allowlist starts the agent host, loads the SDK, and correctly denies a read outside the clone:

```
the clone
/usr  /bin  /System  /Library  /etc  /dev
/private/var/db  /private/var/select
~/.bun                       (the interpreter)
```

Measured with `agentCommand(...) --selftest`, which answered `{"sdk":"loaded","read":"denied","readWhy":"ENOENT","list":"denied",…}` — the agent running, and the boundary holding, under a denied root.

Each of the four candidates was then dropped in turn, and **every one of them is load-bearing**: without `/etc`, `/dev`, `/private/var/db` or `/Library` the agent exits 133 rather than starting. So the set is small, and it is not padded.

## The two things that looked like blockers, and are not

**`git` was reported broken under a denied root. It is not, and the reason is worth keeping.** `/usr/bin/git` is not git — it is an `xcode-select` shim that finds the real binary by reading the symlink `/var/select/developer_dir`, and that link sits in the denied root. Allowing the link's *target* does not help; `/private/var`, `/private/var/select` and the toolchain directory were each tried and each failed identically, because the denial is of traversing the link.

```
/usr/bin/git --version              exit 1  xcode-select: unable to read data link
<toolchain>/usr/bin/git --version   exit 0  git version 2.50.1 (Apple Git-155)
git --version, toolchain on PATH    exit 0  git version 2.50.1 (Apple Git-155)
```

**Already fixed and already shipped**, independently of this decision, because it is not conditional on it: `developerToolsBin` puts the real toolchain ahead of the shim on the agent's `PATH`. Reads are allow-by-default today, so the shim resolves and `git` works — but only because nothing denies the link, which is a bad thing for an agent's `git` to depend on.

**"An explicit allow inside a denied root may not be reliable" — it is reliable.** This was raised as the thing that would kill the option outright, since it would make every entry in the list above suspect. Measured, with a negative control:

```
clone file, base only              STAT ok    | READ ok 16 bytes
the file git wanted, + /Library    STAT ok    | READ ok 64 bytes
the same file, without /Library    STAT EPERM | READ EPERM
```

The doubt came from misreading git's `fatal: unable to access '…/gitconfig'` as a sandbox denial. The file is readable; git never reached it, because the shim died first.

## What is actually left to decide

Not whether it is possible, and not what it needs. Two things:

- **The list is machine-specific.** `~/.bun` is this machine's interpreter; another clone may have bun elsewhere, or node, or a Homebrew toolchain. So the allowlist has to be *computed* at policy-generation time from what is actually in use — `process.execPath` and friends — rather than written down. That is real work and it is the honest cost.
- **It fails closed and obscurely.** A missing entry is `exit 133`, not a message. That is survivable only if srt's `startMacOSSandboxLogMonitor` — which watches kernel deny events and already exists — is wired in to say which path was refused. Without that, a fresh clone on an unfamiliar machine is a hang with no explanation.

`git` is the one known casualty so far: it needs `/private/var/select` (`xcode-select`), which is in the list above, and still failed under it — worth resolving before this ships, since an agent that cannot run `git` in the clone is a serious loss.

- [x] The choice is made and recorded in ADR-0003, alongside the four corrections that led here — as *The decision*, not a fifth correction
- [x] `README.md`'s *Where confinement stops* leads with the inversion, and points at the generated allowlist rather than restating it
- [x] Probe 7 is inverted, with a read inside the clone added as the control the flip needed, and every other probe passes unchanged
- [x] `packages/harness/src/sandbox.ts` says which shape it is using at `denyRead` and `allowRead`, and why every named denial stays denied inside an allowance

Relates to stories 1, 2, 6, 7 and to ticket 13, which documented the current answer.

## Comments

**The two prerequisites are in; the inversion is not.** `denyRead` is untouched and the policy still reads back exactly the clone.

*The violation monitor.* `establishSandbox` now starts `srt`'s `startMacOSSandboxLogMonitor` once the kernel restrictions are real, and `releaseSandbox` stops it. An unexpected denial goes to `console.warn` — stderr, which `src-tauri/src/bridge.rs` inherits, so it lands in varnick's own output; the same channel and the same argument as the policy report immediately above it. Measured noise floor before filtering: three denials for one `cat`, of which two are `sysctl-read kern.iossupportversion` that *every* wrapped command trips. So `isUnexpectedViolation` stays silent for anything that is not a read and for any read under a path `denyRead` names — and deliberately does not count the filesystem root as such a name, because `denyRead: ['/']` would otherwise silence the monitor at the exact moment it becomes the only thing that says why the agent will not start. Probe 10 in `containment.probe.test.ts` measures it, with the same real denial classified against a policy that never denied `$HOME` as the control. On a correct policy a developer sees nothing at all.

*The computed allowlist.* `readAllowlistFor` in `sandbox.ts` derives the interpreter's install root from `process.execPath` (`~/.bun` here, Homebrew or nvm elsewhere — the reason this is a function), the SDK's tree from `agentSdkEntry()`, and the toolchain from the new `developerToolsBin()` in `agent.ts`. Only the eight measured system paths are constants, with a comment saying they were measured.

*It is not wired into the policy, and that is the answer to the question the brief called the most important judgement.* Adding it to `allowRead` today would weaken the boundary and buy nothing. Nothing, because reads are allow-by-default: every path on the list is already readable, so no entry permits anything new. Weaken, because `allowRead` beats `denyRead` — `/usr` re-opens all four `UNREADABLE_BINARIES`, and `/Library` re-opens `/Library/Keychains`, which ticket 16 denied after dumping 37 generic passwords out of it. `~/.bun` is a third, smaller widening: it is under the denied `$HOME`. `sandbox.test.ts` asserts that overlap, so the mistake fails there rather than in a probe with a keychain dump in it. **The inversion therefore cannot be "add these lines and change `denyRead` to `['/']`"** — it has to restore the binary and keychain denials some other way in the same change, since under a denied root they are no longer covered by the deny list at all.

**The inversion is in, and the trap the ticket predicted did not exist.** `denyRead` is `/` plus every entry it already listed, and `allowRead` is `readAllowlistFor` plus the writable trees. The binary and keychain denials did **not** have to be restored some other way: `srt`'s `generateReadRules` already re-emits any *literal* deny nested inside an allowed subpath, so `/Library/Keychains` stays denied under the allowed `/Library` and the four binaries stay denied under the allowed `/usr`. Its own comment says so. What that comment also says is the thing to keep: glob denies are not re-emitted, and `denyReadAlways` is the lever for that case — so a denial written as a pattern would be silently re-opened. Every entry in `denyRead` is a literal, and `sandbox.test.ts` now asserts that for the whole list rather than for the six paths it affects today.

**The spike's allowlist was not enough, and the violation monitor is the only reason that took an hour rather than a day.** Six additions, each with the failure that named it — none of which the `--selftest` measurement could have found, because five of them are not about starting the agent:

```
/private/etc               curl: /private/etc/ssl/openssl.cnf — every request fails
/etc                       curl: CAfile /etc/ssl/cert.pem;  git: /etc/gitconfig
/var                       xcode-select: unable to read data link /var/select/developer_dir
                           — git and python3 do not resolve at all
/tmp                       mkdir: /tmp: Operation not permitted — every Bash command
$TMPDIR                    touch $TMPDIR/x refused;  git: cannot open xcrun_db
/private/tmp/claude-<uid>  touch in the scratch directory refused
```

Each was verified by dropping it again and re-running. Two general facts came out of it. **The three root symlinks grant the link and not the tree** — `/etc`, `/tmp` and `/var` point into `/private`, the kernel canonicalizes real accesses below them, and with `/tmp` allowed `mkdir -p /tmp/claude-<uid>` succeeds while `ls /tmp` and a read of a file under it are still refused. So both spellings are needed and neither makes the other redundant. And **a writable tree has to be readable**, because `touch` stats before it creates; `allowWrite` without a matching `allowRead` is not a grant, and the scratch directory is ticket 27 for the second time by a different mechanism.

**One thing the merge could not do on its own.** Union for a denial and intersection for an allowance are each right and together wrong for this pair: a clone with no baseline takes the stronger side of everything, which adopts `denyRead: ['/']` *and* intersects `allowRead` down to the one entry the old policy had. That policy denies the filesystem and reads back one directory — `/bin/bash` cannot be mapped, nothing runs, `exit 133` with no message. So when the merged policy denies the root, every entry the generator's allowlist names is kept, and the widening is reported as `[weaker]`. `sandbox.boundary.test.ts` plants exactly that clone, which is how it was found.

**Measured.** `bun run probe` under a real subscription credential: fourteen probes, no skip, probe 6 green — the SDK's own `Read`, `Grep` and `Glob` denied outside the clone and permitted inside, with a Session that ended `ok`, which is also the only evidence that a real agent's `Bash` still works under the inversion. Probe 7's verdict is inverted: a repository outside every home directory is now refused a read as well as a write.

**Two costs to write down rather than fix.** The monitor is noisier than probe 10 suggests — starting a real Session printed five denials the policy did not mean (`/home`, `/sbin`, `/private/var`, `/private/tmp`, `/private/var/run/systemkeychaincheck.done`), none of them load-bearing, all of them path probing. Probe 10 stays silent because it only runs `cat`. Widening the allowlist to quiet them would be widening the boundary to tidy a log, so they stand. And the agent can still read `/usr`, `/Library` and `/System` in full: this bounds what it can reach on the developer's disk, not what it can learn about the machine.
