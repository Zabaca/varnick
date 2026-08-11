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

**Found on the way, and not fixed here.** Three read-allowlist gaps, none of
them this ticket's and none of them interacting with the deny (measured with the
`.githooks` entry in force and with it absent: identical either way).

1. **`~/.gitconfig`.** Every `git` command run inside the Sandbox fails on a
   machine that has one — `fatal: unable to access '…/.gitconfig': Operation not
   permitted`, exit 128 — because `$HOME` is denied by design and git treats an
   unreadable global config as fatal rather than as a warning. `git --version`
   is enough to trigger it: git stats the global config before dispatching a
   subcommand, so the blast radius is total rather than config-only. It takes
   `git worktree add`, `git commit` and `git merge` with it, which is the whole
   of ADR-0014's model. This is the cause of **one** failing assertion on `main`,
   at `sandbox.boundary.test.ts:469` — not two, which is what an earlier version
   of this note said. Closing it means either reading one file back out of the
   denied root or setting `GIT_CONFIG_GLOBAL` in the agent's real environment,
   and both are Fence decisions rather than deny-list entries.
2. **`/nix/var/nix/profiles/default`.** A nix install, hit as
   `file-read-metadata`. This is the cause of the *other* pre-existing failure,
   `the kernel denials reach varnick, and only the unintended ones are said out
   loud`, at `containment.probe.test.ts:1463`. A different gap with a different
   fix, corroborated independently.
3. **`/opt/homebrew/bin/git`.** A third gap, observed as `file-read-metadata` in
   the same probe runs. Nothing here depends on it — noted so it is not
   rediscovered as part of either of the two above.
