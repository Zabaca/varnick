# The agent only works in a Worktree, and the live tree moves by fast-forward

The agent works in its Session's Worktree and nowhere else. In v1 that is a rule the agent is told and Claude Code's permission prompts uphold, not one the kernel enforces (ADR-0004). Landing is `git merge --ff-only` into the Live tree, performed by the Host on request and refused on a dirty tree or a non-fast-forward. Rebasing is the agent's job, in its Worktree, where the tools are.

This one rule, even as a convention, replaces everything the previous version built to let the agent edit the tree it ran from: a deny list of protected paths, a fence, a baseline policy diff, a projected gitconfig, hook-directory denies, unattended landing rules, and a build artifact store with fallback. None of those had anything to protect once the agent left the Live tree.

Consequences: there is no distinction between product code and user code; everything lands the same way. A change to varnick itself, including this document, is written in a Worktree and takes effect only after Landing and a Restart. Squash and merge commits are not offered; a branch that will not fast-forward is not landable.
