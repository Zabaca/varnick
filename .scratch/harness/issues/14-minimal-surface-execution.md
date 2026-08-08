# 14 — Run one real Userspace module

**What to build:** A developer asks the agent for something, the agent writes a Userspace module, and it runs. That is the loop the whole product exists for, reduced to its smallest honest form: one module, loaded and rendered, and a failure that stays contained.

**Blocked by:** 05 (the agent has to be able to write the module before anything can run it).

**Status:** done — see Comments for two findings the dev server owns rather than the loader

**Realizes:** `surface.loading`, `surface.loaded`, `surface.failed`

Scope is deliberately narrow — enough of the loader to execute one real module, no more. **Not** a Surface framework, a layout system, a registry, or a way to arrange several. Everything past the one module is what a fork builds, and widening this ticket re-opens a scope line that has now been drawn twice.

The machine already exists and is proven by `drive.ts`: a broken module is a failed Surface, not a dead application ([ADR-0004](../../../docs/adr/0004-core-never-statically-imports-userspace.md)). This ticket supplies the loader, not the model.

- [x] Surfaces are discovered from the filesystem, never registered — adding one is creating a file, which matters because the agent cannot write the file a registry would live in ([ADR-0002](../../../docs/adr/0002-core-userspace-boundary.md))
- [x] Loading goes through dynamic `import()` inside a try/catch; a `no-restricted-imports` lint rule forbids static imports from Userspace inside Core, so the rule holds on the day the agent writes something that does not compile
- [x] A module that does not compile shows what failed and why, and can be retried without restarting varnick
- [x] One broken Surface leaves the others running and the chat alive — the conversation that caused the failure is the conversation that fixes it
- [x] **`SURFACE_STATE_PATHS` moves into the states page's covered set and gains cards.** They are waived on the banner today only because nothing renders a Surface. That waiver is this ticket's debt and expires with it — leaving it in place after this lands is exactly the drift the banner exists to catch

Covers stories 31, 36, 37, 38, 39, 40.

## Comments

Two things the browser and the dev server own, found by breaking
`packages/userspace/surfaces/welcome/index.tsx` for real and driving the page
over CDP. Neither is the loader's to fix, and both are written down rather than
worked around.

**Vite's error overlay covers the window.** When a Userspace module fails to
transform, Vite mounts `<vite-error-overlay>` at full viewport size. Underneath,
everything the ticket asks for is true and was measured: the Surface is `failed`
with its reason, the retry is offered, the composer is still there and still
editable. But the developer has to dismiss the overlay to reach it, and for that
moment it reads as a dead app rather than a failed Surface — the exact
impression [ADR-0004](../../../docs/adr/0004-core-never-statically-imports-userspace.md)
exists to prevent. `server.hmr.overlay: false` in `packages/core/vite.config.ts`
removes it, at the cost of losing the overlay for *Core* errors too, which is a
trade worth deciding deliberately rather than inside this ticket. The overlay
also shows the exact parse error, which is more than the Surface panel can say —
see below.

**A retry cannot re-fetch a module the browser has already failed to load.**
`RETRY` re-runs the loader — measured, the attempt counter climbs and the panel
says which attempt failed — but the browser keeps a failed module record for the
URL and rejects from it without asking the server, so no request goes out and
the same message comes back. In the loop that matters this costs nothing:
fixing the file makes Vite reload the page and the Surface loads, which was also
measured, and a reload is not a restart — the agent process, the Session mirror
and the transcript all survive it. Busting the cache would mean composing the
dev server's own module URL inside Core and marking the import `@vite-ignore`,
which is Vite plumbing in Core and breaks the bundled path.

That second finding is also why the failed panel says *"did not load — Failed to
fetch dynamically imported module"* rather than the parse error: the reason is
in the dev server's 500 body, which a rejected `import()` does not carry.
