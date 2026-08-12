# 17 — Say why the host's git is deliberately unprojected

**What to build:** a doc comment on `worktree_listing`
(`src-tauri/src/preview.rs:264`) saying that the absence of `GIT_CONFIG_GLOBAL`
there is a decision rather than an omission.

That function runs git on the **host**, unconfined, as the developer. The
developer's real `~/.gitconfig` is the correct config for it — it is their git,
listing their worktrees, on their machine. Nothing needs projecting and nothing
should be.

The risk this closes is small and specific: ticket 11 put `GIT_CONFIG_GLOBAL` on
every confined git invocation, so the next person auditing git calls will find
this one bare and may add it, believing they have hardened something. They would
be narrowing the host's own git for no benefit, and leaving a comment implying
the host was ever inside the fence.

Worth saying alongside it: a Preview's *confined* processes are already covered,
because a Preview is a second varnick that runs its own `establishSandbox`
against its own clone root. There is no gap here for the variable to fill.

## Why this is a ticket rather than a commit

It is two lines in `src-tauri/**`, which is Fence, so it costs a human merge —
more than the note is worth on its own. **It should ride with the next change
that touches `src-tauri/` for another reason.** Whoever takes that change should
pick this up in the same branch.

The reasoning is already recorded in `packages/harness/src/gitconfig.ts`, where
the design lives, so nothing is lost meanwhile. What is missing is the pointer at
the call site, which is where the mistake would be made.

**Blocked by:** None, but deliberately not worth its own merge.

**Status:** needs-triage

- [ ] `worktree_listing` says the missing `GIT_CONFIG_GLOBAL` is deliberate, and why
- [ ] It names that a Preview's confined processes are covered by their own `establishSandbox`
- [ ] It landed alongside another `src-tauri/` change rather than as a branch of its own

## Comments

Written during ticket 11 and lost before it was committed: the orchestrator
removed the worktree while the change was still uncommitted, having not checked
for a dirty tree first. The agent had delayed the commit to run `cargo test`
first, since it had touched Rust — a reasonable instinct that cost the work.

Two things came out of that worth keeping. **Commit the two-line change before
running the long verification**, not after; the brief said commit as you go and
this is the case it was for. And **check for uncommitted work before removing a
worktree** — `git worktree remove` refuses a dirty tree, but `--force` does not,
and the orchestrator used `--force` by habit.

The `cargo test` failure seen in that worktree — proc-macro dylibs refused by
code-signing policy, fingerprint files vanishing mid-build — was the reaped
directory racing the build, not an environmental problem. Verified afterwards on
`main`: `cargo test` passes, 144 tests.
