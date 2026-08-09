# ship loop — state

Written so the loop can continue across a context compaction. Delete when the run is over.

## Where things are

`main` at `884bc4d` — the domain model for the worktree amendment. Clean tree, **not pushed**.

Baseline suite on `884bc4d`, measured before any fan-out:

- `bun test packages` — **492 tests, 1 skip, 0 fail**, 1350 expect() calls, 16 files
- `bun run drive` — green
- `cargo test` — **109 passed, 0 failed**
- `bun run typecheck` — clean
- `bun run lint` — clean

**`cargo` is at `~/.cargo/bin` and is not on the default PATH.** `export PATH="$HOME/.cargo/bin:$PATH"` before any Rust command.

**A fresh worktree has no `node_modules`.** Git does not track it, so every worktree agent runs `bun install` first. For Rust, `export CARGO_TARGET_DIR=/Users/uptown/Projects/zabaca/varnick/src-tauri/target` rather than rebuilding Tauri per worktree — safe while only one Rust ticket is in flight at a time.

## The work

Spec amendment: `.scratch/harness/spec.md`, the "Core in a Worktree — amendment" section at the end.
ADRs: 0014 (supersedes 0005), 0015, 0016.

Six tickets, 45–50. The graph:

```
45  sandbox policy: local binding + git's executable config   ─ no blockers
46  second varnick beside the first; Core reloads             ─ no blockers ──┐
47  nested sandbox probe                                      ─ no blockers   │
49  pending worktree changes reach Core                       ─ no blockers ─┐│
                                                                             ││
48  launch_preview: agent asks, host spawns              blocked by 46 ◄──────┘│
50  the diff view, Fence hunks distinct                  blocked by 49 ◄───────┘
```

## In flight

Round one, four worktree agents, branched from `884bc4d`:

- **45** on `ticket/45-sandbox-policy`
- **46** on `ticket/46-port-and-reload`
- **47** on `ticket/47-nested-sandbox-probe`
- **49** on `ticket/49-worktree-changes`

When each returns: read the diff, run the full suite, merge in dependency order, re-run the suite, mark the ticket done, reap the worktree. Then fan out 48 (once 46 lands) and 50 (once 49 lands).

## Things that will bite

**Ticket 47 may come back with a negative result**, and that is a legitimate outcome rather than a failure. If a nested sandbox *can* widen the outer one, `enableWeakerNestedSandbox: false` does not mean what its name says and ADR-0014's Preview argument needs rewriting. Do not let it be quietly assertion-fitted.

**Ticket 45 and ticket 47 both touch the containment story** and may collide in `packages/harness/src/`. Merge 45 first.

**Ticket 49 adds state names**, which means `CONTEXT.md`, the machine's exported path list, and a card on `#/states` all have to agree, or the coverage banner fails. That is the gate, and it is the most likely thing to come back half-done.

**Ticket 46's acceptance criteria are partly unmeasurable headlessly** — two Tauri windows is not something a subagent should attempt. Expect an honest "not measured" on those, and verify them by hand before calling the ticket done.
