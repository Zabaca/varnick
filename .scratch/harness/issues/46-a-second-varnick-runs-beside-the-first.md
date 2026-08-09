# 46 — A second varnick runs beside the first, and Core reloads rather than hot-swaps

**What to build:** Two varnicks run at once without colliding. And a change under `packages/core/**` reloads the window instead of hot-swapping a module, so the conversation that asked for the change survives it.

**Blocked by:** None — can start immediately.

**Status:** ready-for-agent

**Realizes:** no state path.

## The port

`packages/core/vite.config.ts` pins `port: 1420` with `strictPort: true`, and `src-tauri/tauri.conf.json` hardcodes `devUrl: "http://localhost:1420"`. A second instance collides on both. The port becomes an input, and `devUrl` follows it — the two must not be able to disagree, because a `devUrl` pointing at the wrong port produces a window that loads the *other* varnick's frontend, which is worse than a failure.

## The reload

[ADR-0005](../../../docs/adr/0005-two-profiles-live-userspace-cloned-core.md) required an explicit restart after a Core merge, because hot-swapping the module that owns the Session loses the conversation that asked for the change. That was a rule someone had to remember. Make it mechanical: a `handleHotUpdate` that turns any `packages/core/**` change into a full page reload.

A full reload is safe here and a hot swap is not. The Session is durable host-side and resumes from the mirror ([ADR-0009](../../../docs/adr/0009-resume-reads-the-mirror.md)), so a reload costs a moment and loses nothing; a hot swap remounts the machine that holds the conversation.

**Userspace must keep hot-swapping.** "Ask for a Surface and it appears" is the product's main loop and it is a hot update. If this change makes a Surface edit reload the window, it has broken the thing it was meant to protect.

## Watch for

- Both halves are in one file and one config; that is why they are one ticket. They are not one change — say so in the commit.
- The reload rule wants a pure function deciding reload-or-not from a path, so `drive.ts` can assert it without a dev server.
- `1420` stays the default. A developer running `bun tauri dev` in a fresh checkout must see no difference.

- [ ] Two varnicks run at once, each serving its own frontend in its own window
- [ ] The default port is unchanged and a fresh checkout behaves exactly as before
- [ ] `devUrl` cannot disagree with the port the dev server bound
- [ ] A change under `packages/core/**` reloads the window
- [ ] A change under `packages/userspace/**` still hot-swaps
- [ ] The reload decision is asserted headlessly
