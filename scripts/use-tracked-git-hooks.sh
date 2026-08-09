#!/bin/sh
#
# Point git at the tracked hooks directory.
#
# ADR-0016: `.git/hooks/**` and `.git/config` are denied to the agent, because
# `.git` is the one part of the repository no diff ever shows. A hook written
# there runs unconfined on the next commit with nothing for anyone to read —
# including the merge commit that was supposed to be the gate. So hooks live in
# .githooks/ instead, where they are tracked files that travel through the merge
# and a human reads before they run.
#
# This is the bootstrap, and it has to be a human's: `core.hooksPath` lives in
# `.git/config`, which is precisely what the agent may not write. It runs from
# `postinstall`, which ADR-0002 already accepts as a host execution surface.
#
#   sh scripts/use-tracked-git-hooks.sh
#
# It never fails an install. There are three reasons it can do nothing and none
# of them is a broken checkout:
#
#   * there is no git repository here — a tarball, or a vendored copy
#   * the value is already what it should be, which is every run after the first
#   * git was refused the write, which is what the *agent's* own `bun install`
#     sees from inside the Sandbox, because `.git/config` is the thing ADR-0016
#     denies it
#
# The third is why this warns rather than exiting non-zero. An agent running
# `bun install` under the policy must not have its install broken by the denial
# that is the whole point of the denial.

set -u

# The same spelling as TRACKED_HOOKS_DIR in packages/harness/src/sandbox.ts.
# Relative on purpose: git resolves a relative core.hooksPath against the top of
# the working tree, so one value is correct in the clone and in every worktree,
# and .githooks/ is tracked so every worktree has it.
hooks_dir=".githooks"

git rev-parse --git-dir >/dev/null 2>&1 || exit 0

current="$(git config --get core.hooksPath 2>/dev/null || true)"
if [ "$current" = "$hooks_dir" ]; then
  exit 0
fi

if git config core.hooksPath "$hooks_dir" 2>/dev/null; then
  printf 'varnick: git hooks now come from %s/ — tracked, in the diff, read before they run.\n' \
    "$hooks_dir"
else
  printf 'varnick: could not set core.hooksPath=%s; .git/config is not writable here.\n' \
    "$hooks_dir" >&2
  printf '         That is ADR-0016 working if this ran under the Sandbox. On the host,\n' >&2
  printf '         run `git config core.hooksPath %s` once.\n' "$hooks_dir" >&2
fi

exit 0
