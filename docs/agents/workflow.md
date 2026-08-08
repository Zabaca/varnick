# Development workflow

The single flow for building a feature in this repo. Follow it in order. Every stage names the artifacts it reads and writes; the detail lives in [stage-contracts.md](./stage-contracts.md).

Skills are invoked by the user — most carry `disable-model-invocation: true` and cannot be chained automatically. When a stage's skill has not been run, say so rather than improvising its output.

## The stages

```
HUMAN   1. /grill-with-docs          → CONTEXT.md, docs/adr/
HUMAN   2. /to-spec                  → .scratch/<slug>/spec.md   (prose, no code)
          ⤷ gate: does this touch UI?
HUMAN  2.5 /impeccable shape         → .impeccable/surfaces/<slug>.md   (UI work only)
          ⤷ job, audience, direction, boundaries. No states. No code.
          ⤷ gate: machine decomposition announced in one line, confirmed
AUTO    3. /machine-first-prototype  → machines, drive.ts, bare, states, high-fidelity
                                       amends spec; writes CONTEXT.md terms and
                                       the decomposition ADR; inherits the brief
HUMAN   4. use it; iterate visuals; lock look and experience
          ⤷ visual change: free
          ⤷ behavioural change: loops back to stage 3, re-amend spec
AUTO    5. /to-tickets               → integration slices only
        6. /implement                → +/tdd at the machine seam, /code-review
        7. /impeccable document      → DESIGN.md + .impeccable/design.json
        8. PR
```

## Once per project, before stage 1

`/impeccable init` writes `PRODUCT.md`. Impeccable will not establish a visual world without it, and stage 3 needs it. This happens once; it is not part of the per-feature loop.

## The UI gate

Stages 2.5, 3, 4, and 7 apply only to work that touches UI. For backend-only or non-visual work the flow is stages 1, 2, 5, 6, 8.

Answer the gate question explicitly at the end of stage 2: **does this touch UI?**

## What is different about this flow

**Stage 3 produces real product code, not a throwaway.** The machines, the bare page, the states page, and the high-fidelity UI all live in the main codebase and ship. The states page is a permanent coverage-checked test surface, not a demo. The bare page is the permanent design-free behavioural surface, routed dev-only.

**The spec is authored early and amended in place.** Stage 2 writes prose from what is known. Stage 3 discovers states prose cannot predict — loading, empty, filtered-empty, error, every in-flight state — and stage 4 may change more. Those are appended to the same spec file, tagged with their source. The spec must be current before stage 5 reads it.

**Tickets are thinner than usual.** By stage 5 the UI and the machines exist. Tickets cover persistence, the seams where stubbed actors become real services, auth, migrations, and failure paths that only exist against a real backend. They do not cover "build the UI".

**The view layer is pure.** See [ADR-0001](../adr/0001-pure-view-layer.md). This is what lets the states page and the live app be the same code rather than two copies that drift.

## One rule about states

**A state is named in exactly one place: the machines.** Their exported path lists are the source, `CONTEXT.md` defines the names, `#/states` renders them, and a ticket points at a card. Nothing else enumerates them.

That is why stage 2.5 writes no states. `/impeccable shape` offers a *States and ranges* section; here it keeps the ranges and drops the states. Ranges are content facts a builder needs before the machines exist — how many messages, how long a tool output, what an empty Workspace holds. States are machine facts discovered *by* stage 3, and prose written before them is a guess that goes stale within a day and then contradicts the code.

This is checked, not trusted: `drive.ts` asserts that no surface brief contains a declared state path or a states heading. A brief that starts enumerating states fails the build.

## Gates that must not be skipped

1. **Decomposition confirm** (end of stage 2). The prototype skill announces its machine decomposition in one line — *"Three machines: X parent, Y per item, Z per file"*. Confirm it before any code is written. Four auto-generated phases ride on that one decision.
2. **Headless verification** (inside stage 3). No component is written until `drive.ts` passes. This is not ceremony; it catches undo windows that are decorative, actors that never finish, and guards that can never fail — none of which are visible in a rendered page.
3. **Visual lock** (end of stage 4). A visual change at this gate is free. A change to which events are legal invalidates the machines, the glossary entries, and the decomposition ADR — it loops back to stage 3.
4. **Spec currency** (before stage 5). `to-tickets` slices against the spec. If the spec still describes the pre-build guess, the slices describe an app nobody built.

## Where each document is written

| Document | Written by | When |
| --- | --- | --- |
| `PRODUCT.md` | `/impeccable init` | Once per project, before stage 1 |
| `CONTEXT.md` | `/grill-with-docs`, stage 3 | Lazily, as each term resolves |
| `docs/adr/` | `/grill-with-docs`, stage 3 | When a decision passes the three ADR tests |
| `.scratch/<slug>/spec.md` | `/to-spec`, amended by stages 3 and 4 | Stage 2, then in place |
| `.impeccable/surfaces/<slug>.md` | `/impeccable shape` (stage 2.5), amended by stage 3 | Before the machines; amended when the build teaches something |
| `.scratch/<slug>/issues/NN-*.md` | `/to-tickets` | Stage 5 |
| `DESIGN.md` + `.impeccable/design.json` | `/impeccable document` | Stage 7, from shipped code |

`DESIGN.md` is written at finish, from the built world. A design system written before the build gets defended against reality instead of describing it.
