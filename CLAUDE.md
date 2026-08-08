# varnick

## Development workflow

All feature work follows one flow, in order: `/grill-with-docs` → `/to-spec` → `/machine-first-prototype` → visual lock → `/to-tickets` → `/implement` → `/impeccable document` → PR. Read [docs/agents/workflow.md](docs/agents/workflow.md) before starting a feature, and [docs/agents/stage-contracts.md](docs/agents/stage-contracts.md) for what each stage reads and writes.

Four things about this repo that are not obvious from the code:

- **Core and Userspace are different spaces, enforced by the sandbox policy.** The agent writes Userspace freely and cannot write `packages/core/**`, `vite.config.*`, or `package.json` — see [ADR-0002](docs/adr/0002-core-userspace-boundary.md). Adding a Surface must therefore never require editing Core; discovery is filesystem-based.
- **Core never statically imports Userspace** — [ADR-0004](docs/adr/0004-core-never-statically-imports-userspace.md). A broken Userspace module must be a failed Surface, not a dead app with no chat.
- **State machines, the bare page, and the states page are product code, not scaffolding.** They ship. The states page is a coverage-checked test surface; the bare page is the design-free behavioural surface.
- **The view layer is pure** — [ADR-0001](docs/adr/0001-pure-view-layer.md). Components are functions of `(snapshot, send)`; machines declare actors without importing implementations. This is what lets the states page and the live app be the same code.

Read [CONTEXT.md](CONTEXT.md) before using any domain term — `Core`, `Userspace`, `Surface`, `Workspace`, `Profile`, `Clone`, `Collect`, and `Escalation` all have precise meanings here, and `Workspace` means the opposite of what it means in the sibling `zbc` repository.

## Agent skills

### Issue tracker

Issues live as markdown files under `.scratch/<feature-slug>/` in this repo. See `docs/agents/issue-tracker.md`.

### Triage labels

The five canonical triage roles, used verbatim as status strings. See `docs/agents/triage-labels.md`.

### Domain docs

Single-context — `CONTEXT.md` and `docs/adr/` at the repo root. See `docs/agents/domain.md`.
