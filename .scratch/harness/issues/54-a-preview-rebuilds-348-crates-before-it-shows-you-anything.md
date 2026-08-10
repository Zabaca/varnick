# 54 — A Preview rebuilds 348 crates before it shows you anything

**What to build:** A Preview opens in seconds when `src-tauri` is unchanged.

**Blocked by:** None — can start immediately.

**Status:** ready-for-agent

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

- [ ] A Preview of a Worktree that changes no Rust opens without a Tauri build
- [ ] A Preview of a Worktree that changes `src-tauri` still rebuilds
- [ ] Two Previews building at once do not corrupt the shared target
- [ ] The comment says why sharing a build directory is not a boundary question

Found by driving the loop: the first real Preview compiled 348 crates while the developer waited.
