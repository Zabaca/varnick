# 46 — A second varnick runs beside the first, and Core reloads rather than hot-swaps

**What to build:** Two varnicks run at once without colliding. And a change under `packages/core/**` reloads the window instead of hot-swapping a module, so the conversation that asked for the change survives it.

**Blocked by:** None — can start immediately.

**Status:** done

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

- [x] Two varnicks run at once, each serving its own frontend in its own window

  Left unticked by the implementer, who measured the two frontends coexisting
  and the `--config` overlay reaching `build > devUrl`, and declined to claim
  the windows from that — two Tauri *hosts* is not observable headlessly and no
  subagent should open one. Measured by hand at close-out instead, with a
  varnick already holding 1420:

  ```
  16179 bun tauri dev                                                    ← the developer's
  16182   node .../tauri dev
  26264     target/debug/varnick                                         ← host one, :1420
  29692 bun tauri dev --config {"build":{"devUrl":"http://localhost:1421"}}
  29696   node .../tauri dev --config …
  30029     target/debug/varnick                                         ← host two, :1421
  ```

  Two hosts, two frontends, neither disturbed. The second one's agent started
  and its violation monitor reported `file-read-metadata /home` as a gap in the
  read allowlist rather than a boundary holding — pre-existing, the same class
  as the `systemkeychaincheck.done` line the boundary probes print, and worth a
  ticket of its own rather than a note here.

  One thing the teardown showed, caused by how it was torn down rather than by
  this ticket: `kill -9` on the Tauri CLI orphans the Vite dev server, which
  keeps holding the port. A SIGTERM to the launcher cleans up properly. Ticket
  35's parent-death detection covers `serve.ts` and `agent.ts`, not this.
- [x] The default port is unchanged and a fresh checkout behaves exactly as before
- [x] `devUrl` cannot disagree with the port the dev server bound
- [x] A change under `packages/core/**` reloads the window
- [x] A change under `packages/userspace/**` still hot-swaps
- [x] The reload decision is asserted headlessly

## Comments

**Implemented on `ticket/46-port-and-reload`.** `packages/core/dev-server.ts`
holds both halves as pure functions; `vite.config.ts` and
`packages/core/scripts/dev.ts` are the two lines that act on them, and
`bun run drive` asserts them with no dev server and no browser.

The port is threaded as **one string, not one number**. `bun run dev:app
[--port n]` builds the `devUrl` once and hands the same value to the Tauri CLI
as a `--config` overlay and to Vite as `VARNICK_DEV_URL`; Vite reads its port
back out of that URL rather than choosing one. The only remaining literal is
`tauri.conf.json`'s default, and `drive.ts` checks it against
`devUrlFor(DEFAULT_DEV_PORT)`. `bun tauri dev` is untouched.

**The first box is left unticked deliberately.** The frontend half was measured:
this worktree's dev server bound `1421` while another varnick's held `1420`, and
both served. The *window* half was not — that needs two Tauri windows, which
this agent was told not to open, and a window cannot be observed headlessly.
Everything between the two is inference: the `--config` overlay was measured to
reach `build > devUrl` (it fails the schema there on a bad value, before any
build), so the CLI does receive it; whether two Tauri hosts then coexist is
unmeasured.

Nothing reached Rust, so there is no `#[cfg(test)]` in `src-tauri` for this —
`devUrl` is consumed by the Tauri CLI, and `src-tauri/src/**` never reads a port.
