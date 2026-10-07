# Contributing

Launchy is a macOS app written in Swift, with a small Bun server for the Phone page. This is how to
build it, check a change and work the way the repository does. [`README.md`](README.md) says what Launchy
is and what it needs.

## Build and check

- **`make build`** builds, codesigns and fetches the files plain `swift build` lacks. It must finish clean:
  fix every error and every new warning. The first build resolves packages and is slow.
- **`bun test`**, run in `PhonePage/`, tests the Phone page's server and its page.
- **There is no Swift test target.** Swift changes are checked by `make build` and then by hand in a running
  Launchy; say in your change what you checked and what you didn't.

How code here is wired and styled is in [`CODING_STANDARDS.md`](CODING_STANDARDS.md). What a change can
break even when it follows them is in [`docs/agents/where-it-breaks.md`](docs/agents/where-it-breaks.md).
The words the code and docs use are in [`CONTEXT.md`](CONTEXT.md), and the decisions behind the design are in
[`docs/adr/`](docs/adr/).

## Restarting ends sessions

`make run` and `make install` restart Launchy, which ends every Claude, terminal and app pane that isn't
kept in zmx (README, "Restarting ends sessions that aren't kept in zmx"). Leave restarts to the user,
and don't run one from inside a Claude session running in the Launchy you are restarting.

## How work is planned

Non-trivial work starts from a **problem**, then **options**, then **tickets**:

1. A problem is `docs/problems/<slug>/problem.md`: what is wrong, for whom, and what it costs.
2. Each way of solving it is an option, `docs/problems/<slug>/options/NN-<slug>.md`. An accepted option is
   the spec.
3. An option is cut into tickets, which are local files under `.scratch/` and are not committed.

Small fixes and UI tweaks need none of this. The layout and the frontmatter are in
[`docs/agents/issue-tracker.md`](docs/agents/issue-tracker.md). Read its section
[This repository is public](docs/agents/issue-tracker.md#this-repository-is-public) before you commit a doc.

## The Claude Code plugins the agents expect

The repository's agents (`.claude/agents/`) and `CLAUDE.md` use skills from the `mattpocock-skills` plugin,
such as `mattpocock-skills:tdd`, `mattpocock-skills:code-review` and `mattpocock-skills:writing-for-agents`.
The plugins are those `.claude/settings.json` enables. You have to install them yourself, or skip them:
Claude Code may skip an enabled plugin you haven't installed (this is inferred, not checked), in which case
the agents run without those skills and the planning flow above won't work as written. You don't need them to build, test or send a change by hand.

## Sending a change

Keep a change as small as the feature allows: no drive-by refactors, no new abstractions for a single
use, and no new dependencies without a reason in the change. Match the code around it. A new setting,
shortcut, saved field or Claude flag has a place it goes; `CODING_STANDARDS.md` lists them.
