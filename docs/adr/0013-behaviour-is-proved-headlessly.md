# ADR-0013 — Behaviour is proved headlessly, so the bare page is removed

**Status:** accepted

## Context

varnick shipped three renderings of one set of machines. `#/designed` is the
chat. `#/states` is every state on one page, each card the real component driven
by a real actor parked in the state it names. `#/bare` was the third: no design
system, native controls, a `<dl>` of every context field, one button per event
the machine would currently accept, seed checkboxes that made the sandbox check
or a Turn or a save fail on demand, and the transition log.

It came from the machine-first pipeline, where the bare page is **stage 4** and
its purpose is precise: prove the behaviour is complete *before* any visual
decision is made, so that design cannot cover for a gap in the machines. It did
that job. Three defects it found are recorded in `docs/agents/` and in the
machines' own comments — a duplicate Surface id that React reported while the
page was being driven, and a `START` refusal that only the page ever pressed.

## Decision

The bare page is removed. varnick has two renderings.

## Why

**Its purpose expired, and the thing that replaced it is better.** The question
the bare page answers is "is the behaviour complete", and `drive.ts` now answers
it with 434 assertions at the actor seam, in CI, on every change — including the
things the page could never show: an event that must be *refused*, a parallel
region that must stay independent, a delay window that must expire, a final state
that accepts nothing. The page could only show what a person clicked. A surface
that answers a question worse than the thing beside it, and only when someone
remembers to look, is not a second opinion.

**Everything it displayed is now displayed properly.** The `<dl>` was the only
place `sandboxError`, `agentError`, `refusal`, `mintUrl` and `credentialError`
could be seen when it was written. All five are on the chat now — the conditions
strip and the surface's own problem lines — so the dump had become a worse
rendering of shipped UI.

**Every state it could reach is a card.** `#/states` creates each scenario cold
from an entry point with frozen actors, and `drive.ts` asserts that each one
actually reaches the paths it claims. Failure states are not something to be
driven into; they are addressable.

**It is a stage, not a deliverable, and the two were being confused.** CLAUDE.md
listed it beside the states page as product code that ships. The states page
earns that — it is coverage-checked, its banner fails when a state has no card,
and a ticket points at one. The bare page earned it during stage 4 and kept the
billing afterwards.

## What is lost, named rather than glossed

**Failure injection into a live run.** `SeedControls` — `failSandbox`,
`failCredential`, `failStore`, `failMint`, `failTurn`, `failSave` — had exactly
one caller, the bare page's checkboxes, and is removed with it. You can no longer
make a *running* varnick fail on demand. Every state that reached is a card and
every failure path is asserted, so what is gone is the driving rather than the
seeing.

If that turns out to matter it comes back as a debugging console that says it is
one — not as a design-free rendering with the toggles bolted to it. Those were
two features sharing a page because they were built in the same week.

**The transition log and the hand-send event bank** go the same way, and are the
same category: a debugging console, not a rendering.

## What went with it

`BarePage.tsx`, `bare.css`, the `#/bare` route, its View-menu entry, `SeedControls`
and the six failure branches in `seededActors`, and the seventeen assertions in
`drive.ts` that had just been written to enforce the bare rule mechanically
(ticket 43).

**Those assertions were written an hour before this decision, and that is not an
argument against it.** Sunk cost is not a reason to keep a surface. It is worth
recording that the work which made the page's rule checkable is also what made
it clear how little the page was doing: writing down what it must never contain
is a short document, and reading it back is what raised the question.

## What this does not license

**The states page is not next.** It answers a question nothing else answers —
what every state *looks like*, through the real component — and its coverage
banner is a gate that fails. The argument here is specifically that a surface
whose job has been taken over should go, not that developer surfaces are
overhead.

**And the stage stays.** `/machine-first-prototype` should still produce a bare
page: proving behaviour before design is the point of the stage, and a project
without a `drive.ts` yet has nothing else doing it. The contract in
`docs/agents/stage-contracts.md` is unchanged apart from a pointer here. What
changes is that finishing with one is not the same as shipping one for ever.
