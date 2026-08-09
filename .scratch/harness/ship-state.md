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

## Merged

**45, 47, 46, 49** — in that order, full suite between each, four worktrees reaped. Suite after 49:

- `bun test packages` — **546 tests, 1 skip, 0 fail**, 1508 expect() calls, 18 files
- `bun run drive` — **537 assertions**
- `cargo test --lib` — **110 passed**

## In flight

- **48** on `ticket/48-launch-preview` — unblocked by 46
- **50** on `ticket/50-diff-view` — unblocked by 49

When each returns: read the diff, run the full suite, merge, re-run, mark done, reap.

## Owed before this is closed out

**Ticket 46's first acceptance box is deliberately unticked.** Two Tauri *windows* is not observable headlessly and the subagent was told not to try. What was measured: two frontends coexisting on 1420 and 1421, and `tauri dev --config` reaching `build > devUrl`. That two Tauri *hosts* then coexist is inference.

Verify it once at close-out rather than now — a `tauri dev` build contends with the in-flight agents for `CARGO_TARGET_DIR`, and it is one check either way:

```
bun run dev:app --port 1421     # beside a varnick already holding 1420
```

## Findings carried out of review, already fixed

- `scripts/**` was writable while the `package.json` that invokes it was denied. Same shape as `.git/hooks` without `.git/config`; now denied.
- `.git/config` → `.git/config*`, so the lock goes with the file.
- `sandbox.ts` held a literal NUL byte, so git treated the Fence's own generator as **binary and showed no diff for it**. Replaced with an escape.
- ADR-0003 and ticket 25 both claimed `allowLocalBinding` stays `false`; corrected in place, not deleted.
- `CLAUDE.md` still named Clone, Collect and Escalation, and listed an incomplete `denyWrite`.

## Open, not fixed

**Fence is defined in four places, not one.** `FENCE_PATHS` in `packages/harness/src/fence.ts` is the single list for the three consumers, and `fence.test.ts` asserts every entry appears in the generated `denyWrite` — so the two readings fail a test if they drift. `sandbox.ts` was deliberately *not* refactored to consume it: that is policy generation, and rewriting it to remove a duplication risks the fence. If the literal single list is wanted, it is its own careful ticket.

**`sandbox-policy.json` is on `denyWrite` but is not Fence** under the wording in ADR-0014 and `CONTEXT.md` — the generator and the baseline are, the generated output is not. It reads surprising and it is harmless for the dialog, because the file is gitignored and can never appear in a worktree diff.

## Things that will bite

**Ticket 47 may come back with a negative result**, and that is a legitimate outcome rather than a failure. If a nested sandbox *can* widen the outer one, `enableWeakerNestedSandbox: false` does not mean what its name says and ADR-0014's Preview argument needs rewriting. Do not let it be quietly assertion-fitted.

**Ticket 45 and ticket 47 both touch the containment story** and may collide in `packages/harness/src/`. Merge 45 first.

**Ticket 49 adds state names**, which means `CONTEXT.md`, the machine's exported path list, and a card on `#/states` all have to agree, or the coverage banner fails. That is the gate, and it is the most likely thing to come back half-done.

**Ticket 46's acceptance criteria are partly unmeasurable headlessly** — two Tauri windows is not something a subagent should attempt. Expect an honest "not measured" on those, and verify them by hand before calling the ticket done.
