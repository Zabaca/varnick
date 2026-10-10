# Issue tracker: Local Markdown

Work starts from a **Problem**, committed under `docs/problems/`. Issues (tickets) live as markdown files in `.scratch/`, which is gitignored: they stay on this machine and aren't committed.

## Problems

Non-trivial work starts with a problem. Small fixes and UI tweaks don't need one.

```
docs/problems/<problem-slug>/
  problem.md
  options/NN-<option-slug>.md     numbered from 01
```

`problem.md` frontmatter:

- `title` — required, text
- `description` — required, text: what is wrong, for whom
- `impact` — required, text: what it costs if left alone
- `severity` — required: `low | mid | high`
- `evidence` — optional: links, screenshots, session or log references
- `status` — `open | closed`, set by hand

`options/NN-<option-slug>.md` is one way of solving the problem, and it is the spec for that way. Its body follows the `/to-spec` template minus Problem Statement (that lives in `problem.md`), plus Trade-offs: Solution, Trade-offs, User Stories, Implementation Decisions, Testing Decisions, Out of Scope, Further Notes. Same rules as `/to-spec`: no file paths or code snippets, except a prototype snippet that encodes a decision. Frontmatter:

- `problem` — the problem slug
- `title`, `summary`
- `status` — `proposed | accepted | in-progress | shipped | rejected | abandoned`
- `reason` — required when `rejected` or `abandoned`: why, so the option isn't proposed again

Several options can be live on one problem at once. The link runs from option to problem; `problem.md` never lists or picks options. Rejected options stay on record.

An accepted option is the spec: when work starts, its tickets go under `.scratch/<problem-slug>/issues/` (below). An option with an architectural consequence also gets a `docs/adr/` entry once accepted; link to it rather than repeating it.

### Who sets an option's status

The Problems tab on the session board reads these statuses, so they are kept true:

- `proposed`, `accepted`, `rejected`, `abandoned`: the user's choice; the planner writes it.
- `in-progress`: set by hand when work starts that no branch shows yet.
- `shipped`: set by the merge that finishes the option, in the merge commit itself: `git merge --no-ff --no-commit <branch>`, edit the option's `status` to `shipped`, then `git commit` with the merge message. A merge that leaves the option unfinished sets nothing. The branch's tie says which option it built.

**Branch tie.** A builder's first step, on a branch other than main, is `/work option <problem-slug>/<NN>`, which runs `git config branch.<branch>.varnick-option <problem-slug>/<NN>` and links the session or subagent to the option (ADR 0020). Without the skill, run the git command. Every worktree shares the config, and deleting the branch drops the entry. The tab shows the option Building while the branch has commits that main lacks, so no `in-progress` is needed.

**Work links.** Writing a file under `docs/problems/<slug>/`, or under `.scratch/<slug>/` of an existing problem, links the writer to the problem by itself (a hook), so the planner writing `problem.md` and a ticket claim need nothing more. `/work problem <slug>` links work that writes no such file; `/work none` clears. A link to an option replaces only through `/work`.

## Conventions

- One feature per directory: `.scratch/<feature-slug>/`; use the problem slug when the work comes from a problem
- The spec is the accepted option file; for work with no problem it's `.scratch/<feature-slug>/spec.md`
- Implementation issues are one file per ticket at `.scratch/<feature-slug>/issues/<NN>-<slug>.md`, numbered from `01` — never a single combined tickets file
- Triage state is recorded as a `Status:` line near the top of each issue file (see `triage-labels.md` for the role strings)
- Comments and conversation history append to the bottom of the file under a `## Comments` heading

## When a skill says "publish to the issue tracker"

A spec goes in the option file under `docs/problems/<problem-slug>/options/` (create the problem and option if they don't exist yet). Tickets, and a spec for work with no problem, go in a new file under `.scratch/<feature-slug>/` (creating the directory if needed).

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

## This repository is public

Everything that reaches `main` or origin is published, history included. None of these goes into a committed file, a commit message or a PR body:

- email addresses, except a service's public ones
- tailnet names, anything under `.ts.net`, tailnet IPs, Tailscale node or user IDs
- account names, home paths
- hostnames of the user's machines, and their `user@host` forms
- client names, browser profile names
- credentials, and how they are set up
- the path of a private folder, and the names of the files in it

Measurements from the user's own data, recipes with real hosts, and anything else private go in the problem's scratch folder, `.scratch/<problem-slug>/`, which is local and gitignored. The committed doc then says "measured on the user's machine; figures kept locally".

Examples use made-up values. A machine by kind ("the Loft") appears only in problems and ADRs, as a dated record; code and other docs name roles ("another Mac", "a headless host").

The prototyper's capture branch is the local-only exception: it holds real data and is never pushed.
