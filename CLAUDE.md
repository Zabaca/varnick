# varnick

## Development workflow

All feature work follows one flow, in order: `/grill-with-docs` → `/to-spec` → `/impeccable shape` → `/machine-first-prototype` → visual lock → `/to-tickets` → `/implement` → `/impeccable document` → PR. Read [docs/agents/workflow.md](docs/agents/workflow.md) before starting a feature, and [docs/agents/stage-contracts.md](docs/agents/stage-contracts.md) for what each stage reads and writes.

Five things about this repo that are not obvious from the code:

- **Core and Userspace are different spaces, enforced by the sandbox policy.** The agent writes Userspace freely and cannot write `packages/core/**`, `packages/harness/**`, `src-tauri/**`, `vite.config.*`, `package.json`, `scripts/**`, `sandbox-policy.json`, its baseline, `.git/hooks/**` or `.git/config*` — see [ADR-0002](docs/adr/0002-core-userspace-boundary.md). The policy entries are on the list for the same reason as the code: an agent that can rewrite the generator, the policy, or the baseline it is compared against can widen its own fence on the next launch. `scripts/**` and the two `.git` entries close the same shape one step out — deny a file the host executes but leave the file *it* invokes writable, and the deny does nothing ([ADR-0016](docs/adr/0016-gits-own-directory-is-outside-the-review-path.md)). Adding a Surface must therefore never require editing Core; discovery is filesystem-based.
- **The agent changes Core in a worktree, not by escalating** — [ADR-0014](docs/adr/0014-core-is-authored-in-a-worktree.md). `denyWrite` names *absolute live-tree* paths, so a worktree's `packages/core/**` matches nothing and the agent authors Core there under its ordinary Profile. The change becomes running code only when a human merges it and restarts, and the gate needs nothing built: landing it means writing the live tree, which the kernel refuses. ADR-0005's Clone, Escalation and Collect are retired — do not reintroduce them.
- **Core never statically imports Userspace** — [ADR-0004](docs/adr/0004-core-never-statically-imports-userspace.md). A broken Userspace module must be a failed Surface, not a dead app with no chat.
- **State machines and the states page are product code, not scaffolding.** They ship. The states page is a coverage-checked test surface, reachable from the View menu. A third rendering — the design-free bare page — shipped beside it and was removed once `drive.ts` proved behaviour better than clicking did; [ADR-0013](docs/adr/0013-behaviour-is-proved-headlessly.md) says why, so it is not re-added by reflex.
- **The view layer is pure** — [ADR-0001](docs/adr/0001-pure-view-layer.md). Components are functions of `(snapshot, send)`; machines declare actors without importing implementations. This is what lets the states page and the live app be the same code.
- **A state is named in exactly one place: the machines.** Their exported path lists are the source, `CONTEXT.md` defines the names, `#/states` renders them, a ticket points at a card. Surface briefs carry ranges, never states — `drive.ts` fails the build if one does.

Read [CONTEXT.md](CONTEXT.md) before using any domain term — `Core`, `Userspace`, `Surface`, `Realm`, `Workspace`, `Profile`, `Worktree`, `Preview`, and `Fence` all have precise meanings here, and `Workspace` means the opposite of what it means in the sibling `zbc` repository. `Fence` is smaller than `Core`: it is the code that decides what the agent may do, and three separate mechanisms key off that same list. There was a fourth, the Preview approval dialog, and it went when a Preview stopped being an escalation ([ADR-0019](docs/adr/0019-a-preview-is-confined-by-the-live-trees-policy.md)).

## Agent skills

### Issue tracker

Issues live as markdown files under `.scratch/<feature-slug>/` in this repo. See `docs/agents/issue-tracker.md`.

### Triage labels

The five canonical triage roles, used verbatim as status strings. See `docs/agents/triage-labels.md`.

### Domain docs

Single-context — `CONTEXT.md` and `docs/adr/` at the repo root. See `docs/agents/domain.md`.
