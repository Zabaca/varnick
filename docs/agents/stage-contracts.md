# Stage contracts

What each stage of [the workflow](./workflow.md) reads, writes, and must satisfy before the next one starts. Documents are written **inline as decisions resolve**, not batched at the end — the same discipline `/domain-modeling` applies to `CONTEXT.md` and ADRs.

---

## Stage 2 — `/to-spec`

**Reads:** `PRODUCT.md`, `CONTEXT.md`, `docs/adr/`, `DESIGN.md`, `.impeccable/surfaces/`.

**Writes:** `.scratch/<slug>/spec.md`, prose only.

**Seams.** The spec proposes where the feature will be tested. In this repo the answer is almost always the same: **the machine, driven headlessly**. `drive.ts` runs with no DOM, no framework, and no components, which is the highest seam available, and machine-first decomposition tends to yield one per feature. Write it as such. If stage 3's decomposition turns out to differ from what was approved here, amend the spec's Testing Decisions rather than leaving the approved seam contradicted by the code.

**Exit:** the UI gate is answered explicitly. Does this touch UI?

---

## Stage 3 — `/machine-first-prototype`

The skill is screenshot-driven. For greenfield work there are no screenshots; the spec's user stories and the surface brief are the declared evidence. **Say that substitution out loud** rather than letting states be invented silently.

If `PRODUCT.md` does not exist, stop and run `/impeccable init` first. No visual world is established without durable product truth.

### Phase-to-artifact map

| Phase | Writes | Rule |
| --- | --- | --- |
| 1. Pick machines | `CONTEXT.md` | Every machine, state, event, and actor name is a glossary term. Settle "Blocked" against "Paused" here, inline, as each resolves. State names are the sharpest glossary entries the project will produce. |
| 2. Write machines | `docs/adr/` | The decomposition passes all three ADR tests — hard to reverse, surprising, a real trade-off. One ADR per feature: *state decomposition for `<feature>`*. Record why parallel regions beat a flat enum, or why one child actor per item beat a single collection machine. |
| 3. Verify headlessly | `docs/adr/` (amend) | A guard the drive script proves impossible, or a refused-event rule that turns out to be load-bearing, is a domain decision. Amend the ADR rather than leaving it only in `drive.ts`. |
| 4. Bare page | *nothing visual* | Hard checkpoint. The bare page exists to prove behaviour with no design covering for it. No writes to `DESIGN.md` or the surface brief here. |
| 5. High-fidelity page | `.impeccable/surfaces/<slug>.md` | Visitor mode, audience, chosen direction, memorable moment. Per-surface strategy only — never global product truth, never `DESIGN.md` tokens. |
| 6. States page | `.scratch/<slug>/spec.md` (append) | Loading, empty, filtered-empty, error, and every in-flight state — the states no prose predicts. Each becomes a numbered user story appended to the spec, tagged `(machine phase)`. An amber coverage banner means a state has no scenario. |
| 7. Browser verify | — | Screenshot every page and look at them, then drive the real interactions over CDP. Report what the driver printed, not that it compiled. |

### The visual-world branch at phase 5

- **`DESIGN.md` exists** → inherit it. The token file is generated *from* its frontmatter, not invented. Any deviation is either a bug or a proposed system change; propose it explicitly rather than drifting.
- **`DESIGN.md` missing** → this is a new visual world. Route the world choice through impeccable's `new-work` — the choice belongs to the user — and write the direction contract as the opening comment in the high-fidelity page. Still do not write `DESIGN.md`; that happens at stage 7, from the shipped build.

### Actor contracts

Every actor declares its real-service contract when the machine is written: input shape, output shape, error shape. `drive.ts` asserts the failure and retry branches against a seeded failure, not just the happy path.

Machines verified only against instant-resolving seed actors have unproven latency and failure states, and stage 6 degrades from "integrate" into "rewrite the machines".

### Purity

Every machine and component written in this stage obeys [ADR-0001](../adr/0001-pure-view-layer.md). That constraint is what makes the states page and the live app the same code.

### Exit gate — all true or explicitly waived

1. `drive.ts` passes; the assertion count is reported
2. `CONTEXT.md` defines every state and event name the machines use
3. A decomposition ADR exists, or the three tests were applied and it failed them
4. `.impeccable/surfaces/<slug>.md` exists for the surface
5. The spec carries the states discovered in phases 5 and 6
6. Every actor has a declared real-service contract, with its failure branch asserted

---

## Stage 4 — visual lock

The human uses the high-fidelity page and iterates.

- **Visual change** — spacing, colour, type, density, copy — is free. It touches the components and the surface brief.
- **Behavioural change** — anything that alters which events are legal — invalidates the machines, the glossary entries, and the decomposition ADR. It loops back to stage 3 and the spec is amended again, tagged `(visual gate)`.

Name which kind a change is before making it. Unnamed, this becomes silent rework.

---

## Stage 5 — `/to-tickets`

By now the UI and the machines exist and ship. Tickets cover **integration only**: persistence, the seams where stubbed actors become real services, auth, migrations, and failure paths that exist only against a real backend. The vertical-slice rule still holds; the slices are simply thinner, because the UI layer is already there.

**Each ticket names what it makes real:**

```
**Realizes:** orders.sending, orders.sendFailed
```

`to-tickets` bans file paths and code snippets because they go stale. A state path does not: it is the same string in the machine, in the exported `XXX_PATHS` list, in `CONTEXT.md`, and on the states-page card, and the coverage banner keeps those in sync. It resolves to a live card — `#/states → orders.sending` — rather than a copy of the design.

**Stays out of tickets:** tokens, screenshots, surface-brief prose, "match the design". All of it exists as code already; restating it is pure drift surface.

**Carried in:** the trimmed machine config, under the existing prototype-snippet exception — a state machine encodes a decision more precisely than prose can. The decision-rich parts only, not a working demo.

**Consistency check, both directions:**

- a state with a ticket but no card → the states page is incomplete
- a card with no ticket → either already done, or work was missed

---

## Stage 6 — `/implement`

Test at the machine seam with `/tdd`. Typecheck regularly, run single test files regularly, run the full suite once at the end. Review with `/code-review` before the PR.

Swapping a seeded actor for a real one must not change any machine's states, guards, or transitions. If it does, the model was wrong and the change belongs in stage 3, not here.

---

## Stage 7 — `/impeccable document`

Scan mode over the shipped code. Writes `DESIGN.md` and `.impeccable/design.json` from what was actually built.

This runs **before** the PR. Run afterwards, `DESIGN.md` describes a version that was never shipped.

If `DESIGN.md` already exists, it is not silently overwritten — refresh, overwrite, or merge is the user's call.
