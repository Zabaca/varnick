# 05 — The main window is served from a built artifact

**What to build:** work landing in the live tree stops reloading the window the
developer left open. The main window serves a built artifact instead of a dev
server watching the clone, so nothing under it moves while they are away.

Today a change under Core sends a full reload to the window. That is deliberate
and correct while the live tree is what the window renders — hot-swapping the
module that owns the Session would remount the machine holding the conversation.
It stops being correct once merges land unattended, because then the reload
happens all night, to a window nobody asked to reload.

The dev server stays for Previews, which is where hot reloading is still what
the developer wants, and where the work now happens.

This ticket also establishes where built artifacts live and which one the host
serves — the convention the release chain builds on.

This touches the host and lands through a human merge.

**Blocked by:** None — can start immediately.

**Status:** ready-for-agent

- [x] The main window is served from a built artifact, and no watcher is attached to the clone it was built from
- [x] Editing a Core file in the live tree does not reload the open window
- [x] A Preview still runs from a dev server, and hot reloading inside a Preview is unchanged
- [x] Where artifacts live, and which one is currently served, is a fact something else can read — the release chain needs to write into it and switch it
- [x] The existing hot-update decision is left in place and its assertions still pass, since what changes is what calls it
- [x] The lost behaviour is recorded rather than left to be discovered: live Surface hot reloading no longer works in the main window, and does work in a Preview

## Comments

**Authored, checked, and waiting on a human merge.** Branch
`main-window-serves-build`, three commits, a fast-forward onto `main`.

It cannot land unattended and that is correct rather than a problem: the branch
edits `src-tauri/tauri.conf.json` — `beforeDevCommand` — which is `src-tauri/**`
and therefore Fence. The ticket said so up front. The edit is one line and there
is no version of this change without it: `beforeDevCommand` is the whole of how
"what serves the window" reaches `bun tauri dev`, and moving it into the
launcher's `--config` overlay would leave bare `bun tauri dev` — the documented
first-run command — still starting a dev server on the live tree.

Checks, all in the worktree: `bun run typecheck` pass, `bun run lint` pass,
`bun run drive` pass (895 assertions, up from 838), `bun run build` writes the
artifact, `cargo test` 144 passed / 0 failed. `bun test packages` is 794 pass /
1 skip / 2 fail, and both failures are pre-existing on `main` at 75a6e42 —
verified by stashing and re-running — in `packages/harness/**`, which this branch
does not touch.

What tickets 06 and 07 build on: `packages/core/artifacts.ts`. The store is
`<clone>/.varnick/builds/<id>/` with a `served` file naming one id. A
pre-release writes a new id and **leaves `served` alone**; promotion rewrites it;
`bun run build` does both because a developer who typed it asked for this tree
now. Artifacts are assembled in `.<id>.incoming` and renamed into place, and the
leading dot is a name `isArtifactId` refuses, so a half-written build can never
be served. The "nothing resolves, so build one" branch in
`packages/core/scripts/serve.ts` is the placeholder ticket 07's fallback
replaces.
