# 11 — git cannot run inside the Sandbox on a machine with a global config

**What to build:** the confined agent can run `git`. Today it cannot, on any
machine whose developer has a `~/.gitconfig` — which takes `git worktree add`,
`git commit` and `git merge` with it, and therefore takes the whole of
ADR-0014. The agent authors Core in a Worktree; it cannot currently make one.

`$HOME` is denied by default, deliberately — ADR-0003 and ticket 18 both chose
that. What was not chosen is git's reaction to it. An unreadable `~/.gitconfig`
is **fatal** to every git invocation:

```
fatal: unable to access '/Users/<you>/.gitconfig': Operation not permitted
exit 128
```

Note the asymmetry that makes this specifically a config problem rather than a
`$HOME` problem: `~/.config/git/ignore` under the same denial produces only a
`warning:` and git carries on. It is the global config alone that is fatal.

This is invisible on a machine without a `~/.gitconfig`, which is presumably how
it has survived. It is the cause of **one** of the two failures previously read
as flaky pre-existing noise: `sandbox.boundary.test.ts` "git's own executable
configuration is refused by the kernel", which fails at `git worktree add`
returning 128. That test is measuring the developer's home directory rather than
the boundary it names.

**Correction, on picking this up:** that test is no longer red. Ticket 01 pinned
`GIT_CONFIG_GLOBAL=/dev/null` on every git command in it and merged, so it is
green — and green for the reason the pin's own comment admits: the probe arranges
around the finding rather than measuring it. Worse in one place than the comment
said, since the `git config core.hooksPath` assertion only checks for a
`not permitted` message, and an unpinned run supplies that from `~/.gitconfig`
before the write it is about ever happens. Measured on this branch: 8/8 pass
before the change, 8/8 after with every pin removed, and 7/8 with the pins
removed and the fix backed out — `git worktree add` at 128.

The second failure has a **different cause** and wants its own ticket. The
containment probe's "the kernel denials reach varnick, and only the unintended
ones are said out loud" fails at `containment.probe.test.ts:1463`, asserting no
unexpected denials were reported; the denial it gets is `file-read-metadata
/nix/var/nix/profiles/default` — a nix installation on this machine hitting a gap
in the read allowlist. Also machine-specific, also pre-existing, unrelated to
git. An earlier note on this ticket attributed both failures to `~/.gitconfig`;
that was wrong and is corrected here.

## Measured, not inferred

Under a policy with ticket 01's `.githooks/**` deny confirmed present in
`denyWrite`, changing one variable only:

```
git worktree add -q .claude/worktrees/probe -b probe
  → 128  fatal: unable to access '~/.gitconfig': Operation not permitted

GIT_CONFIG_GLOBAL=/dev/null git worktree add -q .claude/worktrees/probe2 -b probe2
  → 0
commit inside that worktree                → 0
git merge --no-ff probe2                   → 0

control, same sandbox: printf x > <clone>/.githooks/pre-commit
  → 1  Operation not permitted
```

So the deny list is biting correctly in the same sandbox where git now works.
The two are independent, and the failing assertions are not about the deny list.

## The decision this needed, and what was chosen

**A projected config, not a copy, in a file the agent cannot write.** Neither of
the two candidates below.

varnick writes `<clone>/.varnick/gitconfig` at launch, from the *unconfined*
runtime — `establishSandbox` in `packages/harness/src/sandbox.ts`, which is the
last moment before the fence exists and the only process that can read the
developer's real config. `GIT_CONFIG_GLOBAL` is pointed at it in two places: the
wrapper's environment overlay, so *every* command run under the Sandbox has it
(the boundary probes shell out to git directly), and `agentEnvironment`, which
builds the Claude Code environment outright rather than inheriting one.

**The file is in `denyWrite`, and that is the security half rather than a
detail.** A gitconfig is executable configuration — `core.hooksPath`,
`core.editor`, `core.pager`, `core.sshCommand`, `alias.*` and
`credential.helper` beginning `!`, `filter.*.clean`, `diff.*.textconv`,
`merge.*.driver`, `include.path`. Writable, the agent puts `core.hooksPath` into
the file every git command in the Sandbox reads and has unconfined execution on
the developer's next commit: exactly the hole ticket 01 closed for `.githooks/`,
arriving through a file varnick introduced to fix something else. srt's
move-blocking covers the node too, so it cannot be deleted or moved aside.

**The projection is an allowlist and not a denylist**: `user.name` and
`user.email`, and the allowlist is enforced by *what is asked for* — each key is
read from git by name, so no other key is ever read, held or rendered. The
argument is ADR-0018's: a denylist of executing keys is complete the day it is
written and stale the next time git adds one, and the failure is silent.
`packages/harness/src/gitconfig.ts` is where all of this is argued.

### Why not the two candidates originally named

- **Read `~/.gitconfig` back out of the denied root.** It widens the fence onto a
  file the developer edits for reasons unrelated to varnick. Measured on this
  machine, that file already carries five executing entries nobody added with an
  agent in mind: `filter.lfs.clean`, `.smudge` and `.process` (git-lfs, which
  fires on the checkout `git worktree add` performs), `alias.lg`, and two
  `credential.<url>.helper` entries that are `!/opt/homebrew/bin/gh`.
- **`GIT_CONFIG_GLOBAL=/dev/null`.** No widening, and it loses authorship:
  commits would carry whatever git auto-detects from the hostname and passwd
  entry. ADR-0014's model is a human reading the agent's diffs before merging, so
  the authorship in that history is something a person relies on.

### The cases, and what each does

- **No `~/.gitconfig` at all** — the file is written anyway, with its header and
  no keys. Absent would also work (git treats a missing global config as empty)
  and is rejected because "not there" and "varnick could not write it" would then
  look identical to anyone reading the clone.
- **Identity set per-repository** — untouched. `.git/config` is inside the clone,
  readable, and wins over the global one. Asserted at the kernel: the boundary
  probe's clone sets `user.name` per-repo and `git log -1 --format=%an` reports it.
- **Unreadable to the host for some other reason** — the same as having none.
  Null covers "not set", "no config" and "git would not run", because all three
  have one consequence.
- **Regeneration** — rewritten every launch, like the `node` shim, so a changed
  identity is picked up on the next start. The agent cannot have edited it in
  between; that is what the deny is for.
- **A Preview** — its `cloneRoot` is the Worktree, so it gets its own projection
  there, which the live tree's `denyWrite` does not name. Same as its `.githooks/`
  and it grants nothing: what a Preview's git reads decides what runs inside that
  Preview's Sandbox, and the developer's own git never looks there.

This is a Fence change and lands through a human merge.

**Blocked by:** None — but everything that depends on the confined agent
committing in a Worktree depends on this, so it should go ahead of them.

**Status:** ready-for-review

- [x] A confined agent can run `git worktree add`, `git commit` and `git merge` on a machine that has a `~/.gitconfig` — measured unpinned in `sandbox.boundary.test.ts`, on the machine whose `~/.gitconfig` caused this
- [x] The chosen fix is recorded with its trade-off, in an ADR or in the sandbox generator's own comments — `packages/harness/src/gitconfig.ts`, the `denyWrite` entry in `sandbox.ts`, the generated policy's own prose, and ADR-0018's three-list table
- [x] The two tests that currently fail for this reason either pass or are renamed to say what they actually measure — the boundary suite's git commands are unpinned and green; the containment probe's remaining pin is kept for a *different* reason (dotfile determinism in probe 11d) and its comment now says so
- [x] A test covers the machine-with-a-global-config case, so this cannot go invisible again — the boundary probe reads the projected file back off disk and asserts every setting line is an allowlisted key, on a machine whose real config has an alias and two credential helpers in it

## Comments

Found by the ticket 01 agent while measuring whether its `.githooks/**` deny
moved the two known failures. It did not: the per-file counts are identical
either side of that change. Filed rather than fixed, because choosing between
the two candidates is the developer's call and not a ticket-01 decision.
