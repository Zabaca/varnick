# 01 — Deny the tracked hooks directory in the live tree

**What to build:** the agent can no longer write a git hook that will run on the
developer's machine without having passed through a diff. `.githooks` is where
hooks live, `core.hooksPath` points at it, and it is currently writable in the
live tree — so a hook written there is on no branch, in no diff and in nobody's
review, and it runs unconfined on the developer's next commit, including the
merge commit that was meant to be the gate. That is the failure ADR-0016
describes for `.git/hooks`, reappearing at the directory it was redirected to.

After this, hooks are authored in a Worktree like Core and arrive the way the
tracked-hooks README already claims they do.

This is a Fence change and lands through a human merge.

**Blocked by:** None — can start immediately.

**Status:** ready-for-review

- [x] The tracked hooks directory is denied to the agent in the live tree, alongside the entries that already deny git's own executable configuration and the host-invoked scripts
- [x] The generated policy's comments explain the entry in the same terms as its neighbours, naming why a tracked directory still needed denying
- [x] Writing a hook in the live tree is refused; writing one in a Worktree still succeeds
- [x] The recorded baseline is regenerated so the addition reads as varnick's own work rather than as a widening
- [x] An assertion covers the new entry beside the existing boundary assertions
- [x] ADR-0016 is amended, or a note added, so the reasoning covers both directories rather than only the unversioned one

**Found on the way, and not fixed here:** every `git` command run inside the
Sandbox fails on a machine that has a `~/.gitconfig` — `fatal: unable to access
'…/.gitconfig': Operation not permitted`, exit 128 — because `$HOME` is denied
by design. It takes `git worktree add`, `git commit` and `git merge` with it,
which is the whole of ADR-0014's model, and it is why two assertions in
`sandbox.boundary.test.ts` fail on `main` on this machine. Out of scope: closing
it means a decision about the read allowlist or about the agent's git
environment, not a deny-list entry.
