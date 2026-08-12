# Issue tracker: Local Markdown

Issues and specs for this repo live as markdown files in `.scratch/`.

## Conventions

- One feature per directory: `.scratch/<feature-slug>/`
- The spec is `.scratch/<feature-slug>/spec.md`
- Implementation issues are one file per ticket at `.scratch/<feature-slug>/issues/<NN>-<slug>.md`, numbered from `01` — never a single combined tickets file
- Triage state is recorded as a `Status:` line near the top of each issue file (see `triage-labels.md` for the role strings)
- Comments and conversation history append to the bottom of the file under a `## Comments` heading
- Each ticket carries a `**Realizes:**` line naming the machine state paths it makes real, e.g. `**Realizes:** orders.sending, orders.sendFailed`. Those paths resolve to cards on the states page and to glossary entries in `CONTEXT.md`; see [stage-contracts.md](./stage-contracts.md#stage-5--to-tickets)
- A ticket that takes something away carries an `**Accepted consequence:**` line saying what stops working, in one paragraph, in the ticket body — see below
- The spec at `.scratch/<feature-slug>/spec.md` is authored once and then amended in place as later stages discover states. It must be current before tickets are cut

## `**Accepted consequence:**` — the one field a release reads

A ticket that removes something the developer relied on says so under this
marker, in the ticket body:

```markdown
**Accepted consequence:** live Surface hot-reloading no longer works in the main
window. It still works in a Preview.
```

Two things read it, and the second is why it is a field rather than a habit.

A human reads it, because a loss that is not written down is one somebody
discovers. And `bun run release` reads it: it is **the only thing a ticket says
that moves the version number**, taking a release from a patch to a minor. See
[ADR-0022](../adr/0022-a-pre-release-is-cut-from-the-changelogs-pending-block.md).

**It is not a bump declaration.** Nobody writes `breaking` on a ticket to choose
a version — that was considered and turned down. This is a sentence the ticket
owes its reader anyway; the release just stops ignoring it.

Write it when, and only when, something that worked stops working. A ticket that
merely changes how something is built has no accepted consequence, and a field
written by reflex is one the number stops meaning anything from.

**The marker is read from the body only** — everything above `## Comments`. A
comment discussing the field, as this paragraph does, is conversation and does
not make a ticket breaking.

## When a skill says "publish to the issue tracker"

Create a new file under `.scratch/<feature-slug>/` (creating the directory if needed).

## When a skill says "fetch the relevant ticket"

Read the file at the referenced path. The user will normally pass the path or the issue number directly.

## Wayfinding operations

Used by `/wayfinder`. The **map** is a file with one **child** file per ticket.

- **Map**: `.scratch/<effort>/map.md` — the Notes / Decisions-so-far / Fog body.
- **Child ticket**: `.scratch/<effort>/issues/NN-<slug>.md`, numbered from `01`, with the question in the body. A `Type:` line records the ticket type (`research`/`prototype`/`grilling`/`task`); a `Status:` line records `claimed`/`resolved`.
- **Blocking**: a `Blocked by: NN, NN` line near the top. A ticket is unblocked when every file it lists is `resolved`.
- **Frontier**: scan `.scratch/<effort>/issues/` for files that are open, unblocked, and unclaimed; first by number wins.
- **Claim**: set `Status: claimed` and save before any work.
- **Resolve**: append the answer under an `## Answer` heading, set `Status: resolved`, then append a context pointer (gist + link) to the map's Decisions-so-far in `map.md`.
