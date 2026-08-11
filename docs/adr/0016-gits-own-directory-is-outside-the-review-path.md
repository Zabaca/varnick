# git's own directory is outside the review path

**Status:** accepted, amended 2026-08-10 — see [Amendment](#amendment-tracked-was-not-the-property-that-mattered)

## Context

[ADR-0014](./0014-core-is-authored-in-a-worktree.md) rests on a single sentence:
*the agent's writes reach the running application only through a merge somebody
read.* That is true of tracked files and it is false of `.git/**`, which is the
one part of the repository no diff ever shows.

`.git/hooks/` is not versioned. It is not on a branch, not in a diff, not in a
merge. An agent that writes `.git/hooks/pre-commit` has arranged for code to run
unconfined on the developer's next `git commit` — **including the merge commit
that was supposed to be the gate**. It executes ahead of review, not behind it.

Worktrees make this sharper rather than milder: they share one `.git` through
`commondir`, so a single write covers every worktree at once, and the worktree
model is what will have the agent touching `.git` constantly.

There is a second path to the same place. `.gitattributes` can name a filter
driver, and git runs `filter.<name>.clean` and `.smudge` on checkout and
commit — but the command those names resolve to is defined in `.git/config`. So
hooks and filters close together or not at all. `.git/config` is also where
`core.hooksPath` lives, which means denying the hooks directory alone is
decorative: the agent redirects hooks somewhere it can still write.

## Decision

Add to `denyWrite`:

```
<clone>/.git/hooks/**
<clone>/.git/config
<clone>/.githooks/**          (added by the amendment below)
```

and set `core.hooksPath` to a tracked directory (`.githooks/`), which is what
husky and lefthook do.

## Why the agent loses nothing it can use

Hooks come back **better** than they were. As tracked files they appear in the
diff, travel through the merge, and are gated by the same review as everything
else — the agent authors them in a Worktree and a human reads them before they
run, which was never true of `.git/hooks`.

The cost of denying `.git/config` is `git remote add`, `git config` and
`--set-upstream`. The agent's network allowlist is `api.anthropic.com` and
`registry.npmjs.org`, so it cannot reach a forge and a remote is dead weight to
it.

Measured, because it was the one thing that could have made this expensive:
**`git worktree add` does not write `.git/config`** — md5 identical before and
after. The worktree flow is unaffected. What a worktree needs is
`.git/worktrees/**`, `.git/objects/**` and `.git/refs/**`, and none of those are
denied.

The global config is under `$HOME`, which `denyRead` already covers.

## Consequences

**This is the exception to the DX-over-security default, and it is cheap enough
to be uncontroversial.** varnick's posture is strong defaults a developer may
loosen, and blast radius bounded by the Sandbox rather than by asking. Two
things sit outside that: `sandbox-policy.json` with its baseline, which is
gitignored and therefore has no merge to be gated by, and this. Both are paths
where a write takes effect with no diff anywhere for anyone to read.

**The bootstrap is a human's.** Setting `core.hooksPath` is one command, run once
by whoever sets up the clone, or by a `postinstall` — which is already an
accepted host execution surface ([ADR-0002](./0002-core-userspace-boundary.md)).

## Amendment: tracked was not the property that mattered

Everything above holds, and it left the hole one directory out.

The argument for `.githooks/` was that a hook there *reaches the developer
through a diff they read*. That is true of a hook on a branch. It is not true of
a hook that never went on one, and the deny list was written as though a tracked
directory could not hold the second kind.
`.githooks/` was writable in the live tree, so the agent could put a
`pre-commit` there directly: on no branch, in no diff, in nobody's review, and
run unconfined by git on the developer's next commit — **including the merge
commit that was meant to be the gate**, which is the sentence this ADR opens
with. Redirecting `core.hooksPath` moved hooks somewhere better and moved the
hole with them.

Tracked describes where a file *can* be reviewed. It says nothing about whether
it was. The property that makes a change reviewable is not its directory but
the merge it has to pass through, which is [ADR-0014](./0014-core-is-authored-in-a-worktree.md)'s
whole subject.

So `<clone>/.githooks/**` joins `denyWrite`, and it joins as the denial
`packages/core/**` is rather than the one `.git/hooks/**` is. The two above are
denied because there is no merge to stand between the agent and the running
code; this one is denied so that there is. The path is absolute and live-tree,
so a Worktree's `.githooks/` matches nothing: the agent authors a hook there
under its ordinary Profile, and it becomes a file git runs when a human merges
it.

**Nothing is lost, and now it is true rather than claimed.** The paragraph above
about hooks coming back better is what this amendment makes accurate: the agent
writes hooks, they travel in a diff, a human reads them before they run.
Measured in `sandbox.boundary.test.ts`: a write to the live tree's
`.githooks/pre-commit` is refused by the kernel, the same write inside
`.claude/worktrees/…` succeeds, and git still runs the hook it finds once one is
there.

**One qualification on that last clause, because it is the kind that gets
dropped.** The hook-running half is measured with `GIT_CONFIG_GLOBAL` pinned in
the probe, and it needs to be: git treats an unreadable `~/.gitconfig` as fatal,
and `$HOME` is denied by design, so on a machine whose developer has a global
git config *every* git command inside the Sandbox exits 128 — `git --version`
included, since git stats the global config before dispatching a subcommand.
That is a read-allowlist gap rather than anything this ADR decided, it is
independent of the hooks deny (measured with the deny in force and with it
absent: identical either way), and it is tracked as its own ticket. Until it is
closed, read every "git still works" sentence in this ADR as *permitted by the
policy*, which is what it measures, rather than as *works on your machine*.

**Why this was not visible in the original.** The two denials this ADR added
were chosen by the property "no diff shows this", and `.githooks/` genuinely
does not have that property. It has a different one — "no diff shows this *yet*"
— and the list had no entry of that kind at the time, because `packages/core/**`
was on it for a reason nobody had written down in these terms. Both directories
are now on the list, and the reasoning above covers both.
