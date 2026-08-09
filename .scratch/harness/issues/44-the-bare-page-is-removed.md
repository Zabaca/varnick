# 44 — The bare page is removed

**What to build:** Two renderings instead of three, and the doctrine that named the third amended rather than quietly contradicted.

**Blocked by:** 41, 42, 43.

**Status:** done.

**Realizes:** no state path.

## Why this exists

Asked by the developer, an hour after ticket 43 made the bare page's rule
mechanically checkable: *"let's remove the bare layer? i think we don't need."*

The reasoning is in [ADR-0013](../../../docs/adr/0013-behaviour-is-proved-headlessly.md)
rather than here, because it reverses a principle stated in four places —
`CLAUDE.md`, `PRODUCT.md`, `docs/agents/workflow.md` and
`docs/agents/stage-contracts.md` — and a reversal that lives in a closed ticket
gets re-argued from scratch.

The short of it: the bare page is **stage 4** of the machine-first pipeline, and
its job is to prove behaviour before design can cover for a gap. `drive.ts` does
that now with 434 assertions in CI, including the things a page cannot show — an
event that must be refused, a region that must stay independent, a window that
must expire. `#/states` shows every state through the real component. A surface
that answers a question worse than the thing beside it, and only when somebody
remembers to look, is not a second opinion.

## What went

`BarePage.tsx`, `bare.css`, the `#/bare` route, its View-menu entry (States moves
to ⌘2), `SeedControls` and the six failure branches in `seededActors`, and
ticket 43's seventeen assertions.

## What was lost, on purpose

**Failure injection into a live run.** `useHarness(controls)` had one caller and
it was the bare page's checkboxes. You cannot make a *running* varnick fail on
demand any more. Every state that reached is a card on `#/states`, created cold
from an entry point, and every failure path is asserted at the actor seam — so
what is gone is the driving, not the seeing. If it turns out to matter it comes
back as a debugging console that says it is one, rather than bolted to a
rendering.

## What was kept

**The provenance.** Comments in `harness.ts` and `drive.ts` saying a defect was
*"found by driving the bare page"* stay as they are. They are history and they
are true; the page earned them.

**The stage.** `/machine-first-prototype` should still produce a bare page. A
project with no `drive.ts` yet has nothing else proving behaviour. What changed
is that finishing with one is not the same as shipping one for ever, which
`stage-contracts.md` now says.

## Watch for

Five live claims about the page were found in code and ADRs and corrected rather
than deleted — `chat-surface.tsx` claimed `#/bare` showed full machine state,
`surface.ts` said it could drive a Surface to `unloaded` by hand, ADR-0009 left a
"not decided here" about it writing over a transcript. That last one was
generalised instead of dropped: **any second surface that spawns a Session
shares this one's id**, which is the hazard rather than the page.

- [x] Two renderings, both in the View menu
- [x] Nothing references the page as something that exists
- [x] The doctrine in four documents amended, with an ADR behind it
- [x] `bun test packages`, `bun run drive`, typecheck, lint and `cargo test` green
