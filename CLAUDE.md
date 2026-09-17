# varnick

Read [CONTEXT.md](CONTEXT.md) before using any domain term; `Host`, `Live`, `Preview`, `Session`, `Worktree`, `Landing`, `Door`, `Machine` and `Snapshot` have precise meanings. Decisions are in [docs/adr/](docs/adr/); ten so far, and ADR-0003 is the one rule most others follow from.

Five things not obvious from the code:

- **The agent only works in a Worktree.** The Live tree is written only by Landing, a fast-forward the Host performs. There is no protected-path list because there is nothing in the Live tree to protect (ADR-0003).
- **The chat is a terminal.** ttyd over a zmx session running `claude`. No Agent SDK, no transcript store of our own (ADR-0002).
- **Actors live in the Host; the page, the agent and tests all use the Door.** Do not add a binding or `executeJs` call for the page; if the page needs it, an agent needs it too (ADR-0006).
- **The agent never holds the Credential.** It has a placeholder and a base URL; the Proxy swaps them (ADR-0005).
- **Nothing is persisted by the Host.** Actors rebuild from git and zmx on launch (ADR-0007).

Machines are XState 5; each ships with a headless test through the Door. No states page, no staged workflow (ADR-0010).

Use `deno task dev` to launch Live. Do not add an egress allowlist without an ADR (ADR-0004).

## Agent skills

### Issue tracker

Fredrin tickets, never GitHub issues and never markdown files in the repo. A spec is a Goal; work is tickets under it. The operating manual is `docs/agents/issue-tracker.md`. Fredrin's memory folder is `docs/`, declared in the tracked `.fredrin/FREDRIN.md`. Until varnick can develop varnick, Fredrin is how varnick is developed.

### Triage labels

The five canonical roles, used verbatim. See `docs/agents/triage-labels.md`.

### Domain docs

Single-context: `CONTEXT.md` and `docs/adr/` at the repo root.
