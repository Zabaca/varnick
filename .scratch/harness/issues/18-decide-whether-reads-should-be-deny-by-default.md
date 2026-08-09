# 18 — Decide whether reads should be deny-by-default

**What to build:** A decision, and whichever policy follows from it. Reads are currently allow-by-default: `denyRead` is a deny list, and everything not on it is readable. That covers home directories, both keychains, and four binaries — and leaves everything else open, including a repository stored anywhere other than under `/Users`.

**Blocked by:** None — the measurement exists as probe 7.

**Status:** needs-info — but the question has changed. It is no longer "is this possible and what does it need"; both are measured below. It is whether the maintenance cost of a computed, machine-specific allowlist is worth the boundary.

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

## What is actually left to decide

Not whether it is possible, and not what it needs. Two things:

- **The list is machine-specific.** `~/.bun` is this machine's interpreter; another clone may have bun elsewhere, or node, or a Homebrew toolchain. So the allowlist has to be *computed* at policy-generation time from what is actually in use — `process.execPath` and friends — rather than written down. That is real work and it is the honest cost.
- **It fails closed and obscurely.** A missing entry is `exit 133`, not a message. That is survivable only if srt's `startMacOSSandboxLogMonitor` — which watches kernel deny events and already exists — is wired in to say which path was refused. Without that, a fresh clone on an unfamiliar machine is a hang with no explanation.

`git` is the one known casualty so far: it needs `/private/var/select` (`xcode-select`), which is in the list above, and still failed under it — worth resolving before this ships, since an agent that cannot run `git` in the clone is a serious loss.

- [ ] The choice is made and recorded in ADR-0003, alongside the four corrections that led here
- [ ] If reads stay allow-by-default, `README.md` says so as a decision rather than as a description
- [ ] If they become deny-by-default, probe 7 is inverted and every other probe still passes unchanged
- [ ] Either way, `packages/harness/src/sandbox.ts` says which shape it is using and why, so the next reader does not have to infer it from the field name

Relates to stories 1, 2, 6, 7 and to ticket 13, which documented the current answer.
