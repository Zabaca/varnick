# Domain Docs

How the engineering skills should consume this repo's domain documentation when exploring the codebase.

This repo is **single-context**: one `CONTEXT.md` and one `docs/adr/` at the repo root.

## Before exploring, read these

- **`CONTEXT.md`** at the repo root — the domain glossary, canonical for all terminology
- **`docs/adr/`** — read ADRs that touch the area you're about to work in
- **`PRODUCT.md`** at the repo root — durable product truth: users, purpose, positioning, brand commitments, and what must not be fabricated. It defers to `CONTEXT.md` for terminology.
- **`DESIGN.md`** at the repo root, plus `.impeccable/design.json` — the visual system. Tokens in its frontmatter are normative.
- **`.impeccable/surfaces/<slug>.md`** — per-surface strategy for the route or artifact you're touching.

`PRODUCT.md`, `DESIGN.md`, and the surface briefs are written and maintained by the `impeccable` skill; see [workflow.md](./workflow.md) for when. Read them the same way you read `CONTEXT.md` — as constraints on the work, not as things to reproduce.

If any of these files don't exist, **proceed silently**. Don't flag their absence; don't suggest creating them upfront. The `/domain-modeling` skill (reached via `/grill-with-docs` and `/improve-codebase-architecture`) creates them lazily when terms or decisions actually get resolved.

## File structure

```
/
├── CONTEXT.md
├── docs/adr/
│   ├── 0001-event-sourced-orders.md
│   └── 0002-postgres-for-write-model.md
└── src/
```

If this repo ever splits into multiple bounded contexts, switch to a root `CONTEXT-MAP.md` pointing at one `CONTEXT.md` per context, with context-scoped ADRs under `src/<context>/docs/adr/`, and update this file.

## Use the glossary's vocabulary

When your output names a domain concept (in an issue title, a refactor proposal, a hypothesis, a test name), use the term as defined in `CONTEXT.md`. Don't drift to synonyms the glossary explicitly avoids.

If the concept you need isn't in the glossary yet, that's a signal — either you're inventing language the project doesn't use (reconsider) or there's a real gap (note it for `/domain-modeling`).

## Flag ADR conflicts

If your output contradicts an existing ADR, surface it explicitly rather than silently overriding:

> _Contradicts ADR-0007 (event-sourced orders) — but worth reopening because…_
