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

## The decision this needs

Two candidate fixes, both Fence decisions, and they trade off against each
other. This ticket is blocked on the developer picking one:

- **Read `~/.gitconfig` back out of the denied root.** Narrow — one file — but it
  is a widening of the fence, and the file is one an attacker who could write it
  would love (`core.hooksPath`, `alias.*`, `core.editor` all execute).
- **Set `GIT_CONFIG_GLOBAL` in the agent's environment overlay**
  (`packages/harness/src/agent.ts`). No widening at all, but it silently drops
  the developer's git identity and aliases, so commits the agent makes would
  carry different authorship than the developer expects.

The second is the safer default and the first is the more faithful one. Whoever
takes this should also decide whether the two tests above are asserting what
they mean to, since both currently fail for a reason unrelated to their names.

This is a Fence change and lands through a human merge.

**Blocked by:** None — but everything that depends on the confined agent
committing in a Worktree depends on this, so it should go ahead of them.

**Status:** needs-triage

- [ ] A confined agent can run `git worktree add`, `git commit` and `git merge` on a machine that has a `~/.gitconfig`
- [ ] The chosen fix is recorded with its trade-off, in an ADR or in the sandbox generator's own comments
- [ ] The two tests that currently fail for this reason either pass or are renamed to say what they actually measure
- [ ] A test covers the machine-with-a-global-config case, so this cannot go invisible again

## Comments

Found by the ticket 01 agent while measuring whether its `.githooks/**` deny
moved the two known failures. It did not: the per-file counts are identical
either side of that change. Filed rather than fixed, because choosing between
the two candidates is the developer's call and not a ticket-01 decision.
