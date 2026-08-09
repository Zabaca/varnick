# git's own directory is outside the review path

**Status:** accepted

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
```

and set `core.hooksPath` to a tracked directory (`.githooks/`), which is what
husky and lefthook do.

## Why the agent loses nothing it can use

Hooks come back **better** than they were. As tracked files they appear in the
diff, travel through the merge, and are gated by the same review as everything
else — the agent writes them freely and a human reads them, which was never true
of `.git/hooks`.

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
