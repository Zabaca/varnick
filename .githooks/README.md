# Git hooks live here, and they are tracked

`core.hooksPath` points at this directory, which is what husky and lefthook do.
`scripts/use-tracked-git-hooks.sh` sets it, from `postinstall`.

Put a hook here under its ordinary git name — `pre-commit`, `commit-msg`,
`pre-push` — and make it executable. Nothing else is needed: git runs what it
finds here instead of `.git/hooks`.

## Why not `.git/hooks`

`.git` is not versioned, so it is on no branch, in no diff and in no merge —
the one part of the repository nobody reviews. A hook written there runs
unconfined on the next commit, **including the merge commit that was supposed
to be the gate**. So `.git/hooks/**` and `.git/config` are denied to the agent
at the kernel; see [ADR-0016](../docs/adr/0016-gits-own-directory-is-outside-the-review-path.md).

The agent loses nothing by it. It writes hooks here freely, and they reach your
machine the same way every other change does: through a diff you read.

This file also exists so the directory itself is tracked — git does not carry
empty ones, and a `core.hooksPath` pointing at nothing would be a bootstrap that
looked done.
