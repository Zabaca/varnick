# varnick

## Development workflow

All feature work follows one flow, in order: `/grill-with-docs` → `/to-spec` → `/impeccable shape` → `/machine-first-prototype` → visual lock → `/to-tickets` → `/implement` → `/impeccable document` → PR. Read [docs/agents/workflow.md](docs/agents/workflow.md) before starting a feature, and [docs/agents/stage-contracts.md](docs/agents/stage-contracts.md) for what each stage reads and writes.

Five things about this repo that are not obvious from the code:

- **Core and Userspace are different spaces, enforced by the sandbox policy.** The agent writes Userspace freely and cannot write `packages/core/**`, `packages/harness/**`, `vite.config.*`, `package.json`, `sandbox-policy.json`, or its baseline — see [ADR-0002](docs/adr/0002-core-userspace-boundary.md). The last three are on the list for the same reason as the first two: an agent that can rewrite the generator, the policy, or the baseline it is compared against can widen its own fence on the next launch. Adding a Surface must therefore never require editing Core; discovery is filesystem-based.
- **Core never statically imports Userspace** — [ADR-0004](docs/adr/0004-core-never-statically-imports-userspace.md). A broken Userspace module must be a failed Surface, not a dead app with no chat.
- **State machines and the states page are product code, not scaffolding.** They ship. The states page is a coverage-checked test surface, reachable from the View menu. A third rendering — the design-free bare page — shipped beside it and was removed once `drive.ts` proved behaviour better than clicking did; [ADR-0013](docs/adr/0013-behaviour-is-proved-headlessly.md) says why, so it is not re-added by reflex.
- **The view layer is pure** — [ADR-0001](docs/adr/0001-pure-view-layer.md). Components are functions of `(snapshot, send)`; machines declare actors without importing implementations. This is what lets the states page and the live app be the same code.
- **A state is named in exactly one place: the machines.** Their exported path lists are the source, `CONTEXT.md` defines the names, `#/states` renders them, a ticket points at a card. Surface briefs carry ranges, never states — `drive.ts` fails the build if one does.

Read [CONTEXT.md](CONTEXT.md) before using any domain term — `Core`, `Userspace`, `Surface`, `Workspace`, `Profile`, `Clone`, `Collect`, and `Escalation` all have precise meanings here, and `Workspace` means the opposite of what it means in the sibling `zbc` repository.

## Agent skills

### Issue tracker

Issues live as markdown files under `.scratch/<feature-slug>/` in this repo. See `docs/agents/issue-tracker.md`.

### Triage labels

The five canonical triage roles, used verbatim as status strings. See `docs/agents/triage-labels.md`.

### Domain docs

Single-context — `CONTEXT.md` and `docs/adr/` at the repo root. See `docs/agents/domain.md`.
