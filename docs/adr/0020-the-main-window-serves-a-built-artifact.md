# ADR-0020 — The main window serves a built artifact

**Status:** accepted

## Context

varnick's window has always been a Vite dev server watching the clone. That was
right while a person was the only thing changing the clone: you edit a Surface,
it appears; you edit Core, the window reloads, and
[ADR-0014](./0014-core-is-authored-in-a-worktree.md) made that reload mechanical
rather than a rule somebody had to remember.

`hotUpdateVerdict` is that rule and it is correct. A hot swap of
`packages/core/**` remounts the machine that owns the **Session**, which loses
the conversation that asked for the change, so Core reloads and everything else
swaps.

What changed is who edits the clone. The autonomous run
(`.scratch/autonomous-runs/spec.md`) lands the agent's own Core work while the
developer is asleep. Every merge is a write under `packages/core/**` in the live
tree, every write is a hot update, and every hot update is `full-reload` sent to
whatever window they left open — at whatever hour the merge happened, over and
over, for the length of the queue. The verdict is not wrong. There should not be
a watcher there to ask it.

## Decision

**The live tree's window is served from a built artifact. A Worktree's window is
served by the Vite dev server, unchanged.**

One function decides — `windowSource` in `packages/core/dev-server.ts` — and it
asks the question ADR-0014 already asks: is this tree a **Worktree**? A varnick
running from one is a **Preview**, and a Preview exists so a change can be
*used* before it is merged. Hot reloading is what makes that worth doing, so
nothing about it moves. A varnick running from the live tree is the window the
developer left open, and nothing under it may move.

`tauri.conf.json`'s `beforeDevCommand` is `packages/core/scripts/serve.ts`
instead of `vite`. That script is the branch: it execs the dev server for a
Worktree, and otherwise binds the same port and serves files.

**`hotUpdateVerdict` is unchanged, and so are its assertions.** They are the
regression guard on the half that still runs. What changed is what calls it.

## Where artifacts live

This is the convention the release chain is built on, so it is written down
rather than left implicit in a script.

```
<clone>/.varnick/builds/            the store
<clone>/.varnick/builds/<id>/       one artifact, index.html at its root
<clone>/.varnick/builds/served      one line: the id the window is served from
```

`.varnick/` because that is already where varnick keeps per-clone machine state
— `.varnick/claude`, `.varnick/bin`, `.varnick/tmp` — and because it is already
gitignored. An artifact is a build of one clone on one machine. It is not
history and must never be committed.

**A directory per id and a file naming one**, rather than a single `dist`,
because three later tickets need exactly that and no less:

- a pre-release is **written without being served**, which needs a second
  directory so the artifact under the developer's window is not the one being
  replaced;
- promoting one **switches which is served**, which needs the choice to be a
  fact on disk rather than a path baked into a launch;
- a build that will not start **falls back to the previous one**, which needs
  the previous one still to exist and needs "which one" to be rewritable by the
  host without a rebuild.

Symlinks would answer all three and read worse: `cat served` says what is
running, and a developer looking at a window that will not open can fix it with
a text editor.

**`bun run build` writes the store.** Vite still writes `packages/core/dist`;
that directory is then installed as the artifact `local` and `served` is pointed
at it. A developer who typed `bun run build` asked for this tree, now — which is
the opposite of a pre-release, cut while somebody is asleep, and the reason the
two are different code paths rather than one with a flag.

**A launch builds only when nothing resolves.** A fresh clone has never built,
and `bun install && bun tauri dev` has to open a window; that is the one case.
A launch that rebuilt every time would undo a promoted release on the next
restart, which is the one thing switching the served artifact is for.

## The one thing that is a boundary rather than a convention

`assetPath` in `packages/core/artifacts.ts` turns a request path into a file
path, or into nothing. It is a pure function with its own assertions, and it is
the whole of what stands between an HTTP request and the disk.

The listener binds localhost, so what reaches it is the webview — and the
webview renders **Userspace**, which the agent writes freely, so a Surface can
issue any `fetch` it likes. A path that climbed out of the artifact would be
that Surface reading the developer's home directory over HTTP, which is exactly
what the Sandbox exists to prevent and exactly the hole a static file server is
traditionally how you open.

It is decided by resolving the path and asking whether the answer is still
inside, rather than by rejecting `..` in the input. The second is a filter, and
a filter is a list of things somebody thought of.

## What is lost, named rather than left to be discovered

**Live Surface hot-reloading no longer works in the main window.** "Ask for a
Surface and it appears" is the product's main loop, and in the live tree it now
takes a `bun run build` and a restart. It continues to work, unchanged, in a
**Preview** — and `bun run dev` still opens the same interface in a browser with
hot reloading and no host behind it.

That is the accepted cost of a window that does not move while nobody is
watching, and it was taken deliberately rather than worked around. Restoring it
is out of scope for the autonomous-runs work; whatever restores it has to
explain how a merge at 3am does not reload an open window, which is the problem
that produced this decision.

**Core changes in the live tree are invisible until built.** Edit, restart, and
the window is the artifact it was already serving. The artifact server prints
which artifact it is serving at launch, and ticket 04 puts the version in the
window; before this, the answer to "what am I running" was always "the files on
disk", and it is not any more.

**`tauri dev` still watches `src-tauri/**`** and restarts the host on a Rust
change. That watcher is not removed, and it is not the one this ADR is about:
`src-tauri/**` is **Fence**, an unattended run never merges it, and taking the
watcher away would cost a developer working on the host for no gain to a
developer who is asleep. Named here so that "nothing watches the live tree" is
read as the frontend claim it is.

## Alternatives rejected

**Keep the dev server and suppress the reload for merges.** There is nothing to
key it on. A merge writes files exactly as an editor does, and a Vite plugin
that tried to tell them apart would be guessing at authorship from a path — and
would still be a watcher on the tree, one bug away from reloading.

**Serve `packages/core/dist` directly.** One directory, so a pre-release could
not be written without replacing what the window is serving, and there would be
nothing to fall back to. Every later ticket in the chain would have to invent
the store anyway, one at a time.

**Have the Rust host serve the artifact through a custom URI scheme.** More
faithful to "the host serves it" and the right answer once varnick is a bundled
application, which [ADR-0008](./0008-the-harness-runs-as-one-long-lived-host-process.md)
records as unsolved. Today varnick runs as `bun tauri dev`, the window loads
`devUrl`, and putting the decision in TypeScript is what lets `bun run drive`
assert all of it with nothing built and nothing serving — which is
[ADR-0013](./0013-behaviour-is-proved-headlessly.md)'s argument applied to a
launch path. The store's layout is where the two designs meet: a host that grows
its own file serving reads the same `served` file.
