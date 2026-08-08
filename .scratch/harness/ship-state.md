# ship loop — state

Written before a context compaction so the loop can continue without it. Delete when the run is over.

## Where things are

`main` at `6076a64`, clean tree, **not pushed** — 41 commits ahead of `origin/main`.

Suite on `main`: `bun test packages` 300 tests / 1 skip, `bun run drive` 219 assertions, `cargo test` 43, `bun run build` clean.

**`cargo` is at `~/.cargo/bin` and is not on the default PATH.** `export PATH="$HOME/.cargo/bin:$PATH"` before any Rust command.

## In flight

Three worktree agents, all branched from `55abb9f`, all still running:

| Ticket | Branch |
| --- | --- |
| 08 compaction | `ticket/08-compaction` |
| 09 plan-usage wiring | `ticket/09-plan-usage-wiring` |
| 14 Surface execution | `ticket/14-surface-execution` |

When each returns: review the diff, run all five commands, merge serially, run the full suite again, mark the ticket `done`, reap the worktree with `git worktree remove --force`.

## Then

**12** (secret resolution) is the last ticket and unblocks when 14 lands. **18** is `needs-info` — a decision for the developer, not an agent. Ticket 11's fourth criterion and ticket 09's marker criterion are deliberately unticked with reasons in their Comments.

After 12: full suite, `/code-review`, `/impeccable document` (the UI changed — ticket 11 moved the default route and ticket 14 renders Surfaces), then the PR.

## Things that will bite a merge

- **Worktrees are checked out stale.** Every agent so far found its worktree at an old commit and had to branch from `main` itself. Check `git log --oneline -3` in the worktree before trusting a diff.
- **Resolve conflicts by hand, not with a regex that keeps both sides.** Doing that dropped a whole function (`toolProbe`) and an unclosed `describe` block in two separate merges. Both were caught by typecheck, not by review.
- **`git add -A` will sweep `.claude/worktrees/` into the commit** as embedded repos if the ignore rule is ever lost.
- **A clean merge is not a green merge.** Ticket 16 merged with no conflicts and went red, because it renamed `DENIED_BINARIES` while ticket 03 was in flight.
- **Ticket 17 merges the policy forward**, so a test that deliberately writes a weaker `sandbox-policy.json` gets it strengthened back. Record a baseline first — see probe 2b in `containment.probe.test.ts`.

## Do not undo

- No unconfined fallback, under any flag or state.
- No second `query()` — every SDK control request rides the confined session. ADR-0003's last consequence; ticket 09 broke it once.
- The login-Keychain, `/Library/Keychains`, write-boundary and probe-7 assertions in `containment.probe.test.ts` and `sandbox.boundary.test.ts` are load-bearing. Strengthen only.
- No test may touch the real Keychain. `security add-generic-password`'s keychain argument is positional and `-w VALUE` before it has caused an accidental write to the real Keychain twice in this run.
