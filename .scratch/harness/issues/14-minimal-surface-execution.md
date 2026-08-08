# 14 — Run one real Userspace module

**What to build:** A developer asks the agent for something, the agent writes a Userspace module, and it runs. That is the loop the whole product exists for, reduced to its smallest honest form: one module, loaded and rendered, and a failure that stays contained.

**Blocked by:** 05 (the agent has to be able to write the module before anything can run it).

**Status:** ready-for-agent

**Realizes:** `surface.loading`, `surface.loaded`, `surface.failed`

Scope is deliberately narrow — enough of the loader to execute one real module, no more. **Not** a Surface framework, a layout system, a registry, or a way to arrange several. Everything past the one module is what a fork builds, and widening this ticket re-opens a scope line that has now been drawn twice.

The machine already exists and is proven by `drive.ts`: a broken module is a failed Surface, not a dead application ([ADR-0004](../../../docs/adr/0004-core-never-statically-imports-userspace.md)). This ticket supplies the loader, not the model.

- [ ] Surfaces are discovered from the filesystem, never registered — adding one is creating a file, which matters because the agent cannot write the file a registry would live in ([ADR-0002](../../../docs/adr/0002-core-userspace-boundary.md))
- [ ] Loading goes through dynamic `import()` inside a try/catch; a `no-restricted-imports` lint rule forbids static imports from Userspace inside Core, so the rule holds on the day the agent writes something that does not compile
- [ ] A module that does not compile shows what failed and why, and can be retried without restarting varnick
- [ ] One broken Surface leaves the others running and the chat alive — the conversation that caused the failure is the conversation that fixes it
- [ ] **`SURFACE_STATE_PATHS` moves into the states page's covered set and gains cards.** They are waived on the banner today only because nothing renders a Surface. That waiver is this ticket's debt and expires with it — leaving it in place after this lands is exactly the drift the banner exists to catch

Covers stories 31, 36, 37, 38, 39, 40.
