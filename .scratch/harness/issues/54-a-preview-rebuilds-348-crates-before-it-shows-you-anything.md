# 54 — A Preview rebuilds 348 crates before it shows you anything

**What to build:** A Preview opens in seconds when `src-tauri` is unchanged.

**Blocked by:** None — can start immediately.

**Status:** done — 348 crates became one, measured. See the foot.

**Realizes:** no state path.

## What happens

The first Preview of a Worktree compiles Tauri from scratch — measured at **348 crates**, including `tao`, `wry`, `objc2-app-kit` and `window-vibrancy` — because a fresh worktree has its own empty `src-tauri/target/`.

That is minutes, every time, for every new Worktree. And it is paid *after* the developer has approved the Fence dialog, so the sequence is: read the hunks, decide, then wait several minutes staring at nothing.

## Why it matters more than it looks

[ADR-0014](../../../docs/adr/0014-core-is-authored-in-a-worktree.md) argues the Preview exists so that reviewing a change means **using** it rather than reading a diff. A four-minute wall in front of that is not a slow feature; it is the feature not being used. The developer reads the diff instead, which is the outcome the Preview was built to improve on.

## The fix, and the reason it is known to work

`CARGO_TARGET_DIR` pointing at the live clone's `src-tauri/target`. Every worktree then shares one build cache, and a Worktree that changed no Rust — which is most of them, since most Core changes are TypeScript — links against what is already there and starts immediately.

This was measured today by hand, outside the product: four worktree agents were given a shared `CARGO_TARGET_DIR` and none of them paid a Tauri build.

## Watch for

- **The target directory is a build artifact, not source**, so sharing it crosses no boundary the Sandbox draws. It is already gitignored. Say that in the code, because a shared path between a worktree and the live tree looks like a boundary question and is not one.
- **Concurrent builds are the thing to actually check.** Cargo takes a lock on the target directory, so two Previews building at once serialise rather than corrupt — verify that rather than assuming it, and decide whether serialising is acceptable or whether a per-worktree directory under one shared root is better.
- A Worktree that *does* change `src-tauri` still pays a rebuild, and should. That is the case the dialog raised for.
- `packages/core/scripts/dev.ts` is where the launch is composed, so it is where this belongs — next to the `bun install` bootstrap, which is the same class of decision and was already made there.

- [x] A Preview of a Worktree that changes no Rust opens without a Tauri build
- [x] A Preview of a Worktree that changes `src-tauri` still rebuilds
- [x] Two Previews building at once do not corrupt the shared target
- [x] The comment says why sharing a build directory is not a boundary question

Found by driving the loop: the first real Preview compiled 348 crates while the developer waited.

## Measured

A fresh worktree, no Rust changed, building into the owning clone's target:

```
   Compiling varnick v0.0.0 (…/.claude/worktrees/target-share-probe/src-tauri)
    Finished `dev` profile [unoptimized + debuginfo] target(s) in 7.02s
```

**One crate, seven seconds.** All 348 dependencies were reused — `tao`, `wry`,
`objc2-app-kit` and the rest never entered the build. Only `varnick` itself
recompiles, because its source path differs, and that is the part that has to.

**A Worktree that changes `src-tauri` still rebuilds**, which is the same
measurement read the other way: touching `src/lib.rs` produced a recompile.
Nothing here suppresses a build; cargo's fingerprinting decides, and this only
says where the artifacts already are.

**Two builds at once serialise rather than corrupt** — run concurrently against
the shared directory, the second said so out loud and both finished green:

```
B:     Blocking waiting for file lock on build directory
A:    Finished `dev` profile … in 2.02s
B:    Finished `dev` profile … in 3.88s
```

That is accepted rather than worked around. Waiting for a build that is already
running beats running it twice, which is what per-worktree directories would do.

## Where it lives

`sharedTargetDir` in `packages/core/dev-server.ts` — a pure function over a path,
asserted in `drive.ts`, for the same reason `hotUpdateVerdict` is: the
alternative is a build you have to sit through to find out. `scripts/dev.ts` is
the spawn, beside the `bun install` bootstrap, which is the same class of
decision and was already made there.

Two answers are `null`, and both matter: **the live tree**, which must pay and
change nothing, and **a developer who set `CARGO_TARGET_DIR` themselves**, who
has already answered this question. Overriding them would be the same class of
surprise as varnick picking a port they did not ask for.

## Why sharing is not a boundary question

Stated in the code because the reflex to check is the right one in general.
`target/` is a build artifact, not source: nothing in it is reviewed, nothing in
it is merged, it is gitignored, and it is reproducible from the sources on either
side. The Fence exists so that code the agent wrote cannot become code the host
runs without a human reading it — and a Preview already runs the agent's unmerged
code, deliberately, which is what a Preview *is*. Sharing the cache changes
nothing about what is read or what is run.
